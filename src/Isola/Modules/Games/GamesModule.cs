using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using Isola.Core;

namespace Isola.Modules.Games;

/// <summary>"Prestazioni": CPU, GPU, RAM and network. A slim strip above fullscreen apps (games,
/// videos) and a card with the last 60 s. Reads the counters only while one of the two is on
/// screen; otherwise no thread, no timer, no query exists.</summary>
public sealed class GamesModule : IIslandModule, IStripProvider
{
    private IIslandHost? _host;
    private GamesSettings _settings = new();
    private PerfViewModel? _vm;
    private PerfSampler? _sampler;
    private FrameworkElement? _card;
    private readonly List<Sparkline> _sparklines = new();
    private readonly HashSet<FrameworkElement> _visibleStrips = new();
    private bool _lastWantsStrip;

    // Hand-off from the sampler thread: the newest reading, applied at most once per UI pass.
    private readonly object _pendingLock = new();
    private PerfSnapshot? _pending;
    private bool _posted;
    private int _generation;

    public string Id => "games";
    public string Title => "Prestazioni";
    public string Glyph => "";
    public int Order => 70;
    public bool EnabledByDefault => true;

    public bool WantsStrip => _host != null && _settings.AnyMetric && _host.IsFullscreenAppActive;

    public void Start(IIslandHost host)
    {
        _host = host;
        _settings = host.LoadSettings<GamesSettings>(Id);
        _settings.Normalize();
        _vm = new PerfViewModel();
        _vm.ApplySettings(_settings);
        _vm.HistoryChanged += OnHistoryChanged;
        _sampler = new PerfSampler(OnSample, msg => _host?.Log(Id, msg));
        host.FullscreenChanged += OnFullscreenChanged;
        _lastWantsStrip = WantsStrip;
    }

    public void Stop()
    {
        if (_host != null) _host.FullscreenChanged -= OnFullscreenChanged;
        _sampler?.Stop();
        _sampler = null;
        Interlocked.Increment(ref _generation);
        if (_vm != null) _vm.HistoryChanged -= OnHistoryChanged;
        _vm = null;
        _card = null;
        _sparklines.Clear();
        _visibleStrips.Clear();
        _host = null;
    }

    // ---- Demand --------------------------------------------------------------------------

    private void OnFullscreenChanged(object? sender, EventArgs e)
    {
        RefreshWantsStrip();
        UpdateDemand();
    }

    private void RefreshWantsStrip()
    {
        bool w = WantsStrip;
        if (w == _lastWantsStrip) return;
        _lastWantsStrip = w;
        _host?.RefreshRestingFace();
    }

    /// <summary>Sampling runs only while the card is visible, or while a strip is visible above a
    /// fullscreen app. Called whenever one of those changes.</summary>
    private void UpdateDemand()
    {
        if (_host == null || _sampler == null) return;
        bool cardOn = _card is { IsVisible: true };
        bool stripOn = _host.IsFullscreenAppActive && _visibleStrips.Count > 0;
        bool want = _settings.AnyMetric && (cardOn || stripOn);
        if (want && !_sampler.IsRunning) _sampler.Start(Options());
        else if (!want && _sampler.IsRunning) _sampler.Stop();
    }

    private SamplerOptions Options()
        => new(_settings.ShowCpu, _settings.ShowGpu, _settings.ShowRam, _settings.ShowNet, _settings.RateHz);

    private void RestartSampler()
    {
        if (_sampler is not { IsRunning: true }) { UpdateDemand(); return; }
        _sampler.Stop();
        UpdateDemand();
    }

    private void OnSample(PerfSnapshot s)
    {
        // Sampler thread.
        var host = _host;
        if (host == null) return;
        int gen = Volatile.Read(ref _generation);
        lock (_pendingLock)
        {
            _pending = s;
            if (_posted) return;
            _posted = true;
        }
        host.Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            PerfSnapshot? p;
            lock (_pendingLock)
            {
                p = _pending;
                _pending = null;
                _posted = false;
            }
            if (gen != Volatile.Read(ref _generation) || _vm == null || p == null) return;
            _vm.Apply(p.Value);
        });
    }

    private void OnHistoryChanged(object? sender, EventArgs e)
    {
        if (_card is not { IsVisible: true }) return;
        foreach (var s in _sparklines) s.InvalidateVisual();
    }

    // ---- Strip ---------------------------------------------------------------------------

    public FrameworkElement CreateStrip()
    {
        var strip = PerfViews.BuildStrip(_vm!);
        strip.IsVisibleChanged += (_, e) =>
        {
            if ((bool)e.NewValue) _visibleStrips.Add(strip);
            else _visibleStrips.Remove(strip);
            UpdateDemand();
        };
        return strip;
    }

    // ---- Card ----------------------------------------------------------------------------

    public FrameworkElement? CreateCard()
    {
        _sparklines.Clear();
        var card = PerfViews.BuildCard(_vm!, _sparklines);
        card.IsVisibleChanged += (_, _) =>
        {
            UpdateDemand();
            if (card.IsVisible) foreach (var s in _sparklines) s.InvalidateVisual();
        };
        _card = card;
        return card;
    }

    // ---- Settings ------------------------------------------------------------------------

    public FrameworkElement? CreateSettingsPage()
        => PerfViews.BuildSettings(_settings, Changed);

    private void Changed(bool samplerAffected)
    {
        _settings.Normalize();
        _host?.SaveSettings(Id, _settings);
        _vm?.ApplySettings(_settings);
        RefreshWantsStrip();
        if (samplerAffected) RestartSampler();
        else UpdateDemand();
    }
}

public sealed class GamesSettings
{
    public bool ShowCpu { get; set; } = true;
    public bool ShowGpu { get; set; } = true;
    public bool ShowRam { get; set; } = true;
    public bool ShowNet { get; set; } = true;
    public bool ShowBars { get; set; } = true;
    /// <summary>Readings per second: 2, 5 or 10.</summary>
    public int RateHz { get; set; } = 5;

    internal bool AnyMetric => ShowCpu || ShowGpu || ShowRam || ShowNet;

    internal void Normalize()
    {
        RateHz = RateHz switch { <= 2 => 2, <= 5 => 5, _ => 10 };
    }
}
