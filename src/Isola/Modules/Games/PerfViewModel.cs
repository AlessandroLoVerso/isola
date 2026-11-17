using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;

namespace Isola.Modules.Games;

/// <summary>Formatted values for the strip and the card. Lives on the UI thread.</summary>
internal sealed class PerfViewModel : INotifyPropertyChanged
{
    private static readonly CultureInfo It = CultureInfo.GetCultureInfo("it-IT");
    public const int HistoryLength = 120;              // 60 s at one point every 0.5 s
    private const double HistoryStepSeconds = 0.5;

    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>Raised when a point was added to the histories (at most twice a second).</summary>
    public event EventHandler? HistoryChanged;

    public string Cpu { get; private set; } = "–";
    public string Gpu { get; private set; } = "–";
    public string Ram { get; private set; } = "–";
    public string RamDetail { get; private set; } = "";
    public string Down { get; private set; } = "–";
    public string Up { get; private set; } = "–";
    public double CpuFraction { get; private set; }
    public double GpuFraction { get; private set; }
    public double RamFraction { get; private set; }
    public double DownFraction { get; private set; }

    public bool ShowCpu { get; private set; } = true;
    public bool ShowGpu { get; private set; } = true;
    public bool ShowRam { get; private set; } = true;
    public bool ShowNet { get; private set; } = true;
    public bool ShowBars { get; private set; } = true;

    public History CpuHistory { get; } = new(HistoryLength);
    public History GpuHistory { get; } = new(HistoryLength);
    public History RamHistory { get; } = new(HistoryLength);
    public History DownHistory { get; } = new(HistoryLength);
    public History UpHistory { get; } = new(HistoryLength);

    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private double _lastPointAt = double.NegativeInfinity;
    private readonly List<string> _changed = new();

    public void ApplySettings(GamesSettings s)
    {
        Set(ShowCpu, s.ShowCpu, v => ShowCpu = v, nameof(ShowCpu));
        Set(ShowGpu, s.ShowGpu, v => ShowGpu = v, nameof(ShowGpu));
        Set(ShowRam, s.ShowRam, v => ShowRam = v, nameof(ShowRam));
        Set(ShowNet, s.ShowNet, v => ShowNet = v, nameof(ShowNet));
        Set(ShowBars, s.ShowBars, v => ShowBars = v, nameof(ShowBars));
        Flush();
    }

    public void Apply(PerfSnapshot p)
    {
        Set(Cpu, Percent(p.Cpu), v => Cpu = v, nameof(Cpu));
        Set(Gpu, Percent(p.Gpu), v => Gpu = v, nameof(Gpu));
        Set(Ram, Percent(p.RamPercent), v => Ram = v, nameof(Ram));
        Set(RamDetail, double.IsNaN(p.RamUsedGb) ? "" : string.Format(It, "{0:0.0} di {1:0.0} GB", p.RamUsedGb, p.RamTotalGb),
            v => RamDetail = v, nameof(RamDetail));
        Set(Down, Rate(p.DownBytesPerSec), v => Down = v, nameof(Down));
        Set(Up, Rate(p.UpBytesPerSec), v => Up = v, nameof(Up));
        Set(CpuFraction, Fraction(p.Cpu), v => CpuFraction = v, nameof(CpuFraction));
        Set(GpuFraction, Fraction(p.Gpu), v => GpuFraction = v, nameof(GpuFraction));
        Set(RamFraction, Fraction(p.RamPercent), v => RamFraction = v, nameof(RamFraction));
        Set(DownFraction, RateFraction(p.DownBytesPerSec), v => DownFraction = v, nameof(DownFraction));
        Flush();

        double t = _clock.Elapsed.TotalSeconds;
        if (t - _lastPointAt >= HistoryStepSeconds)
        {
            // A long pause (nothing was on screen): old points would draw a misleading line.
            if (t - _lastPointAt > 60) ClearHistories();
            _lastPointAt = t;
            CpuHistory.Add(p.Cpu);
            GpuHistory.Add(p.Gpu);
            RamHistory.Add(p.RamPercent);
            DownHistory.Add(p.DownBytesPerSec);
            UpHistory.Add(p.UpBytesPerSec);
            HistoryChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private void ClearHistories()
    {
        CpuHistory.Clear(); GpuHistory.Clear(); RamHistory.Clear(); DownHistory.Clear(); UpHistory.Clear();
    }

    private static string Percent(double v) => double.IsNaN(v) ? "–" : Math.Round(v).ToString("0", It) + "%";

    // Bars move in 2% steps: a redraw of the (software-rendered, layered) island costs more than reading.
    private static double Fraction(double v) => double.IsNaN(v) ? 0 : Quantize(v / 100);

    private static double Quantize(double f) => Math.Round(Math.Clamp(f, 0, 1) * 50) / 50;

    /// <summary>Log scale: 1 KB/s = 0, 100 MB/s = full.</summary>
    private static double RateFraction(double bytes)
        => double.IsNaN(bytes) || bytes < 1024 ? 0 : Quantize(Math.Log10(bytes / 1024) / 5);

    public static string Rate(double bytes)
    {
        if (double.IsNaN(bytes)) return "–";
        double kb = bytes / 1024;
        if (kb < 99.5) return kb.ToString("0", It) + " KB/s";
        // Two significant digits: the third one only flickers and costs a redraw each time.
        if (kb < 995) return (Math.Round(kb / 10) * 10).ToString("0", It) + " KB/s";
        double mb = kb / 1024;
        if (mb < 9.95) return mb.ToString("0.0", It) + " MB/s";
        if (mb < 999.5) return mb.ToString("0", It) + " MB/s";
        return (mb / 1024).ToString("0.0", It) + " GB/s";
    }

    private void Set<T>(T old, T value, Action<T> store, string name)
    {
        if (EqualityComparer<T>.Default.Equals(old, value)) return;
        store(value);
        _changed.Add(name);
    }

    private void Flush()
    {
        // Raise after all values are stored, so bindings read the new ones.
        foreach (var n in _changed) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
        _changed.Clear();
    }
}

/// <summary>Fixed-size ring of values, oldest first. NaN = gap.</summary>
internal sealed class History
{
    private readonly double[] _items;
    private int _start, _count;

    public History(int capacity) => _items = new double[capacity];

    public int Capacity => _items.Length;
    public int Count => _count;
    public double this[int i] => _items[(_start + i) % _items.Length];

    public void Add(double v)
    {
        if (_count < _items.Length) _items[(_start + _count++) % _items.Length] = v;
        else { _items[_start] = v; _start = (_start + 1) % _items.Length; }
    }

    public void Clear() { _start = 0; _count = 0; }

    public double Max()
    {
        double m = 0;
        for (int i = 0; i < _count; i++) if (!double.IsNaN(this[i])) m = Math.Max(m, this[i]);
        return m;
    }
}
