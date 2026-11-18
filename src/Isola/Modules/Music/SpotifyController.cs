using System.Globalization;
using System.Windows.Threading;
using Isola.Core;

namespace Isola.Modules.Music;

internal enum SpotifyLinkState { Disconnected, Connecting, Connected }

/// <summary>Spotify extras on top of the GSMTC player. Lives from module Start to Stop. All public
/// members run on the UI thread; the network work runs on the thread pool. No polling: the API is
/// called only when the Spotify track changes or when the user opens / uses the panel.</summary>
internal sealed class SpotifyController
{
    private static readonly TimeSpan PlaylistCacheAge = TimeSpan.FromMinutes(10);

    private readonly IIslandHost _host;
    private readonly string _moduleId;
    private readonly SpotifyViewModel _vm;
    private readonly SpotifyApi _api;
    private readonly Action<string> _saveClientId;
    private readonly DispatcherTimer _messageTimer;
    private bool _alive = true;

    private bool _connected;
    private bool _sourceIsSpotify;
    private string _gsmtcTitle = "", _gsmtcArtist = "";
    private string _trackKey = "";
    private int _trackVersion;
    private SpotifyTrack? _track;
    private bool _likeBusy, _adding;

    private SpotifyMe? _me;
    private bool _fetchingMe;
    private List<SpotifyPlaylist>? _playlists;
    private DateTime _playlistsAt;
    private bool _playlistsLoading;
    private string _playlistFilter = "";
    private int _queueVersion, _searchVersion;
    private string _lastQuery = "";
    private CancellationTokenSource? _login;

    public SpotifyLinkState LinkState { get; private set; } = SpotifyLinkState.Disconnected;
    public string? DisplayName => _me?.DisplayName;
    public string LinkMessage { get; private set; } = "";
    /// <summary>Raised on the UI thread when the connection state changes (settings page).</summary>
    public event Action? LinkChanged;

    public SpotifyController(IIslandHost host, string moduleId, SpotifyViewModel vm, Action<string> saveClientId)
    {
        _host = host;
        _moduleId = moduleId;
        _vm = vm;
        _saveClientId = saveClientId;
        _api = new SpotifyApi(new SpotifyTokenStore(host.DataDirectory(moduleId)), m => host.Log(moduleId, m));
        _api.Revoked += () => Post(() =>
        {
            _connected = false;
            _me = null;
            ResetRecents();
            SetLink(SpotifyLinkState.Disconnected, "Spotify ha revocato l'accesso: collegalo di nuovo.");
            UpdateActive();
        });
        _messageTimer = new DispatcherTimer(DispatcherPriority.Background, host.Dispatcher) { Interval = TimeSpan.FromSeconds(2.6) };
        _messageTimer.Tick += (_, _) => { _messageTimer.Stop(); _vm.Message = ""; };
        _vm.ResetAll();

        // DPAPI + file read off the UI thread. No network here.
        Run(() => Task.FromResult(_api.LoadStored()), loaded =>
        {
            if (!loaded) return;
            _connected = true;
            SetLink(SpotifyLinkState.Connected, "");
            UpdateActive();
        });
    }

    public void Stop()
    {
        _alive = false;
        _login?.Cancel();
        _login = null;
        _messageTimer.Stop();
        _vm.ResetAll();
        LinkChanged = null;
    }

    internal static bool IsSpotifyApp(string? aumid)
    {
        if (string.IsNullOrEmpty(aumid)) return false;
        return aumid.Equals("Spotify.exe", StringComparison.OrdinalIgnoreCase)
               || aumid.EndsWith("\\Spotify.exe", StringComparison.OrdinalIgnoreCase)
               || aumid.StartsWith("SpotifyAB.SpotifyMusic_", StringComparison.OrdinalIgnoreCase);
    }

    // ---------- GSMTC side (from MusicModule) ----------

    public void SetSource(string? aumid)
    {
        bool spotify = IsSpotifyApp(aumid);
        if (spotify == _sourceIsSpotify) return;
        _sourceIsSpotify = spotify;
        _trackKey = "";
        if (!spotify) { _gsmtcTitle = _gsmtcArtist = ""; _vm.TrackTitle = ""; }
        UpdateActive();
    }

    /// <summary>Media properties of the Spotify session (title/artist). Deduplicated: GSMTC fires
    /// several times per track (text first, cover later).</summary>
    public void OnTrack(string title, string artist)
    {
        if (!_sourceIsSpotify) return;
        _gsmtcTitle = title;
        _gsmtcArtist = artist;
        _vm.TrackTitle = title;
        string key = title + "\n" + artist;
        if (key == _trackKey) return;
        _trackKey = key;
        _track = null;
        _vm.ResetTrack();
        int v = ++_trackVersion;
        if (_vm.IsActive && title.Length > 0) FetchTrack(v, title);
    }

    private void UpdateActive()
    {
        bool active = _sourceIsSpotify && _connected;
        if (active == _vm.IsActive) return;
        _vm.IsActive = active;
        if (!active)
        {
            _vm.IsPanelOpen = false;
            _track = null;
            _trackVersion++;
            _vm.ResetTrack();
        }
        else
        {
            _trackKey = "";
            OnTrack(_gsmtcTitle, _gsmtcArtist);
        }
    }

    private void FetchTrack(int v, string title)
    {
        Run(async () =>
        {
            // Spotify's API can lag a moment behind the Windows media session: retry a couple of
            // times until the API reports the same title (only right after a track change).
            for (int attempt = 0; attempt < 3; attempt++)
            {
                if (attempt > 0) await Task.Delay(1500).ConfigureAwait(false);
                if (v != Volatile.Read(ref _trackVersion) || !_alive) return (Track: (SpotifyTrack?)null, Saved: (bool?)null);
                var (t, err) = await _api.GetCurrentlyPlayingAsync().ConfigureAwait(false);
                if (err != SpotifyError.None) break;
                if (t != null && SameTitle(t.Name, title))
                    return (Track: t, Saved: t.Id != null ? await _api.IsSavedAsync(t).ConfigureAwait(false) : null);
            }
            return (Track: (SpotifyTrack?)null, Saved: (bool?)null);
        }, r =>
        {
            if (v != _trackVersion) return;
            _track = r.Track;
            _vm.CanLike = r.Track?.Id != null && r.Saved != null;
            _vm.IsLiked = r.Saved == true;
            if (_vm.IsPanelOpen && _vm.Segment == SpotifySegment.Queue) LoadQueue();
        });
    }

    internal static bool SameTitle(string api, string gsmtc)
    {
        string a = api.Trim(), b = gsmtc.Trim();
        if (a.Length == 0 || b.Length == 0) return false;
        return string.Equals(a, b, StringComparison.CurrentCultureIgnoreCase)
               || a.StartsWith(b, StringComparison.CurrentCultureIgnoreCase)
               || b.StartsWith(a, StringComparison.CurrentCultureIgnoreCase);
    }

    // ---------- heart ----------

    public void ToggleLike()
    {
        var t = _track;
        if (t == null || !_vm.CanLike || _likeBusy) return;
        bool target = !_vm.IsLiked;
        _vm.IsLiked = target; // optimistic
        _likeBusy = true;
        int v = _trackVersion;
        Run(() => _api.SetSavedAsync(t, target), err =>
        {
            _likeBusy = false;
            if (err == SpotifyError.None) return;
            if (v == _trackVersion) _vm.IsLiked = !target;
            ShowMessage(ErrorText(err, "Non riuscito"));
        }, () => { _likeBusy = false; if (v == _trackVersion) _vm.IsLiked = !target; });
    }

    // ---------- panel ----------

    public void OpenPanel()
    {
        if (!_vm.IsActive) return;
        _vm.IsPanelOpen = true;
        if (_track == null && _gsmtcTitle.Length > 0) { _trackKey = ""; OnTrack(_gsmtcTitle, _gsmtcArtist); }
        LoadSegment();
    }

    public void ClosePanel() => _vm.IsPanelOpen = false;

    public void SelectSegment(SpotifySegment s)
    {
        _vm.Segment = s;
        if (_vm.IsPanelOpen) LoadSegment();
    }

    private void LoadSegment()
    {
        switch (_vm.Segment)
        {
            case SpotifySegment.Playlist: LoadPlaylists(); break;
            case SpotifySegment.Queue: LoadQueue(); break;
        }
    }

    // ---------- playlists ----------

    private void LoadPlaylists()
    {
        if (_playlists != null && DateTime.UtcNow - _playlistsAt < PlaylistCacheAge) { ApplyPlaylistFilter(); return; }
        if (_playlistsLoading) return;
        _playlistsLoading = true;
        if (_playlists == null) _vm.PlaylistStatus = "Carico le playlist…";
        var knownMe = _me;
        Run(async () =>
        {
            var me = knownMe;
            if (me == null)
            {
                var (m, err) = await _api.GetMeAsync().ConfigureAwait(false);
                if (m == null) return (Me: (SpotifyMe?)null, List: (List<SpotifyPlaylist>?)null, Error: err == SpotifyError.None ? SpotifyError.Failed : err);
                me = m;
            }
            var (list, e2) = await _api.GetEditablePlaylistsAsync(me.Id).ConfigureAwait(false);
            return (Me: (SpotifyMe?)me, List: list, Error: e2);
        }, r =>
        {
            _playlistsLoading = false;
            if (r.Me != null && _me == null) { _me = r.Me; LinkChanged?.Invoke(); }
            if (r.List != null)
            {
                _playlists = r.List.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
                _playlistsAt = DateTime.UtcNow;
                ApplyPlaylistFilter();
            }
            else if (_playlists == null) _vm.PlaylistStatus = ErrorText(r.Error, "Playlist non disponibili");
        }, () => { _playlistsLoading = false; if (_playlists == null) _vm.PlaylistStatus = "Playlist non disponibili"; });
    }

    public void SetPlaylistFilter(string text)
    {
        _playlistFilter = text.Trim();
        ApplyPlaylistFilter();
    }

    private void ApplyPlaylistFilter()
    {
        if (_playlists == null) return;
        var cmp = CultureInfo.CurrentCulture.CompareInfo;
        const CompareOptions opts = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;
        _vm.Playlists.Clear();
        foreach (var p in _playlists)
            if (_playlistFilter.Length == 0 || cmp.IndexOf(p.Name, _playlistFilter, opts) >= 0)
                _vm.Playlists.Add(new PlaylistRow(p));
        _vm.PlaylistStatus = _vm.Playlists.Count > 0 ? ""
            : _playlists.Count == 0 ? "Nessuna playlist tua o collaborativa"
            : "Nessuna playlist trovata";
    }

    public void AddToPlaylist(PlaylistRow row)
    {
        var t = _track;
        if (t == null) { ShowMessage("Brano non riconosciuto su Spotify"); return; }
        if (_adding) return;
        _adding = true;
        string name = row.Name;
        Run(() => _api.AddToPlaylistAsync(row.Playlist.Id, t.Uri), err =>
        {
            _adding = false;
            ShowMessage(err == SpotifyError.None ? $"Aggiunta a {name}" : ErrorText(err, "Non riuscito"));
        }, () => _adding = false);
    }

    // ---------- queue ----------

    private void LoadQueue()
    {
        int v = ++_queueVersion;
        if (_vm.Queue.Count == 0) _vm.QueueStatus = "Carico la coda…";
        Run(() => _api.GetQueueAsync(), r =>
        {
            if (v != _queueVersion) return;
            if (r.List == null)
            {
                if (_vm.Queue.Count == 0) _vm.QueueStatus = ErrorText(r.Error, "Coda non disponibile");
                return;
            }
            _vm.Queue.Clear();
            for (int i = 0; i < r.List.Count; i++) _vm.Queue.Add(new QueueRow(i + 1, r.List[i]));
            _vm.QueueStatus = r.List.Count == 0 ? "La coda è vuota" : "";
        });
    }

    // ---------- search ----------

    public void Search(string query)
    {
        string q = query.Trim();
        if (q.Length == 0)
        {
            _lastQuery = "";
            _searchVersion++;
            _vm.Results.Clear();
            _vm.SearchStatus = "";
            return;
        }
        if (q == _lastQuery) return;
        _lastQuery = q;
        int v = ++_searchVersion;
        if (_vm.Results.Count == 0) _vm.SearchStatus = "Cerco…";
        Run(() => _api.SearchAsync(q), r =>
        {
            if (v != _searchVersion) return;
            if (r.List == null)
            {
                _lastQuery = ""; // allow a retry of the same text
                _vm.Results.Clear();
                _vm.SearchStatus = ErrorText(r.Error, "Ricerca non riuscita");
                return;
            }
            _vm.Results.Clear();
            foreach (var t in r.List)
            {
                var row = new SearchRow(t);
                _vm.Results.Add(row);
                if (t.ImageUrl is { } url) LoadCover(v, row, url);
            }
            _vm.SearchStatus = r.List.Count == 0 ? "Nessun risultato" : "";
        });
    }

    private void LoadCover(int v, SearchRow row, string url)
    {
        Run(async () =>
        {
            var bytes = await SpotifyApi.DownloadImageAsync(url).ConfigureAwait(false);
            return bytes == null ? null : CoverArt.Decode(bytes, 64);
        }, img => { if (v == _searchVersion && img != null) row.Cover = img; });
    }

    public void Play(SearchRow row)
    {
        if (_vm.PlayBlocked) { ShowMessage(SpotifyViewModel.PremiumTip); return; }
        Run(() => _api.PlayAsync(row.Track.Uri), err =>
        {
            if (err == SpotifyError.PremiumRequired) _vm.PlayBlocked = true;
            ShowMessage(err == SpotifyError.None ? "In riproduzione" : ErrorText(err, "Non riuscito", player: true));
        });
    }

    public void Enqueue(SearchRow row)
    {
        if (_vm.QueueBlocked) { ShowMessage(SpotifyViewModel.PremiumTip); return; }
        Run(() => _api.EnqueueAsync(row.Track.Uri), err =>
        {
            if (err == SpotifyError.PremiumRequired) _vm.QueueBlocked = true;
            ShowMessage(err == SpotifyError.None ? "Aggiunto alla coda" : ErrorText(err, "Non riuscito", player: true));
        });
    }

    // ---------- "Apri Spotify" / "Recenti" (empty card) ----------

    private static readonly TimeSpan RecentsCacheAge = TimeSpan.FromMinutes(5);
    private const int MaxRecents = 4;
    private DateTime _recentsAt;
    private bool _recentsLoading, _recentsDenied;
    private int _recentsVersion;

    public bool IsConnected => _connected;

    /// <summary>Fetches the "Recenti" chips when the empty card becomes visible. Cached 5 minutes;
    /// a missing scope (account linked before this feature) stops it until the next link.</summary>
    public void EnsureRecents()
    {
        if (!_connected || _vm.PlayBlocked || _recentsDenied || _recentsLoading) return;
        if (_recentsAt != default && DateTime.UtcNow - _recentsAt < RecentsCacheAge) return;
        _recentsLoading = true;
        int v = ++_recentsVersion;
        var known = _playlists?.ToDictionary(p => p.Id, p => p.Name, StringComparer.Ordinal);
        Run(async () =>
        {
            var (list, err) = await _api.GetRecentlyPlayedAsync(MaxRecents).ConfigureAwait(false);
            if (list == null) return (List: (List<SpotifyRecent>?)null, Error: err);
            // Playlist names aren't in the history: from the cache, else one small GET each (≤ 4).
            var named = await Task.WhenAll(list.Select(async r =>
            {
                if (r.PlaylistId == null) return r;
                string? name = known != null && known.TryGetValue(r.PlaylistId, out var n) ? n
                    : await _api.GetPlaylistNameAsync(r.PlaylistId).ConfigureAwait(false);
                return name is { Length: > 0 } ? r with { Label = name } : r;
            })).ConfigureAwait(false);
            return (List: (List<SpotifyRecent>?)named.ToList(), Error: SpotifyError.None);
        }, r =>
        {
            _recentsLoading = false;
            if (v != _recentsVersion) return;
            _recentsAt = DateTime.UtcNow; // also after an error: no retry before the cache expires
            if (r.List == null)
            {
                if (r.Error == SpotifyError.Forbidden) _recentsDenied = true;
                return;
            }
            _vm.Recents.Clear();
            foreach (var item in r.List) _vm.Recents.Add(new RecentRow(item));
            _vm.HasRecents = _vm.Recents.Count > 0;
        }, () => _recentsLoading = false);
    }

    private void ResetRecents()
    {
        _recentsVersion++;
        _recentsAt = default;
        _recentsLoading = _recentsDenied = false;
        _vm.Recents.Clear();
        _vm.HasRecents = false;
    }

    /// <summary>Web API fallback: finds this PC's Spotify device and resumes there (no body), or
    /// plays a "Recenti" chip. One retry after 2 s if the device hasn't registered yet; then done.</summary>
    public void PlayOnThisPc(SpotifyRecent? item, Action<SpotifyError> done)
    {
        string machine = Environment.MachineName;
        Run(async () =>
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                if (attempt > 0) await Task.Delay(2000).ConfigureAwait(false);
                if (!_alive) return SpotifyError.Failed;
                var (devices, err) = await _api.GetDevicesAsync().ConfigureAwait(false);
                if (devices == null) return err;
                var d = SpotifyApi.PickDevice(devices, machine);
                if (d == null) continue;
                return item == null
                    ? await _api.ResumeOnDeviceAsync(d.Id).ConfigureAwait(false)
                    : await _api.PlayRecentOnDeviceAsync(d.Id, item).ConfigureAwait(false);
            }
            return SpotifyError.NotFound;
        }, done, () => done(SpotifyError.Failed));
    }

    /// <summary>403 PREMIUM_REQUIRED seen by the launcher: hide the chips, disable panel play.</summary>
    public void MarkPlayBlocked() => _vm.PlayBlocked = true;

    internal void ShowHint(string text) => ShowMessage(text);

    // ---------- connection (settings page) ----------

    public void Connect(string clientId)
    {
        clientId = clientId.Trim();
        if (LinkState != SpotifyLinkState.Disconnected) return;
        if (!SpotifyPkce.IsValidClientId(clientId))
        {
            SetLink(SpotifyLinkState.Disconnected, "Il Client ID è lungo 32 caratteri (cifre e lettere a-f).");
            return;
        }
        _saveClientId(clientId);
        var cts = new CancellationTokenSource();
        _login = cts;
        SetLink(SpotifyLinkState.Connecting, "");
        Run(async () =>
        {
            var res = await SpotifyLogin.RunAsync(clientId, cts.Token).ConfigureAwait(false);
            if (res.Outcome != LoginOutcome.Code) return (res.Outcome, Ok: false, Me: (SpotifyMe?)null);
            bool ok = await _api.ExchangeCodeAsync(clientId, res.Code!, res.Verifier!).ConfigureAwait(false);
            var me = ok ? (await _api.GetMeAsync().ConfigureAwait(false)).Me : null;
            return (res.Outcome, Ok: ok, Me: me);
        }, r =>
        {
            if (_login == cts) _login = null;
            cts.Dispose();
            if (r.Ok)
            {
                _connected = true;
                _me = r.Me;
                _playlists = null;
                _vm.PlayBlocked = _vm.QueueBlocked = false;
                ResetRecents();
                _host.Log(_moduleId, "Spotify: collegato");
                SetLink(SpotifyLinkState.Connected, "");
                UpdateActive();
                return;
            }
            SetLink(SpotifyLinkState.Disconnected, r.Outcome switch
            {
                LoginOutcome.Code => "Spotify non ha accettato l'accesso. Controlla Client ID e Redirect URI.",
                LoginOutcome.Denied => "Accesso annullato su Spotify.",
                LoginOutcome.PortBusy => "La porta 47322 è occupata da un altro programma.",
                LoginOutcome.Timeout => "Tempo scaduto (5 minuti). Riprova.",
                LoginOutcome.Cancelled => "",
                _ => "Non riesco ad aprire il browser.",
            });
        }, () =>
        {
            if (_login == cts) _login = null;
            SetLink(SpotifyLinkState.Disconnected, "Collegamento non riuscito.");
        });
    }

    public void CancelConnect() => _login?.Cancel();

    public void Disconnect()
    {
        _login?.Cancel();
        _connected = false;
        _me = null;
        _playlists = null;
        _track = null;
        _vm.PlayBlocked = _vm.QueueBlocked = false;
        ResetRecents();
        Run(() => { _api.Disconnect(); return Task.FromResult(true); }, _ => { });
        _host.Log(_moduleId, "Spotify: scollegato");
        SetLink(SpotifyLinkState.Disconnected, "");
        UpdateActive();
    }

    /// <summary>Fetches /me only to show "Collegato come …" (kept in memory, never saved).</summary>
    public void EnsureDisplayName()
    {
        if (!_connected || _me != null || _fetchingMe) return;
        _fetchingMe = true;
        Run(() => _api.GetMeAsync(), r =>
        {
            _fetchingMe = false;
            if (r.Me != null) { _me = r.Me; LinkChanged?.Invoke(); }
        }, () => _fetchingMe = false);
    }

    private void SetLink(SpotifyLinkState state, string message)
    {
        LinkState = state;
        LinkMessage = message;
        LinkChanged?.Invoke();
    }

    // ---------- helpers ----------

    private void ShowMessage(string text)
    {
        _messageTimer.Stop();
        _vm.Message = text;
        if (text.Length > 0) _messageTimer.Start();
    }

    private static string ErrorText(SpotifyError err, string fallback, bool player = false) => err switch
    {
        SpotifyError.PremiumRequired => SpotifyViewModel.PremiumTip,
        SpotifyError.RateLimited => "Spotify è occupato, riprova tra poco",
        SpotifyError.Network => "Spotify non risponde",
        SpotifyError.NotConnected => "Spotify non è collegato",
        SpotifyError.Forbidden => "Spotify non lo permette",
        SpotifyError.NotFound when player => "Nessun dispositivo Spotify attivo",
        _ => fallback,
    };

    private void Post(Action action)
    {
        if (!_alive) return;
        _host.Dispatcher.InvokeAsync(() =>
        {
            if (!_alive) return;
            try { action(); }
            catch (Exception ex) { _host.Log(_moduleId, "Spotify: errore interno " + ex.GetType().Name); }
        });
    }

    /// <summary>Runs <paramref name="work"/> on the thread pool and hands the result to
    /// <paramref name="done"/> on the UI thread (dropped if the module stopped meanwhile).</summary>
    private void Run<T>(Func<Task<T>> work, Action<T> done, Action? failed = null)
    {
        _ = Task.Run(async () =>
        {
            T result;
            try { result = await work().ConfigureAwait(false); }
            catch (Exception ex)
            {
                _host.Log(_moduleId, "Spotify: errore interno " + ex.GetType().Name);
                if (failed != null) Post(failed);
                return;
            }
            Post(() => done(result));
        });
    }
}
