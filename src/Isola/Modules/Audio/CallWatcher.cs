using Microsoft.Win32;

namespace Isola.Modules.Audio;

/// <summary>Detects "an app is using the microphone" from the privacy consent store:
/// under ConsentStore\microphone (direct subkeys = packaged apps, NonPackaged\* = desktop apps)
/// an entry with LastUsedTimeStart != 0 and LastUsedTimeStop == 0 is recording right now.
/// A background thread waits on RegNotifyChangeKeyValue: no polling.</summary>
internal sealed class CallWatcher : IDisposable
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    private readonly Action<DateTime?, string?> _changed; // (start of the call in UTC or null, app name)
    private readonly Action<string> _log;
    private readonly ManualResetEvent _stop = new(false);
    private readonly string _selfSuffix;
    private Thread? _thread;
    private DateTime? _lastStart;
    private bool _first = true;

    public CallWatcher(Action<DateTime?, string?> changed, Action<string> log)
    {
        _changed = changed;
        _log = log;
        var exe = Path.GetFileName(Environment.ProcessPath ?? "Isola.exe");
        _selfSuffix = "#" + exe;
    }

    public void Start()
    {
        _thread = new Thread(Run) { IsBackground = true, Name = "Isola.Audio.CallWatcher" };
        _thread.Start();
    }

    private void Run()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: false);
            if (key == null)
            {
                _log("chiave del registro del microfono assente: rilevamento chiamate spento");
                return;
            }
            using var changed = new AutoResetEvent(false);
            var handles = new WaitHandle[] { changed, _stop };
            while (true)
            {
                // Register first, then read: a change between the two is never missed.
                int rc = NativeAudio.RegNotifyChangeKeyValue(key.Handle, true,
                    NativeAudio.REG_NOTIFY_CHANGE_LAST_SET | NativeAudio.REG_NOTIFY_CHANGE_NAME,
                    changed.SafeWaitHandle, true);
                if (rc != 0)
                {
                    _log($"RegNotifyChangeKeyValue fallita ({rc}): rilevamento chiamate spento");
                    return;
                }
                Scan(key);
                if (WaitHandle.WaitAny(handles) == 1) return;
                // Apps write Start and Stop in quick bursts: coalesce them.
                if (_stop.WaitOne(150)) return;
            }
        }
        catch (Exception ex)
        {
            _log("rilevamento chiamate interrotto: " + ex.Message);
        }
    }

    private void Scan(RegistryKey root)
    {
        DateTime? earliest = null;
        string? app = null;

        void Check(RegistryKey parent, string name)
        {
            if (name.EndsWith(_selfSuffix, StringComparison.OrdinalIgnoreCase)) return; // ignore Isola itself
            try
            {
                using var k = parent.OpenSubKey(name, false);
                if (k == null) return;
                long start = ToLong(k.GetValue("LastUsedTimeStart"));
                long stop = ToLong(k.GetValue("LastUsedTimeStop"));
                if (start == 0 || stop != 0) return;
                var t = DateTime.FromFileTimeUtc(start);
                if (earliest == null || t < earliest)
                {
                    earliest = t;
                    app = PrettyName(name);
                }
            }
            catch { /* entry vanished while reading */ }
        }

        foreach (var name in root.GetSubKeyNames())
        {
            if (name.Equals("NonPackaged", StringComparison.OrdinalIgnoreCase))
            {
                using var np = root.OpenSubKey(name, false);
                if (np == null) continue;
                foreach (var sub in np.GetSubKeyNames()) Check(np, sub);
            }
            else Check(root, name);
        }

        // A recording that started "in the future" (clock skew) still counts from now.
        if (earliest > DateTime.UtcNow) earliest = DateTime.UtcNow;
        if (_first || earliest != _lastStart)
        {
            _first = false;
            _lastStart = earliest;
            _changed(earliest, app);
        }
    }

    private static long ToLong(object? v) => v switch
    {
        long l => l,
        int i => i,
        byte[] { Length: 8 } b => BitConverter.ToInt64(b, 0),
        _ => 0,
    };

    private static string PrettyName(string keyName)
    {
        // "C:#Program Files#Discord#Discord.exe" -> "Discord"; "Microsoft.Teams_8wek..." -> "Microsoft.Teams"
        var last = keyName.Split('#')[^1];
        if (last.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) last = last[..^4];
        int us = last.IndexOf('_');
        return us > 0 ? last[..us] : last;
    }

    public void Dispose()
    {
        _stop.Set();
        _thread?.Join(1000);
        _thread = null;
        _stop.Dispose();
    }
}
