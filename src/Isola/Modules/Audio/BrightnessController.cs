using System.Management;

namespace Isola.Modules.Audio;

/// <summary>Screen brightness: the laptop panel through WMI (root\WMI WmiMonitorBrightness),
/// external monitors through DDC/CI (dxva2). Every call is slow (DDC/CI can take 50+ ms per
/// monitor), so everything runs on a single background worker; values are 0..100.</summary>
internal sealed class BrightnessController : IDisposable
{
    private readonly Action<string> _log;
    private readonly object _gate = new();
    private readonly List<(IntPtr handle, uint min, uint max, string name)> _ddc = new();
    private bool _wmi;
    private bool _disposed;
    private int? _pending;
    private Task _worker = Task.CompletedTask;

    public BrightnessController(Action<string> log) => _log = log;

    public bool Available => _wmi || _ddc.Count > 0;

    /// <summary>Finds the supported displays. Returns the current level, or null if none works.
    /// Call it off the UI thread.</summary>
    public int? Initialize()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentBrightness FROM WmiMonitorBrightness");
            foreach (ManagementObject mo in searcher.Get())
            {
                using (mo)
                {
                    _wmi = true;
                    _log("luminosità: pannello interno (WMI)");
                    break;
                }
            }
        }
        catch { /* no WMI brightness on desktops: expected */ }

        try
        {
            var hmons = new List<IntPtr>();
            NativeAudio.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, _, _, _) => { hmons.Add(h); return true; }, IntPtr.Zero);
            foreach (var hmon in hmons)
            {
                if (!NativeAudio.GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, out uint n) || n == 0) continue;
                var arr = new NativeAudio.PHYSICAL_MONITOR[n];
                if (!NativeAudio.GetPhysicalMonitorsFromHMONITOR(hmon, n, arr)) continue;
                foreach (var pm in arr)
                {
                    if (NativeAudio.GetMonitorBrightness(pm.hPhysicalMonitor, out uint min, out uint cur, out uint max) && max > min)
                    {
                        lock (_gate) _ddc.Add((pm.hPhysicalMonitor, min, max, $"n. {_ddc.Count + 1}"));
                        _log($"luminosità: monitor DDC/CI n. {_ddc.Count} regolabile");
                    }
                    else NativeAudio.DestroyPhysicalMonitor(pm.hPhysicalMonitor);
                }
            }
        }
        catch (Exception ex) { _log("DDC/CI non disponibile: " + ex.Message); }

        lock (_gate)
        {
            if (_disposed) // the module stopped while we were enumerating
            {
                foreach (var m in _ddc) NativeAudio.DestroyPhysicalMonitor(m.handle);
                _ddc.Clear();
                return null;
            }
        }
        if (!Available) _log("luminosità: nessuno schermo regolabile, cursore nascosto");
        return Read();
    }

    /// <summary>Current level of the first supported display. Off the UI thread.</summary>
    public int? Read()
    {
        if (_disposed) return null;
        if (_wmi)
        {
            try
            {
                using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentBrightness FROM WmiMonitorBrightness");
                foreach (ManagementObject mo in searcher.Get())
                    using (mo) return Convert.ToInt32(mo["CurrentBrightness"]);
            }
            catch { }
        }
        lock (_gate)
        {
            foreach (var m in _ddc)
            {
                if (NativeAudio.GetMonitorBrightness(m.handle, out uint min, out uint cur, out uint max) && max > min)
                    return (int)Math.Round((cur - min) * 100.0 / (max - min));
            }
        }
        return null;
    }

    /// <summary>Requests a level; intermediate values while dragging are coalesced.</summary>
    public void Set(int level)
    {
        lock (_gate)
        {
            _pending = Math.Clamp(level, 0, 100);
            if (!_worker.IsCompleted) return;
            _worker = Task.Run(Drain);
        }
    }

    private void Drain()
    {
        while (true)
        {
            int level;
            lock (_gate)
            {
                if (_pending == null || _disposed) return;
                level = _pending.Value;
                _pending = null;
            }
            Apply(level);
        }
    }

    private void Apply(int level)
    {
        if (_wmi)
        {
            try
            {
                using var cls = new ManagementClass(@"root\WMI", "WmiMonitorBrightnessMethods", null);
                foreach (ManagementObject mo in cls.GetInstances())
                    using (mo) mo.InvokeMethod("WmiSetBrightness", new object[] { (uint)1, (byte)level });
            }
            catch (Exception ex) { _log("WmiSetBrightness: " + ex.Message); }
        }
        lock (_gate)
        {
            foreach (var m in _ddc)
            {
                uint v = m.min + (uint)Math.Round((m.max - m.min) * level / 100.0);
                if (!NativeAudio.SetMonitorBrightness(m.handle, v))
                    _log($"SetMonitorBrightness fallita sul monitor {m.name}");
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _pending = null;
        }
        // Let an in-flight DDC write finish before the handles go away.
        try { _worker.Wait(2000); } catch { }
        lock (_gate)
        {
            foreach (var m in _ddc) NativeAudio.DestroyPhysicalMonitor(m.handle);
            _ddc.Clear();
        }
    }
}
