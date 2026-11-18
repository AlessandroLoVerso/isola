using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;

namespace Isola.Modules.Music;

/// <summary>State shown by the card and by the resting faces. Only touched on the UI thread.</summary>
internal sealed class MusicViewModel : INotifyPropertyChanged
{
    public static readonly Color DefaultAccent = Color.FromRgb(0x0A, 0x84, 0xFF);

    private bool _hasSession;
    private bool _isPlaying;
    private string _title = "";
    private string _artist = "";
    private ImageSource? _cover;
    private Brush? _coverBrush;
    private Color _accent = DefaultAccent;
    private Brush _accentBrush = Freeze(new SolidColorBrush(DefaultAccent));
    private Brush _accentSoftBrush = Freeze(new SolidColorBrush(Color.FromArgb(0x40, DefaultAccent.R, DefaultAccent.G, DefaultAccent.B)));
    private bool _hasTimeline;
    private bool _isLive;
    private double _progress;
    private string _elapsed = "0:00";
    private string _total = "0:00";
    private bool _canPrev, _canNext, _canPlayPause, _canSeek;
    private bool _hasLyrics;
    private string _lyricCurrent = "";
    private string _lyricNext = "";

    /// <summary>Spotify extras (heart, panel); inactive unless Spotify plays and is connected.</summary>
    public SpotifyViewModel Spotify { get; } = new();

    public bool HasSession { get => _hasSession; set { if (Set(ref _hasSession, value)) { Raise(nameof(NoSession)); Raise(nameof(ShowSpotifyButton)); } } }
    public bool NoSession => !_hasSession;

    // ---------- "Apri Spotify" (empty card) ----------

    public const string DefaultEmptyHint = "Avvia musica o un video in un'app qualsiasi.";
    private bool _spotifyInstalled, _spotifyRunning, _launchBusy;
    private string _launchHint = "";

    public bool SpotifyInstalled
    {
        get => _spotifyInstalled;
        set { if (Set(ref _spotifyInstalled, value)) { Raise(nameof(ShowSpotifyButton)); Raise(nameof(ShowEmptySubtitle)); } }
    }
    public bool SpotifyRunning { get => _spotifyRunning; set { if (Set(ref _spotifyRunning, value)) Raise(nameof(SpotifyButtonText)); } }
    /// <summary>A launch / resume attempt is in progress: the button shows the progress label.</summary>
    public bool LaunchBusy
    {
        get => _launchBusy;
        set { if (Set(ref _launchBusy, value)) { Raise(nameof(SpotifyButtonText)); Raise(nameof(CanLaunchSpotify)); } }
    }
    /// <summary>Short result of the last attempt ("Spotify è aperto: premi play lì"). Empty = none.</summary>
    public string LaunchHint
    {
        get => _launchHint;
        set { if (Set(ref _launchHint, value)) { Raise(nameof(EmptySubtitle)); Raise(nameof(ShowEmptySubtitle)); } }
    }
    public bool ShowSpotifyButton => !_hasSession && _spotifyInstalled;
    public bool CanLaunchSpotify => !_launchBusy;
    public string SpotifyButtonText => _launchBusy
        ? (_spotifyRunning ? "Riprendo su Spotify…" : "Avvio di Spotify…")
        : (_spotifyRunning ? "Riprendi su Spotify" : "Apri Spotify");
    /// <summary>With the Spotify button the generic line goes away (space for the chips) unless
    /// there's a hint to show.</summary>
    public bool ShowEmptySubtitle => !_spotifyInstalled || _launchHint.Length > 0;
    public string EmptySubtitle => _launchHint.Length > 0 ? _launchHint : DefaultEmptyHint;

    public bool IsPlaying
    {
        get => _isPlaying;
        set { if (Set(ref _isPlaying, value)) { Raise(nameof(IsPaused)); Raise(nameof(PlayGlyph)); Raise(nameof(PlayTip)); } }
    }
    public bool IsPaused => _hasSession && !_isPlaying;
    public string PlayGlyph => _isPlaying ? "\uF8AE" : "\uF5B0";
    public string PlayTip => _isPlaying ? "Pausa" : "Riproduci";

    public string Title { get => _title; set => Set(ref _title, value); }
    public string Artist { get => _artist; set => Set(ref _artist, value); }

    public ImageSource? Cover
    {
        get => _cover;
        set
        {
            if (!Set(ref _cover, value)) return;
            CoverBrush = value == null ? null : Freeze(new ImageBrush(value) { Stretch = Stretch.UniformToFill });
            Raise(nameof(HasCover));
        }
    }
    public bool HasCover => _cover != null;
    public Brush? CoverBrush { get => _coverBrush; private set => Set(ref _coverBrush, value); }

    public Color Accent
    {
        get => _accent;
        set
        {
            if (!Set(ref _accent, value)) return;
            AccentBrush = Freeze(new SolidColorBrush(value));
            AccentSoftBrush = Freeze(new SolidColorBrush(Color.FromArgb(0x40, value.R, value.G, value.B)));
        }
    }
    public Brush AccentBrush { get => _accentBrush; private set => Set(ref _accentBrush, value); }
    public Brush AccentSoftBrush { get => _accentSoftBrush; private set => Set(ref _accentSoftBrush, value); }

    public bool HasTimeline { get => _hasTimeline; set => Set(ref _hasTimeline, value); }
    public bool IsLive { get => _isLive; set => Set(ref _isLive, value); }
    public double Progress { get => _progress; set => Set(ref _progress, value); }
    public string Elapsed { get => _elapsed; set => Set(ref _elapsed, value); }
    public string Total { get => _total; set => Set(ref _total, value); }

    public bool CanPrev { get => _canPrev; set => Set(ref _canPrev, value); }
    public bool CanNext { get => _canNext; set => Set(ref _canNext, value); }
    public bool CanPlayPause { get => _canPlayPause; set => Set(ref _canPlayPause, value); }
    public bool CanSeek { get => _canSeek; set => Set(ref _canSeek, value); }

    public bool HasLyrics { get => _hasLyrics; set { if (Set(ref _hasLyrics, value)) Raise(nameof(NoLyrics)); } }
    public bool NoLyrics => !_hasLyrics;
    public string LyricCurrent { get => _lyricCurrent; set => Set(ref _lyricCurrent, value); }
    public string LyricNext { get => _lyricNext; set => Set(ref _lyricNext, value); }

    public void Reset()
    {
        HasSession = false; IsPlaying = false; Title = ""; Artist = ""; Cover = null; Accent = DefaultAccent;
        HasTimeline = false; IsLive = false; Progress = 0; Elapsed = "0:00"; Total = "0:00";
        CanPrev = CanNext = CanPlayPause = CanSeek = false;
        HasLyrics = false; LyricCurrent = ""; LyricNext = "";
        Raise(nameof(IsPaused));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name!);
        if (name == nameof(HasSession)) Raise(nameof(IsPaused));
        return true;
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private static T Freeze<T>(T f) where T : Freezable { f.Freeze(); return f; }
}
