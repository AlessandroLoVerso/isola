using System.Windows;
using System.Windows.Threading;
using Isola.Core;
using Isola.Island;
using Isola.Settings;

namespace Isola.Backdrops;

// The two glass themes. Discovered by ThemeManager through reflection, in this order.

/// <summary>Theme "Vetro": frosted glass. A separate, non-layered window under the island (DWM
/// materials don't work on the island's AllowsTransparency window) shows a blur of what is
/// behind it, a dark tint and a light rim, cut to the island's outline on every frame.
/// Windows 11: Windows.UI.Composition HostBackdropBrush (<see cref="HostBackdropVisuals"/>).
/// Windows 10: ACCENT_ENABLE_ACRYLICBLURBEHIND + SetWindowRgn, tint and rim drawn by the island.
/// Idle cost: nothing runs while the island is still.</summary>
public sealed class VetroBackdrop : IIslandBackdrop, IIslandBackdropPalette
{
    private AcrylicGlass? _glass;

    public string Id => "vetro";

    public string Name => "Vetro";

    public void Attach(IIslandBackdropSite site)
    {
        _glass = new AcrylicGlass(site);
        _glass.Start();
    }

    public void Detach()
    {
        _glass?.Dispose();
        _glass = null;
    }

    public void OverrideResources(ResourceDictionary resources) => GlassStyle.OverrideSurfaces(resources);
}

/// <summary>Theme "Liquido": real refraction of what's behind the island (Desktop Duplication +
/// D3D11 shader + DirectComposition, see <see cref="LiquidRenderer"/>).
/// Needs the island hidden from screen capture; with "Mostra l'isola negli screenshot" on, or
/// if the GPU path fails, it falls back to the acrylic of "Vetro".
/// Dev: ISOLA_GLASS_CAPTURABLE=1 captures the background once and then lets screenshots see
/// the island (for testing only; the glass stops following what's behind it).</summary>
public sealed class LiquidoBackdrop : IIslandBackdrop, IIslandBackdropPalette
{
    private IIslandBackdropSite? _site;
    private GlobalSettingsStore? _settings;
    private LiquidGlass? _liquid;
    private AcrylicGlass? _fallback;
    private bool _gpuFailed;

    public string Id => "liquido";

    public string Name => "Liquido";

    public void Attach(IIslandBackdropSite site)
    {
        _site = site;
        _gpuFailed = false;
        _settings = GlobalSettingsStore.Instance;
        if (_settings != null) _settings.Changed += OnSettingsChanged;
        Rebuild();
    }

    public void Detach()
    {
        if (_settings != null) _settings.Changed -= OnSettingsChanged;
        _settings = null;
        _liquid?.Dispose();
        _liquid = null;
        _fallback?.Dispose();
        _fallback = null;
        _site = null;
    }

    public void OverrideResources(ResourceDictionary resources) => GlassStyle.OverrideSurfaces(resources);

    private void OnSettingsChanged(object? sender, EventArgs e) => Rebuild();

    private void Rebuild()
    {
        if (_site == null) return;
        bool wantLiquid = !_gpuFailed && !(_settings?.Current.ShowInScreenshots ?? false);

        if (wantLiquid && _liquid == null)
        {
            _fallback?.Dispose();
            _fallback = null;
            try
            {
                _liquid = new LiquidGlass(_site, OnGpuFailed);
                _liquid.Start();
            }
            catch (Exception ex)
            {
                Log.Error("Liquido non disponibile, uso Vetro", ex);
                _liquid?.Dispose();
                _liquid = null;
                _gpuFailed = true;
                wantLiquid = false;
            }
        }

        if (!wantLiquid && _fallback == null)
        {
            _liquid?.Dispose();
            _liquid = null;
            _fallback = new AcrylicGlass(_site);
            _fallback.Start();
        }
    }

    private void OnGpuFailed()
    {
        var site = _site;
        site?.Dispatcher.BeginInvoke(DispatcherPriority.Normal, () =>
        {
            if (_site == null || !ReferenceEquals(_site, site)) return;
            _gpuFailed = true;
            try { Rebuild(); }
            catch (Exception ex) { Log.Error("Liquido: anche Vetro non è partito", ex); }
        });
    }
}
