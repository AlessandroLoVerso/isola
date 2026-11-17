using System.Windows.Media;
using Isola.Core;
using Isola.Island;

namespace Isola.Backdrops;

/// <summary>The acrylic backdrop window bound to the island (also Liquido's fallback).</summary>
internal sealed class AcrylicGlass : IDisposable
{
    private readonly IIslandBackdropSite _site;
    private BackdropWindow? _window;
    private HostBackdropVisuals? _visuals;
    private readonly ShapeDelay _delay;

    public AcrylicGlass(IIslandBackdropSite site)
    {
        _site = site;
        _delay = new ShapeDelay(s => Apply(s), ShapeDelay.DefaultFrames(1.5));
    }

    public void Start()
    {
        if (_site.IslandHwnd == IntPtr.Zero) throw new InvalidOperationException("L'isola non ha ancora una finestra");
        var material = BackdropMaterial.HostBackdrop;
        try
        {
            // Windows 10 (and 11 21H2): the spec'd DWM acrylic accent + WPF tint. Windows 11: composition.
            if (GlassNative.Build < 22000) throw new NotSupportedException("Windows 10: uso l'accent acrylic");
            if (Environment.GetEnvironmentVariable("ISOLA_GLASS_MATERIAL") is "accent" or "system") throw new NotSupportedException("forzato da ISOLA_GLASS_MATERIAL");
            _window = new BackdropWindow(_site.IslandHwnd, _site.Dispatcher, noRedirectionBitmap: true) { RegionGrow = 2 };
            GlassNative.SetDwm(_window.Hwnd, GlassNative.DWMWA_USE_HOSTBACKDROPBRUSH, 1);
            _visuals = new HostBackdropVisuals(_window.Hwnd, _window.Rect.Width, _window.Rect.Height, GlassStyle.VetroLook());
            _window.Moved += r => _visuals?.Resize(r.Width, r.Height);
        }
        catch (Exception ex)
        {
            Log.Warn($"Vetro: composizione non disponibile, uso l'acrylic di DWM ({ex.Message})", ex is NotSupportedException ? null : ex);
            _visuals?.Dispose();
            _visuals = null;
            _window?.Dispose();
            _window = new BackdropWindow(_site.IslandHwnd, _site.Dispatcher, noRedirectionBitmap: false);
            material = _window.ApplyAcrylic(GlassStyle.Win10TintAbgr);
        }
        Log.Info($"Vetro attivo ({material}, build {GlassNative.Build})");

        if (material == BackdropMaterial.HostBackdrop)
        {
            // Blur, tint and rim are all drawn behind the island, in one composition tree.
            _site.SetIslandFill(GlassStyle.HitFill());
            _site.SetIslandEdge(null, 0);
        }
        else
        {
            _site.SetIslandFill(material == BackdropMaterial.None ? null : GlassStyle.VetroFill());
            _site.SetIslandEdge(GlassStyle.Rim(), 1 / Math.Max(1, _site.CurrentShape.DpiScale));
        }
        _site.ShapeChanged += OnShapeChanged;
        Apply(_site.CurrentShape);
    }

    private void Apply(in IslandShapeInfo shape)
    {
        if (_window == null) return;
        _window.Update(shape);
        if (_visuals != null && shape.IsVisible)
            _visuals.Update(ShapeOutline.From(shape, _window.Rect.Left, _window.Rect.Top));
    }

    private void OnShapeChanged(object? sender, IslandShapeInfo shape)
    {
        if (_window != null) _delay.Push(shape);
    }

    public void Dispose()
    {
        _site.ShapeChanged -= OnShapeChanged;
        _delay.Dispose();
        _visuals?.Dispose();
        _visuals = null;
        _window?.Dispose();
        _window = null;
    }
}
