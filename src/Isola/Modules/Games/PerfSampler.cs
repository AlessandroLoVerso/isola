using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using static Isola.Modules.Games.NativePerf;

namespace Isola.Modules.Games;

/// <summary>One smoothed reading. NaN = not available (counter missing or still warming up).</summary>
internal readonly record struct PerfSnapshot(
    double Cpu, double Gpu, double RamPercent, double RamUsedGb, double RamTotalGb,
    double DownBytesPerSec, double UpBytesPerSec);

/// <summary>What to read. Disabled metrics are not even added to the query.</summary>
internal readonly record struct SamplerOptions(bool Cpu, bool Gpu, bool Ram, bool Net, int RateHz);

/// <summary>Reads CPU / GPU (PDH, the Task Manager counters), RAM (GlobalMemoryStatusEx) and network
/// (interface byte counters) on its own background thread, smooths them and hands each reading to
/// <see cref="Sample"/>. Runs only between Start and Stop: nothing at all happens otherwise.</summary>
internal sealed class PerfSampler
{
    private readonly Action<PerfSnapshot> _sample;
    private readonly Action<string> _log;
    private Worker? _worker;

    public PerfSampler(Action<PerfSnapshot> sample, Action<string> log)
    {
        _sample = sample;
        _log = log;
    }

    public bool IsRunning => _worker != null;

    /// <summary>UI thread only.</summary>
    public void Start(SamplerOptions options)
    {
        if (_worker != null) return;
        _worker = new Worker(this, options);
    }

    /// <summary>UI thread only. Returns at once; the thread exits within one interval.</summary>
    public void Stop()
    {
        _worker?.Cancel();
        _worker = null;
    }

    /// <summary>One background thread per Start..Stop, with its own cancel flag, so a quick
    /// Stop + Start never revives an old loop.</summary>
    private sealed class Worker
    {
        private readonly AutoResetEvent _wake = new(false);
        private volatile bool _cancelled;

        public Worker(PerfSampler owner, SamplerOptions o)
        {
            var t = new Thread(() => Run(owner, o))
            {
                IsBackground = true,
                Name = "Isola.Games.Sampler",
                Priority = ThreadPriority.BelowNormal,
            };
            t.Start();
        }

        public void Cancel()
        {
            _cancelled = true;
            try { _wake.Set(); } catch (ObjectDisposedException) { }
        }

        private void Run(PerfSampler owner, SamplerOptions o)
        {
            Session? s = null;
            try
            {
                s = new Session(o, owner._log);
                int intervalMs = 1000 / Math.Clamp(o.RateHz, 1, 10);
                while (!_cancelled)
                {
                    var snap = s.Read();
                    if (_cancelled) break;
                    if (snap is { } v) owner._sample(v);
                    _wake.WaitOne(intervalMs);
                }
            }
            catch (Exception ex)
            {
                owner._log("Campionamento interrotto: " + ex.Message);
            }
            finally
            {
                s?.Dispose();
                _wake.Dispose(); // Cancel() tolerates a disposed event
            }
        }
    }
    /// <summary>The PDH query and the previous readings, alive for one Start..Stop.</summary>
    private sealed class Session : IDisposable
    {
        private readonly SamplerOptions _o;
        private IntPtr _query, _gpuQuery;
        // GPU engines (hundreds of instances) and network are slower to read and change less
        // abruptly: they are refreshed at most 5 and 2 times per second.
        private const double GpuStep = 0.2, NetStep = 0.5;
        private double _gpuAt = double.NegativeInfinity, _netAt = double.NegativeInfinity;
        private IntPtr _cpuCounter, _gpuCounter;
        private IntPtr _buffer;
        private uint _bufferSize;
        private readonly Dictionary<string, double> _gpuByAdapter = new();
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private double _lastT;
        private bool _first = true;

        // Smoothed values
        private double _cpu = double.NaN, _gpu = double.NaN, _down = double.NaN, _up = double.NaN;

        // Network
        private NetworkInterface[] _nics = Array.Empty<NetworkInterface>();
        private double _nicsAt = -100;
        private long _lastRx = -1, _lastTx = -1;
        private string _nicKey = "";

        public Session(SamplerOptions o, Action<string> log)
        {
            _o = o;
            if (o.Cpu && PdhOpenQuery(null, IntPtr.Zero, out _query) != ERROR_SUCCESS) { _query = IntPtr.Zero; log("PDH non disponibile"); }
            if (o.Gpu && PdhOpenQuery(null, IntPtr.Zero, out _gpuQuery) != ERROR_SUCCESS) { _gpuQuery = IntPtr.Zero; log("PDH non disponibile"); }

            if (_query != IntPtr.Zero &&
                PdhAddEnglishCounter(_query, @"\Processor Information(_Total)\% Processor Utility", IntPtr.Zero, out _cpuCounter) != ERROR_SUCCESS &&
                PdhAddEnglishCounter(_query, @"\Processor(_Total)\% Processor Time", IntPtr.Zero, out _cpuCounter) != ERROR_SUCCESS)
            {
                _cpuCounter = IntPtr.Zero;
                log("Contatore CPU non disponibile");
            }

            // Only the 3D engines (what Task Manager shows); fall back to all engines filtered by name.
            if (_gpuQuery != IntPtr.Zero &&
                PdhAddEnglishCounter(_gpuQuery, @"\GPU Engine(*engtype_3D)\Utilization Percentage", IntPtr.Zero, out _gpuCounter) != ERROR_SUCCESS &&
                PdhAddEnglishCounter(_gpuQuery, @"\GPU Engine(*)\Utilization Percentage", IntPtr.Zero, out _gpuCounter) != ERROR_SUCCESS)
            {
                _gpuCounter = IntPtr.Zero;
                log("Contatori GPU non disponibili");
            }
            // Rate counters need a first reading.
            if (_query != IntPtr.Zero) PdhCollectQueryData(_query);
            if (_gpuQuery != IntPtr.Zero) PdhCollectQueryData(_gpuQuery);
        }

        public PerfSnapshot? Read()
        {
            double t = _clock.Elapsed.TotalSeconds;
            double dt = _first ? 0 : t - _lastT;
            _lastT = t;
            bool first = _first;
            _first = false;

            // Time constant ~0.35 s: steady numbers without visible lag.
            double a = dt <= 0 ? 1 : 1 - Math.Exp(-dt / 0.35);

            if (_cpuCounter != IntPtr.Zero && !first && PdhCollectQueryData(_query) == ERROR_SUCCESS &&
                PdhGetFormattedCounterValue(_cpuCounter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, out _, out var v) == ERROR_SUCCESS &&
                v.CStatus is PDH_CSTATUS_VALID_DATA or PDH_CSTATUS_NEW_DATA)
                _cpu = Smooth(_cpu, Math.Clamp(v.DoubleValue, 0, 100), a);

            if (_gpuCounter != IntPtr.Zero && !first && t - _gpuAt >= GpuStep - 0.02)
            {
                double gdt = t - _gpuAt;
                _gpuAt = t;
                double ga = double.IsInfinity(gdt) ? 1 : 1 - Math.Exp(-gdt / 0.35);
                if (PdhCollectQueryData(_gpuQuery) == ERROR_SUCCESS && ReadGpu() is { } g)
                    _gpu = Smooth(_gpu, g, ga);
            }

            double ramPct = double.NaN, used = double.NaN, total = double.NaN;
            if (_o.Ram)
            {
                var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
                if (GlobalMemoryStatusEx(ref m) && m.ullTotalPhys > 0)
                {
                    total = m.ullTotalPhys / 1073741824.0;
                    used = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
                    ramPct = 100.0 * (m.ullTotalPhys - m.ullAvailPhys) / m.ullTotalPhys;
                }
            }

            if (_o.Net && t - _netAt >= NetStep - 0.02)
            {
                double ndt = double.IsInfinity(_netAt) ? 0 : t - _netAt;
                _netAt = t;
                ReadNet(t, ndt, ndt <= 0 ? 1 : 1 - Math.Exp(-ndt / 0.6));
            }

            if (first) return null;
            return new PerfSnapshot(_o.Cpu ? _cpu : double.NaN, _o.Gpu ? _gpu : double.NaN, ramPct, used, total,
                _o.Net ? _down : double.NaN, _o.Net ? _up : double.NaN);
        }

        private static double Smooth(double old, double value, double a)
            => double.IsNaN(old) ? value : old + (value - old) * a;

        /// <summary>Sums the 3D engines per adapter (luid) and returns the busiest adapter, like Task Manager.</summary>
        private double? ReadGpu()
        {
            uint size = _bufferSize;
            int r = PdhGetFormattedCounterArray(_gpuCounter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out uint count, _buffer);
            if (r == PDH_MORE_DATA)
            {
                if (_buffer != IntPtr.Zero) Marshal.FreeHGlobal(_buffer);
                _bufferSize = size + 4096; // instances come and go: leave some room
                _buffer = Marshal.AllocHGlobal((int)_bufferSize);
                size = _bufferSize;
                r = PdhGetFormattedCounterArray(_gpuCounter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out count, _buffer);
            }
            if (r != ERROR_SUCCESS) return null;

            _gpuByAdapter.Clear();
            int itemSize = Marshal.SizeOf<PDH_FMT_COUNTERVALUE_ITEM>();
            for (int i = 0; i < count; i++)
            {
                var item = Marshal.PtrToStructure<PDH_FMT_COUNTERVALUE_ITEM>(_buffer + i * itemSize);
                if (item.FmtValue.CStatus is not (PDH_CSTATUS_VALID_DATA or PDH_CSTATUS_NEW_DATA)) continue;
                double v = item.FmtValue.DoubleValue;
                if (v <= 0) continue;
                string? name = Marshal.PtrToStringUni(item.szName);
                if (name == null || !name.Contains("engtype_3D", StringComparison.OrdinalIgnoreCase)) continue;
                string luid = Luid(name);
                _gpuByAdapter[luid] = (_gpuByAdapter.TryGetValue(luid, out var s) ? s : 0) + v;
            }
            double max = 0;
            foreach (var v in _gpuByAdapter.Values) max = Math.Max(max, v);
            return Math.Clamp(max, 0, 100);
        }

        private static string Luid(string name)
        {
            // pid_1234_luid_0x00000000_0x0000D1B6_phys_0_eng_0_engtype_3D
            int i = name.IndexOf("luid_", StringComparison.OrdinalIgnoreCase);
            if (i < 0) return "";
            int j = name.IndexOf("_phys", i, StringComparison.OrdinalIgnoreCase);
            return j > i ? name.Substring(i, j - i) : name.Substring(i);
        }

        private void ReadNet(double t, double dt, double a)
        {
            if (t - _nicsAt > 5)
            {
                _nicsAt = t;
                try
                {
                    _nics = NetworkInterface.GetAllNetworkInterfaces().Where(IsCounted).ToArray();
                }
                catch { _nics = Array.Empty<NetworkInterface>(); }
                string key = string.Join("|", _nics.Select(n => n.Id));
                if (key != _nicKey) { _nicKey = key; _lastRx = _lastTx = -1; }
            }

            long rx = 0, tx = 0;
            foreach (var n in _nics)
            {
                try
                {
                    var st = n.GetIPStatistics();
                    rx += st.BytesReceived;
                    tx += st.BytesSent;
                }
                catch { /* adapter vanished: the list refreshes within 5 s */ }
            }

            if (_lastRx >= 0 && dt > 0 && rx >= _lastRx && tx >= _lastTx)
            {
                _down = Smooth(_down, (rx - _lastRx) / dt, a);
                _up = Smooth(_up, (tx - _lastTx) / dt, a);
            }
            else if (_lastRx >= 0 && double.IsNaN(_down))
            {
                _down = _up = 0;
            }
            _lastRx = rx;
            _lastTx = tx;
        }

        /// <summary>Real adapters only: virtual switches and VPN tunnels would count the same bytes twice.</summary>
        private static bool IsCounted(NetworkInterface n)
        {
            if (n.OperationalStatus != OperationalStatus.Up) return false;
            if (n.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel or NetworkInterfaceType.Unknown) return false;
            string d = n.Description ?? "";
            foreach (var bad in ExcludedDescriptions)
                if (d.Contains(bad, StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }

        private static readonly string[] ExcludedDescriptions =
            { "Virtual", "Hyper-V", "VPN", "TAP-", "WireGuard", "Wintun", "Npcap", "Loopback", "Pseudo", "VMware", "VirtualBox" };

        public void Dispose()
        {
            if (_query != IntPtr.Zero) { PdhCloseQuery(_query); _query = IntPtr.Zero; }
            if (_gpuQuery != IntPtr.Zero) { PdhCloseQuery(_gpuQuery); _gpuQuery = IntPtr.Zero; }
            if (_buffer != IntPtr.Zero) { Marshal.FreeHGlobal(_buffer); _buffer = IntPtr.Zero; }
        }
    }
}
