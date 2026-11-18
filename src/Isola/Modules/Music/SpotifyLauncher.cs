using System.Diagnostics;
using System.Windows.Threading;
using Isola.Core;
using Microsoft.Win32;
using Windows.Media.Control;
using Session = Windows.Media.Control.GlobalSystemMediaTransportControlsSession;

namespace Isola.Modules.Music;

/// <summary>"Apri Spotify" / "Riprendi su Spotify" and the "Recenti" chips of the empty card.
/// One attempt per click, then idle: opens Spotify, waits (event driven, one timeout timer) for
/// its media session, presses play once through GSMTC (works without Premium) and, if that
/// doesn't take and the account is linked, falls back once to the Web API. UI thread only.</summary>
internal sealed class SpotifyLauncher
{
    public const string OpenHint = "Spotify è aperto: premi play lì";
    private static readonly TimeSpan LaunchWait = TimeSpan.FromSeconds(20);
    /// <summary>Spotify already running without a session usually won't grow one by itself.</summary>
    private static readonly TimeSpan RunningWait = TimeSpan.FromSeconds(4);
    private static readonly TimeSpan PlayWait = TimeSpan.FromSeconds(4);

    private enum Phase { Idle, WaitSession, WaitPlay, WebApi }
    private enum Mode { OpenOnly, Resume, Recent }

    private readonly IIslandHost _host;
    private readonly string _moduleId;
    private readonly MusicViewModel _vm;
    private readonly SpotifyController _spotify;
    private readonly Func<IReadOnlyList<Session>?> _sessions;
    private readonly Func<bool> _autoPlay;
    private readonly DispatcherTimer _timer;
    private bool _alive = true;
    private Phase _phase;
    private Mode _mode;
    private SpotifyRecent? _recent;
    private Session? _target;
    private int _attempt;

    public SpotifyLauncher(IIslandHost host, string moduleId, MusicViewModel vm, SpotifyController spotify,
                           Func<IReadOnlyList<Session>?> sessions, Func<bool> autoPlay)
    {
        _host = host;
        _moduleId = moduleId;
        _vm = vm;
        _spotify = spotify;
        _sessions = sessions;
        _autoPlay = autoPlay;
        _timer = new DispatcherTimer(DispatcherPriority.Background, host.Dispatcher);
        _timer.Tick += (_, _) => OnTimeout();
    }

    public bool IsBusy => _phase != Phase.Idle;

    public void Stop()
    {
        _alive = false;
        _attempt++;
        _timer.Stop();
        _phase = Phase.Idle;
        _target = null;
        _vm.LaunchBusy = false;
        _vm.LaunchHint = "";
    }

    // ---------- detection (cheap; call off the UI thread) ----------

    private static string DesktopExe =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Spotify", "Spotify.exe");

    private static bool ProtocolRegistered()
    {
        try
        {
            using var hkcu = Registry.CurrentUser.OpenSubKey(@"Software\Classes\spotify");
            if (hkcu != null) return true;
            using var hkcr = Registry.ClassesRoot.OpenSubKey("spotify");
            return hkcr != null;
        }
        catch { return false; }
    }

    private static bool StorePackagePresent()
    {
        try
        {
            string packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages");
            return Directory.Exists(packages) && Directory.EnumerateDirectories(packages, "SpotifyAB.SpotifyMusic_*").Any();
        }
        catch { return false; }
    }

    public static bool IsInstalled() => File.Exists(DesktopExe) || ProtocolRegistered() || StorePackagePresent();

    public static bool IsRunning()
    {
        try
        {
            var ps = Process.GetProcessesByName("Spotify");
            foreach (var p in ps) p.Dispose();
            return ps.Length > 0;
        }
        catch { return false; }
    }

    /// <summary>The spotify: protocol (desktop and Store), else the desktop exe. Also brings an
    /// already running Spotify to the front.</summary>
    private static bool StartProcess()
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo("spotify:") { UseShellExecute = true });
            return true;
        }
        catch { }
        try
        {
            string exe = DesktopExe;
            if (!File.Exists(exe)) return false;
            using var p = Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
            return true;
        }
        catch { return false; }
    }

    // ---------- the attempt ----------

    /// <summary>Button (recent == null) or a "Recenti" chip.</summary>
    public void Launch(SpotifyRecent? recent)
    {
        if (!_alive || _phase != Phase.Idle) return;
        _mode = recent != null ? Mode.Recent : _autoPlay() ? Mode.Resume : Mode.OpenOnly;
        _recent = recent;
        int attempt = ++_attempt;
        bool running = IsRunning();
        _vm.SpotifyRunning = running;
        _vm.LaunchHint = "";
        _vm.LaunchBusy = true;
        _host.Log(_moduleId, running ? "Spotify: apro (era già avviato)" : "Spotify: avvio");

        _ = Task.Run(StartProcess).ContinueWith(t =>
        {
            if (t.Result) return;
            Post(() => { if (attempt == _attempt && _phase != Phase.Idle) Finish("Non riesco ad aprire Spotify"); });
        }, TaskScheduler.Default);

        if (_mode == Mode.OpenOnly && running) { Finish(""); return; }
        if (_mode == Mode.Recent && running) { StartWebApi(); return; }

        _phase = Phase.WaitSession;
        Arm(running ? RunningWait : LaunchWait);
        OnSessionsChanged(); // a Spotify session may already exist without being the current one
    }

    /// <summary>From MusicModule on every GSMTC SessionsChanged / CurrentSessionChanged / playback change.</summary>
    public void OnSessionsChanged()
    {
        if (_phase == Phase.WaitSession)
        {
            var s = FindSpotifySession();
            if (s == null) return;
            _target = s;
            switch (_mode)
            {
                case Mode.OpenOnly: Finish(""); return;
                case Mode.Recent: StartWebApi(); return;
            }
            if (IsPlaying(s)) { Finish(""); return; }
            _phase = Phase.WaitPlay;
            Arm(PlayWait);
            TryPlay(s, _attempt);
        }
        else if (_phase == Phase.WaitPlay && _target != null && IsPlaying(_target))
        {
            Finish("");
        }
    }

    private async void TryPlay(Session s, int attempt)
    {
        bool ok = false;
        try { ok = await s.TryPlayAsync(); } catch { }
        if (attempt != _attempt || _phase != Phase.WaitPlay) return;
        if (IsPlaying(s)) { Finish(""); return; }
        if (!ok) OnTimeout(); // refused outright: no point waiting 4 s
    }

    private void OnTimeout()
    {
        _timer.Stop();
        switch (_phase)
        {
            case Phase.WaitSession:
                if (_mode == Mode.OpenOnly) Finish("");
                else if (_spotify.IsConnected) StartWebApi();
                else Finish(OpenHint);
                break;
            case Phase.WaitPlay:
                if (_target != null && IsPlaying(_target)) Finish("");
                else if (_spotify.IsConnected) StartWebApi();
                else Finish(OpenHint);
                break;
        }
    }

    private void StartWebApi()
    {
        if (!_spotify.IsConnected) { Finish(OpenHint); return; }
        _timer.Stop();
        _phase = Phase.WebApi;
        int attempt = _attempt;
        _spotify.PlayOnThisPc(_mode == Mode.Recent ? _recent : null, err =>
        {
            if (attempt != _attempt || _phase != Phase.WebApi) return;
            _host.Log(_moduleId, err == SpotifyError.None ? "Spotify: play via Web API" : "Spotify: play via Web API non riuscito (" + err + ")");
            if (err == SpotifyError.None) { Finish(""); return; }
            if (err == SpotifyError.PremiumRequired) _spotify.MarkPlayBlocked();
            Finish(OpenHint);
        });
    }

    private void Finish(string hint)
    {
        _attempt++;
        _timer.Stop();
        _phase = Phase.Idle;
        _target = null;
        _recent = null;
        _vm.LaunchBusy = false;
        _vm.SpotifyRunning = IsRunning();
        _vm.LaunchHint = hint;
        // The card may already show the (paused) Spotify player: say it there too.
        if (hint.Length > 0 && _vm.HasSession) _spotify.ShowHint(hint);
    }

    // ---------- helpers ----------

    private void Arm(TimeSpan wait)
    {
        _timer.Stop();
        _timer.Interval = wait;
        _timer.Start();
    }

    private Session? FindSpotifySession()
    {
        try
        {
            var all = _sessions();
            if (all == null) return null;
            foreach (var s in all)
            {
                string? id = null;
                try { id = s.SourceAppUserModelId; } catch { }
                if (SpotifyController.IsSpotifyApp(id)) return s;
            }
        }
        catch { }
        return null;
    }

    private static bool IsPlaying(Session s)
    {
        try { return s.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing; }
        catch { return false; }
    }

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
}
