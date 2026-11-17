using System.Windows.Threading;
using Isola.Core;
using Isola.Island;

namespace Isola.Backdrops;

/// <summary>The refracting backdrop bound to the island.</summary>
internal sealed class LiquidGlass : IDisposable
{
    private readonly IIslandBackdropSite _site;
    private readonly Action _onFailed;
    private readonly bool _capturable;
    private BackdropWindow? _window;
    private LiquidRenderer? _renderer;
    private bool _affinitySet;
    private readonly ShapeDelay _delay;

    public LiquidGlass(IIslandBackdropSite site, Action onFailed)
    {
        _site = site;
        _onFailed = onFailed;
        _delay = new ShapeDelay(Apply, ShapeDelay.DefaultFrames(1.5));
        _capturable = Environment.GetEnvironmentVariable("ISOLA_GLASS_CAPTURABLE") == "1";
    }

    public void Start()
    {
        if (_site.IslandHwnd == IntPtr.Zero) throw new InvalidOperationException("L'isola non ha ancora una finestra");
        _window = new BackdropWindow(_site.IslandHwnd, _site.Dispatcher, noRedirectionBitmap: true) { RegionGrow = 2 };

        // Both windows must be invisible to the capture, or the glass would see itself.
        if (!GlassNative.SetWindowDisplayAffinity(_window.Hwnd, GlassNative.WDA_EXCLUDEFROMCAPTURE) ||
            !GlassNative.SetWindowDisplayAffinity(_site.IslandHwnd, GlassNative.WDA_EXCLUDEFROMCAPTURE))
            throw new InvalidOperationException("WDA_EXCLUDEFROMCAPTURE non supportato");
        _affinitySet = true;

        _renderer = new LiquidRenderer(_window.Hwnd, _window.Rect, captureOnce: _capturable);
        _renderer.Failed += _ => _onFailed();
        if (_capturable)
        {
            // Test mode: once the background has been grabbed, let screenshots see the island.
            _renderer.FirstFrame += () => _site.Dispatcher.BeginInvoke(DispatcherPriority.Normal, ClearAffinity);
        }
        _window.Moved += r => _renderer?.SetWindowRect(r);

        // The shader draws tint and rim too (same frame as the refraction = consistent edges).
        _site.SetIslandFill(GlassStyle.HitFill());
        _site.SetIslandEdge(null, 0);
        _site.ShapeChanged += OnShapeChanged;
        Apply(_site.CurrentShape);
        Log.Info($"Liquido attivo{(_capturable ? " (ISOLA_GLASS_CAPTURABLE: cattura una volta sola)" : "")}");
    }

    private void OnShapeChanged(object? sender, IslandShapeInfo shape) => _delay.Push(shape);

    private void Apply(IslandShapeInfo shape)
    {
        if (_window == null || _renderer == null) return;
        _window.Update(shape);
        _renderer.SetPaused(!shape.IsVisible);
        if (!shape.IsVisible) return;
        var r = _window.Rect;
        _renderer.SetShape(ShapeOutline.From(shape, r.Left, r.Top), shape.DpiScale);
    }

    private void ClearAffinity()
    {
        if (!_affinitySet) return;
        _affinitySet = false;
        if (_window != null) GlassNative.SetWindowDisplayAffinity(_window.Hwnd, GlassNative.WDA_NONE);
        if (_site.IslandHwnd != IntPtr.Zero) GlassNative.SetWindowDisplayAffinity(_site.IslandHwnd, GlassNative.WDA_NONE);
    }

    public long FramesRendered => _renderer?.FramesRendered ?? 0;

    public void Dispose()
    {
        _site.ShapeChanged -= OnShapeChanged;
        _delay.Dispose();
        _renderer?.Dispose();
        _renderer = null;
        ClearAffinity();
        _window?.Dispose();
        _window = null;
    }
}
