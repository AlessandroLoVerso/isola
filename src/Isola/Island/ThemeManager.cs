using System.Reflection;
using System.Windows;
using System.Windows.Media;
using Isola.Core;

namespace Isola.Island;

public sealed record ThemeOption(string Id, string Name);

/// <summary>Applies the island theme by replacing the Isola.Brush.* resources (modules use them
/// through DynamicResource) and attaches/detaches IIslandBackdrop themes.</summary>
public static class ThemeManager
{
    private sealed record Palette(Color Background, Color Foreground, Color Muted, Color Accent, Color Surface, Color SurfaceHover);

    private static readonly Palette Nero = new(
        Rgb(0x0B, 0x0B, 0x0D), Rgb(0xF5, 0xF5, 0xF7), Rgb(0x8E, 0x8E, 0x96),
        Rgb(0x0A, 0x84, 0xFF), Rgb(0x1C, 0x1C, 0x21), Rgb(0x26, 0x26, 0x2C));

    private static readonly Palette Grafite = new(
        Rgb(0x2A, 0x2B, 0x30), Rgb(0xF5, 0xF5, 0xF7), Rgb(0xA3, 0xA4, 0xAC),
        Rgb(0x0A, 0x84, 0xFF), Rgb(0x3A, 0x3B, 0x42), Rgb(0x45, 0x46, 0x4E));

    private static List<IIslandBackdrop>? _backdrops;
    private static IIslandBackdrop? _active;
    private static IIslandBackdropSite? _site;

    public static string CurrentId { get; private set; } = "nero";

    public static IReadOnlyList<ThemeOption> Options
    {
        get
        {
            var list = new List<ThemeOption> { new("nero", "Nero"), new("grafite", "Grafite") };
            foreach (var b in Backdrops)
            {
                try { list.Add(new ThemeOption(b.Id.ToLowerInvariant(), b.Name)); }
                catch (Exception ex) { Log.Error("Backdrop non valido", ex); }
            }
            return list;
        }
    }

    private static List<IIslandBackdrop> Backdrops => _backdrops ??= DiscoverBackdrops();

    public static void Initialize(IIslandBackdropSite site) => _site = site;

    public static void Apply(string? id)
    {
        id = (id ?? "nero").Trim().ToLowerInvariant();
        var backdrop = Backdrops.FirstOrDefault(b => SafeId(b) == id);
        if (id != "nero" && id != "grafite" && backdrop == null) id = "nero";

        SetPalette(id == "grafite" ? Grafite : Nero);

        if (!ReferenceEquals(_active, backdrop))
        {
            DetachActive();
            if (backdrop != null && _site != null)
            {
                try
                {
                    backdrop.Attach(_site);
                    _active = backdrop;
                }
                catch (Exception ex)
                {
                    Log.Error($"Backdrop '{id}' non avviato, torno a Nero", ex);
                    _site.SetIslandFill(null);
                    _site.SetIslandEdge(null, 0);
                    id = "nero";
                }
            }
        }
        if (_active is IIslandBackdropPalette bp)
        {
            try { bp.OverrideResources(System.Windows.Application.Current.Resources); }
            catch (Exception ex) { Log.Error("Palette del backdrop non applicata", ex); }
        }
        CurrentId = id;
    }

    public static void Shutdown() => DetachActive();

    private static void DetachActive()
    {
        if (_active == null) return;
        try { _active.Detach(); }
        catch (Exception ex) { Log.Error("Errore staccando il backdrop", ex); }
        _active = null;
        _site?.SetIslandFill(null);
        _site?.SetIslandEdge(null, 0);
    }

    private static void SetPalette(Palette p)
    {
        var res = System.Windows.Application.Current.Resources;
        res["Isola.Brush.Background"] = Frozen(p.Background);
        res["Isola.Brush.Foreground"] = Frozen(p.Foreground);
        res["Isola.Brush.Muted"] = Frozen(p.Muted);
        res["Isola.Brush.Accent"] = Frozen(p.Accent);
        res["Isola.Brush.Surface"] = Frozen(p.Surface);
        res["Isola.Brush.SurfaceHover"] = Frozen(p.SurfaceHover);
    }

    private static string SafeId(IIslandBackdrop b)
    {
        try { return b.Id.Trim().ToLowerInvariant(); } catch { return ""; }
    }

    private static List<IIslandBackdrop> DiscoverBackdrops()
    {
        var list = new List<IIslandBackdrop>();
        Type[] types;
        try { types = Assembly.GetExecutingAssembly().GetTypes(); }
        catch (ReflectionTypeLoadException ex) { types = ex.Types.Where(t => t != null).ToArray()!; }
        foreach (var t in types)
        {
            if (t.IsAbstract || t.IsInterface || !typeof(IIslandBackdrop).IsAssignableFrom(t)) continue;
            if (t.GetConstructor(Type.EmptyTypes) is not { IsPublic: true }) continue;
            try { list.Add((IIslandBackdrop)Activator.CreateInstance(t)!); }
            catch (Exception ex) { Log.Error($"Backdrop {t.FullName} non creato", ex); }
        }
        return list;
    }

    private static SolidColorBrush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    private static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);
}
