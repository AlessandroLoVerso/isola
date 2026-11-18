using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using Isola.Core;
using Windows.Media.Control;
using Session = Windows.Media.Control.GlobalSystemMediaTransportControlsSession;
using SessionManager = Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager;

namespace Isola.Modules.Music;

/// <summary>"Musica": follows the system media session (Spotify, browsers, VLC...) through
/// GlobalSystemMediaTransportControls. Event driven: the only timer is the 4 Hz progress tick,
/// and it runs only while the card is on screen and something is playing.</summary>
public sealed class MusicModule : IIslandModule, IRestingFaceProvider
{
    private readonly MusicViewModel _vm = new();
    private IIslandHost? _host;
    private MusicSettings _settings = new();
    private SessionManager? _manager;
    private Session? _session;
    private DispatcherTimer? _timer;
    private MusicCard? _card;
    private LyricsService? _lyrics;
    private SpotifyController? _spotify;
    private SpotifyLauncher? _launcher;
    private int _generation;
    private int _priority;
    private int _propsVersion;

    // Timeline model: position = _basePos + (now - _baseAt) * rate while playing.
    private TimeSpan _start, _end, _basePos;
    private DateTimeOffset _baseAt = DateTimeOffset.Now;
    private double _rate = 1;
    private bool _playing;
    /// <summary>When playback stopped (null while playing). A paused track keeps the pill only
    /// for <see cref="PausedFaceTime"/>: a tab paused hours ago shouldn't hide the clock.</summary>
    private DateTime? _pausedSince;
    private DispatcherTimer? _pauseTimer;
    private static readonly TimeSpan PausedFaceTime = TimeSpan.FromMinutes(3);
    private bool _previewing;

    private string _title = "", _artist = "", _album = "";
    private byte[]? _thumbBytes;
    private LrcLine[]? _lyricLines;
    private string _lyricsKey = "";
    private CancellationTokenSource? _lyricsCts;

    public string Id => "music";
    public string Title => "Musica";
    public string Glyph => "\uE8D6";
    public int Order => 10;
    public bool EnabledByDefault => true;
    public int RestingPriority => _priority;

    public void Start(IIslandHost host)
    {
        _host = host;
        int gen = ++_generation;
        _settings = host.LoadSettings<MusicSettings>(Id);
        _lyrics = new LyricsService(Path.Combine(host.DataDirectory(Id), "lyrics"), m => host.Log(Id, m));
        _timer = new DispatcherTimer(DispatcherPriority.Background, host.Dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
        _timer.Tick += (_, _) => UpdatePosition();
        _pauseTimer = new DispatcherTimer(DispatcherPriority.Background, host.Dispatcher);
        _pauseTimer.Tick += (_, _) => { _pauseTimer?.Stop(); UpdatePriority(); };
        _vm.Reset();
        _spotify = new SpotifyController(host, Id, _vm.Spotify, SaveClientId);
        _launcher = new SpotifyLauncher(host, Id, _vm, _spotify, () => _manager?.GetSessions(), () => _settings.SpotifyAutoPlay);
        _ = InitAsync(gen);
    }

    private void SaveClientId(string clientId)
    {
        if (_settings.SpotifyClientId == clientId) return;
        _settings.SpotifyClientId = clientId;
        _host?.SaveSettings(Id, _settings);
    }

    public void Stop()
    {
        _generation++;
        _timer?.Stop();
        _timer = null;
        _pauseTimer?.Stop();
        _pauseTimer = null;
        _pausedSince = null;
        _lyricsCts?.Cancel();
        _lyricsCts = null;
        _launcher?.Stop();
        _launcher = null;
        _spotify?.Stop();
        _spotify = null;
        DetachSession();
        if (_manager != null)
        {
            _manager.CurrentSessionChanged -= OnManagerChanged;
            _manager.SessionsChanged -= OnSessionsChanged;
            _manager = null;
        }
        _card = null;
        _priority = 0;
        _thumbBytes = null;
        _lyricLines = null;
        _lyricsKey = "";
        _title = _artist = _album = "";
        _host = null;
    }

    private async Task InitAsync(int gen)
    {
        try
        {
            var mgr = await SessionManager.RequestAsync();
            if (gen != _generation) return;
            _manager = mgr;
            mgr.CurrentSessionChanged += OnManagerChanged;
            mgr.SessionsChanged += OnSessionsChanged;
            AttachCurrent();
        }
        catch (Exception ex)
        {
            _host?.Log(Id, "Controlli multimediali non disponibili: " + ex.Message);
        }
    }

    // ---------- events (arrive on any thread) ----------

    private void OnManagerChanged(SessionManager s, CurrentSessionChangedEventArgs e) => Post(AttachCurrent);
    private void OnSessionsChanged(SessionManager s, SessionsChangedEventArgs e) => Post(AttachCurrent);
    private void OnMediaProps(Session s, MediaPropertiesChangedEventArgs e) => Post(() => _ = LoadPropertiesAsync());
    private void OnPlayback(Session s, PlaybackInfoChangedEventArgs e) => Post(UpdatePlayback);
    private void OnTimeline(Session s, TimelinePropertiesChangedEventArgs e) => Post(UpdateTimeline);

    private void Post(Action action)
    {
        var host = _host;
        if (host == null) return;
        int gen = _generation;
        host.Dispatcher.InvokeAsync(() =>
        {
            if (gen != _generation) return;
            try { action(); }
            catch (Exception ex) { _host?.Log(Id, "Errore: " + ex.Message); }
        });
    }

    // ---------- session tracking ----------

    private void AttachCurrent()
    {
        if (_manager == null) return;
        Session? next = _manager.GetCurrentSession();
        if (next == null)
        {
            // Windows sometimes has sessions but no "current" one: prefer one that is playing.
            var all = _manager.GetSessions();
            next = all.FirstOrDefault(x => Safe(() => x.GetPlaybackInfo().PlaybackStatus) == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                   ?? all.FirstOrDefault();
        }

        // Reference identity: CsWinRT returns the same wrapper for the same session, and two
        // browser tabs share the app id, so comparing ids would miss a tab switch.
        if (!ReferenceEquals(next, _session))
        {
            DetachSession();
            _session = next;
            if (next != null)
            {
                next.MediaPropertiesChanged += OnMediaProps;
                next.PlaybackInfoChanged += OnPlayback;
                next.TimelinePropertiesChanged += OnTimeline;
            }
            _thumbBytes = null;
            _pausedSince = null; // a different player: its pause starts counting now
        }
        var current = _session;
        _spotify?.SetSource(current == null ? null : Safe(() => current.SourceAppUserModelId));

        if (_session == null)
        {
            _vm.Reset();
            _playing = false;
            _title = _artist = _album = "";
            ClearLyrics();
            UpdatePriority();
            UpdateTimerState();
            _launcher?.OnSessionsChanged();
            if (_card is { IsVisible: true }) RefreshEmptyState();
            return;
        }

        _vm.HasSession = true;
        _launcher?.OnSessionsChanged();
        UpdatePlayback();
        UpdateTimeline();
        _ = LoadPropertiesAsync();
    }

    private void DetachSession()
    {
        if (_session == null) return;
        try
        {
            _session.MediaPropertiesChanged -= OnMediaProps;
            _session.PlaybackInfoChanged -= OnPlayback;
            _session.TimelinePropertiesChanged -= OnTimeline;
        }
        catch { }
        _session = null;
    }

    private void UpdatePlayback()
    {
        var s = _session;
        if (s == null) return;
        var info = s.GetPlaybackInfo();
        if (info == null) return;
        bool playing = info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        var c = info.Controls;
        _vm.CanPrev = c.IsPreviousEnabled;
        _vm.CanNext = c.IsNextEnabled;
        _vm.CanPlayPause = c.IsPlayPauseToggleEnabled || c.IsPlayEnabled || c.IsPauseEnabled;
        _rate = info.PlaybackRate is double r && r > 0 ? r : 1;

        if (playing != _playing)
        {
            // Freeze/restart the extrapolation at the switch; the app's next timeline update corrects it.
            _basePos = CurrentPosition();
            _baseAt = DateTimeOffset.Now;
            _playing = playing;
        }
        _vm.IsPlaying = playing;
        if (playing) _pausedSince = null;
        else _pausedSince ??= DateTime.Now;
        UpdatePriority();
        UpdateTimerState();
        UpdatePosition();
        _launcher?.OnSessionsChanged();
    }

    private void UpdateTimeline()
    {
        var s = _session;
        if (s == null) return;
        var tl = s.GetTimelineProperties();
        if (tl == null) return;
        var now = DateTimeOffset.Now;
        _start = tl.StartTime;
        _end = tl.EndTime;
        _basePos = tl.Position;
        _baseAt = tl.LastUpdatedTime.Year < 2000 || tl.LastUpdatedTime > now ? now : tl.LastUpdatedTime;

        bool hasTimeline = _end - _start > TimeSpan.FromSeconds(1);
        _vm.HasTimeline = hasTimeline;
        _vm.IsLive = !hasTimeline;
        _vm.CanSeek = hasTimeline && tl.MaxSeekTime > tl.MinSeekTime;
        _vm.Total = Format(_end - _start);
        UpdatePosition();
        UpdateTimerState();
        MaybeLoadLyrics();
    }

    private async Task LoadPropertiesAsync()
    {
        var s = _session;
        if (s == null) return;
        int version = ++_propsVersion;
        int gen = _generation;

        GlobalSystemMediaTransportControlsSessionMediaProperties? p;
        try { p = await s.TryGetMediaPropertiesAsync(); }
        catch { return; }
        if (p == null || version != _propsVersion || gen != _generation || !ReferenceEquals(s, _session)) return;

        _title = p.Title?.Trim() ?? "";
        _artist = (string.IsNullOrWhiteSpace(p.Artist) ? p.AlbumArtist : p.Artist)?.Trim() ?? "";
        _album = p.AlbumTitle?.Trim() ?? "";
        _vm.Title = _title.Length > 0 ? _title : "Senza titolo";
        _vm.Artist = _artist.Length > 0 ? _artist : AppName(Safe(() => s.SourceAppUserModelId) ?? "");
        _spotify?.OnTrack(_title, _artist); // no-op unless the source is Spotify; deduplicated per track
        MaybeLoadLyrics();

        byte[]? bytes = null;
        if (p.Thumbnail != null)
        {
            try
            {
                using var ras = await p.Thumbnail.OpenReadAsync();
                using var stream = ras.AsStreamForRead();
                using var ms = new MemoryStream();
                await stream.CopyToAsync(ms);
                bytes = ms.ToArray();
            }
            catch { bytes = null; }
        }
        if (version != _propsVersion || gen != _generation) return;

        if (bytes == null || bytes.Length == 0)
        {
            _thumbBytes = null;
            _vm.Cover = null;
            _vm.Accent = MusicViewModel.DefaultAccent;
            return;
        }
        if (_thumbBytes != null && bytes.AsSpan().SequenceEqual(_thumbBytes)) return;
        _thumbBytes = bytes;

        var (cover, accent) = await Task.Run(() => (CoverArt.Decode(bytes, 256), CoverArt.DominantColor(bytes)));
        if (version != _propsVersion || gen != _generation) return;
        _vm.Cover = cover;
        _vm.Accent = accent ?? MusicViewModel.DefaultAccent;
    }

    // ---------- position ----------

    private TimeSpan CurrentPosition()
    {
        var p = _basePos;
        if (_playing) p += TimeSpan.FromTicks((long)((DateTimeOffset.Now - _baseAt).Ticks * _rate));
        if (_end > _start) p = p < _start ? _start : p > _end ? _end : p;
        return p;
    }

    private void UpdatePosition()
    {
        var pos = CurrentPosition();
        if (!_previewing && _vm.HasTimeline)
        {
            var dur = _end - _start;
            _vm.Progress = dur.Ticks > 0 ? (pos - _start).Ticks / (double)dur.Ticks : 0;
            _vm.Elapsed = Format(pos - _start);
        }
        UpdateLyricLine(pos - _start);
    }

    private void UpdateTimerState()
    {
        if (_timer == null) return;
        bool want = _playing && _card is { IsVisible: true } && (_vm.HasTimeline || _vm.HasLyrics);
        if (want && !_timer.IsEnabled) { UpdatePosition(); _timer.Start(); }
        else if (!want && _timer.IsEnabled) _timer.Stop();
    }

    private static string Format(TimeSpan t)
    {
        if (t < TimeSpan.Zero) t = TimeSpan.Zero;
        return t.TotalHours >= 1
            ? t.ToString(@"h\:mm\:ss", CultureInfo.InvariantCulture)
            : $"{(int)t.TotalMinutes}:{t.Seconds:00}";
    }

    // ---------- commands (from the card, UI thread) ----------

    internal async void PlayPause()
    {
        var s = _session;
        if (s == null) return;
        try { await s.TryTogglePlayPauseAsync(); } catch { }
    }

    internal async void Next()
    {
        var s = _session;
        if (s == null) return;
        try { await s.TrySkipNextAsync(); } catch { }
    }

    internal async void Previous()
    {
        var s = _session;
        if (s == null) return;
        try { await s.TrySkipPreviousAsync(); } catch { }
    }

    internal void PreviewSeek(double fraction)
    {
        if (!_vm.HasTimeline) return;
        _previewing = true;
        var dur = _end - _start;
        _vm.Progress = fraction;
        _vm.Elapsed = Format(TimeSpan.FromTicks((long)(dur.Ticks * fraction)));
    }

    internal void CancelSeek()
    {
        _previewing = false;
        UpdatePosition();
    }

    internal async void CommitSeek(double fraction)
    {
        _previewing = false;
        var s = _session;
        if (s == null || !_vm.HasTimeline) return;
        var target = _start + TimeSpan.FromTicks((long)((_end - _start).Ticks * fraction));
        // Show the new position right away; the app confirms it with a timeline update.
        _basePos = target;
        _baseAt = DateTimeOffset.Now;
        UpdatePosition();
        try { await s.TryChangePlaybackPositionAsync(target.Ticks); } catch { }
    }

    // ---------- Spotify extras (from the card, UI thread) ----------

    internal void SpotifyToggleLike() => _spotify?.ToggleLike();
    internal void SpotifyOpenPanel() => _spotify?.OpenPanel();
    internal void SpotifyClosePanel() => _spotify?.ClosePanel();
    internal void SpotifySelectSegment(SpotifySegment s) => _spotify?.SelectSegment(s);
    internal void SpotifyFilterPlaylists(string text) => _spotify?.SetPlaylistFilter(text);
    internal void SpotifyAddToPlaylist(PlaylistRow row) => _spotify?.AddToPlaylist(row);
    internal void SpotifySearch(string query) => _spotify?.Search(query);
    internal void SpotifyPlay(SearchRow row) => _spotify?.Play(row);
    internal void SpotifyEnqueue(SearchRow row) => _spotify?.Enqueue(row);
    internal void RequestKeyboardFocus() => _host?.RequestKeyboardFocus();

    // ---------- "Apri Spotify" (empty card, UI thread) ----------

    internal void OpenSpotify() => _launcher?.Launch(null);
    internal void PlayRecent(RecentRow row) => _launcher?.Launch(row.Item);

    /// <summary>The empty card became visible (or the last session went away while it was):
    /// is Spotify installed / running, plus the "Recenti" chips. Nothing runs while it's hidden.</summary>
    private void RefreshEmptyState()
    {
        if (_vm.HasSession || _host == null) return;
        _ = Task.Run(() => (Installed: SpotifyLauncher.IsInstalled(), Running: SpotifyLauncher.IsRunning())).ContinueWith(t =>
        {
            if (t.IsFaulted) return;
            var r = t.Result;
            Post(() =>
            {
                _vm.SpotifyInstalled = r.Installed;
                if (_launcher is { IsBusy: false }) _vm.SpotifyRunning = r.Running;
            });
        }, TaskScheduler.Default);
        _spotify?.EnsureRecents();
    }

    // ---------- priority ----------

    private void UpdatePriority()
    {
        int p = 0;
        _pauseTimer?.Stop();
        if (_session != null && _playing) p = 50;
        else if (_session != null)
        {
            var left = PausedFaceTime - (DateTime.Now - (_pausedSince ?? DateTime.Now));
            if (left > TimeSpan.Zero)
            {
                p = 20;
                if (_pauseTimer != null) { _pauseTimer.Interval = left + TimeSpan.FromMilliseconds(100); _pauseTimer.Start(); }
            }
        }
        if (p == _priority) return;
        _priority = p;
        _host?.RefreshRestingFace();
    }

    // ---------- lyrics ----------

    private void MaybeLoadLyrics()
    {
        if (!_settings.LyricsEnabled || _lyrics == null || _title.Length == 0 || !_vm.HasTimeline)
        {
            if (!_settings.LyricsEnabled || _title.Length == 0) ClearLyrics();
            return;
        }
        int dur = (int)Math.Round((_end - _start).TotalSeconds);
        string key = $"{_artist}\n{_title}\n{_album}\n{dur}";
        if (key == _lyricsKey) return;
        ClearLyrics();
        _lyricsKey = key;

        var cts = new CancellationTokenSource();
        _lyricsCts = cts;
        var service = _lyrics;
        string artist = _artist, title = _title, album = _album;
        _ = Task.Run(async () =>
        {
            LrcLine[]? lines = null;
            try { lines = await service.GetAsync(artist, title, album, dur, cts.Token); } catch { }
            if (cts.IsCancellationRequested) return;
            Post(() =>
            {
                if (_lyricsKey != key) return;
                _lyricLines = lines;
                _vm.HasLyrics = lines is { Length: > 0 };
                UpdatePosition();
                UpdateTimerState();
            });
        });
    }

    private void ClearLyrics()
    {
        _lyricsCts?.Cancel();
        _lyricsCts = null;
        _lyricsKey = "";
        _lyricLines = null;
        _vm.HasLyrics = false;
        _vm.LyricCurrent = "";
        _vm.LyricNext = "";
    }

    private void UpdateLyricLine(TimeSpan pos)
    {
        var lines = _lyricLines;
        if (lines == null || lines.Length == 0) return;
        int i = LyricsService.IndexAt(lines, pos + TimeSpan.FromMilliseconds(250));
        string current = i >= 0 ? lines[i].Text : "";
        string next = i + 1 < lines.Length ? lines[i + 1].Text : "";
        _vm.LyricCurrent = current.Length > 0 ? current : "♪";
        _vm.LyricNext = next;
    }

    // ---------- UI ----------

    public FrameworkElement? CreateCard()
    {
        var card = new MusicCard(this, _vm);
        card.IsVisibleChanged += (_, _) =>
        {
            UpdatePosition();
            UpdateTimerState();
            if (card.IsVisible) RefreshEmptyState();
            else if (_launcher is { IsBusy: false }) _vm.LaunchHint = "";
        };
        _card = card;
        return card;
    }

    public FrameworkElement CreateRestingFace()
    {
        var placeholder = new Border { CornerRadius = new CornerRadius(6) };
        placeholder.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Surface");
        var note = new TextBlock { Text = "\uE8D6", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        note.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        note.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        placeholder.Child = note;

        var art = new Border { CornerRadius = new CornerRadius(6) };
        art.SetBinding(Border.BackgroundProperty, new Binding(nameof(MusicViewModel.CoverBrush)));

        var cover = new Grid { Width = 22, Height = 22, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
        cover.Children.Add(placeholder);
        cover.Children.Add(art);

        var eq = new Equalizer { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 2, 0) };
        eq.SetBinding(Equalizer.IsActiveProperty, new Binding(nameof(MusicViewModel.IsPlaying)));
        eq.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(MusicViewModel.IsPlaying)) { Converter = new BooleanToVisibilityConverter() });

        var paused = new TextBlock { Text = "\uE769", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 3, 0) };
        paused.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        paused.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        paused.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(MusicViewModel.IsPaused)) { Converter = new BooleanToVisibilityConverter() });

        // Small heart when the Spotify track is in "Brani che ti piacciono" (only then).
        var heart = new TextBlock { Text = "", FontSize = 9, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 28, 0), Opacity = 0.85 };
        heart.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        heart.SetBinding(TextBlock.ForegroundProperty, new Binding(nameof(MusicViewModel.AccentBrush)));
        heart.SetBinding(UIElement.VisibilityProperty, new Binding("Spotify." + nameof(SpotifyViewModel.ShowRestingHeart)) { Converter = new BooleanToVisibilityConverter() });

        var grid = new Grid { DataContext = _vm };
        grid.Children.Add(cover);
        grid.Children.Add(heart);
        grid.Children.Add(eq);
        grid.Children.Add(paused);
        return grid;
    }

    public FrameworkElement? CreateSettingsPage()
    {
        var toggle = new CheckBox { IsChecked = _settings.LyricsEnabled, Content = "Testi sincronizzati" };
        toggle.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.ToggleSwitch");
        void Changed(object s, RoutedEventArgs e)
        {
            _settings.LyricsEnabled = toggle.IsChecked == true;
            _host?.SaveSettings(Id, _settings);
            if (_settings.LyricsEnabled) MaybeLoadLyrics(); else ClearLyrics();
            UpdateTimerState();
        }
        toggle.Checked += Changed;
        toggle.Unchecked += Changed;

        var note = new TextBlock
        {
            Text = "Mostra nella scheda la riga del testo che si sta cantando. I testi vengono scaricati da lrclib.net " +
                   "(titolo, artista e durata del brano) e salvati sul PC. Oltre a Spotify, se lo colleghi qui sotto, è l'unica funzione della musica che usa internet.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Margin = new Thickness(0, 6, 0, 0),
        };
        note.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");

        var card = new Border { Child = new StackPanel { Margin = new Thickness(0, 14, 0, 14), Children = { toggle, note } } };
        card.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SettingCard");

        var autoPlay = new CheckBox { IsChecked = _settings.SpotifyAutoPlay, Content = "Quando apro Spotify dall'isola, fai partire la musica" };
        autoPlay.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.ToggleSwitch");
        void AutoPlayChanged(object s, RoutedEventArgs e)
        {
            _settings.SpotifyAutoPlay = autoPlay.IsChecked == true;
            _host?.SaveSettings(Id, _settings);
        }
        autoPlay.Checked += AutoPlayChanged;
        autoPlay.Unchecked += AutoPlayChanged;
        var autoNote = new TextBlock
        {
            Text = "Se non suona niente e Spotify è sul PC, la scheda mostra «Apri Spotify». Con questa opzione Isola preme anche play " +
                   "(riprende l'ultima cosa ascoltata); se non basta e Spotify è collegato qui sotto, lo chiede una volta a Spotify (serve Premium).",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Margin = new Thickness(0, 6, 0, 0),
        };
        autoNote.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");
        var autoCard = new Border { Margin = new Thickness(0, 8, 0, 0), Child = new StackPanel { Margin = new Thickness(0, 14, 0, 14), Children = { autoPlay, autoNote } } };
        autoCard.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SettingCard");

        var page = new StackPanel();
        page.Children.Add(card);
        page.Children.Add(autoCard);
        page.Children.Add(new SpotifySettingsSection(_spotify, _settings.SpotifyClientId, SaveClientId));
        return page;
    }

    // ---------- helpers ----------

    private static string AppName(string aumid)
    {
        string s = aumid;
        int bang = s.LastIndexOf('!');
        if (bang >= 0) s = s[(bang + 1)..];
        if (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) s = s[..^4];
        return s.ToLowerInvariant() switch
        {
            "chrome" => "Google Chrome",
            "msedge" => "Microsoft Edge",
            "firefox" or "308046b0af4a39cb" => "Firefox",
            "spotify" => "Spotify",
            "vlc" => "VLC",
            _ => s.Length > 0 ? s : "Riproduzione",
        };
    }

    private static T? Safe<T>(Func<T> f)
    {
        try { return f(); } catch { return default; }
    }
}

public sealed class MusicSettings
{
    public bool LyricsEnabled { get; set; }
    /// <summary>Client ID of the user's own Spotify developer app (PKCE, no secret). Empty = not set.</summary>
    public string SpotifyClientId { get; set; } = "";
    /// <summary>"Apri Spotify" also starts the music (one GSMTC play, then one Web API resume).</summary>
    public bool SpotifyAutoPlay { get; set; } = true;
}
