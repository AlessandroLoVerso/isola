using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Isola.Backdrops;

/// <summary>Brushes shared by the glass themes.</summary>
internal static class GlassStyle
{
    /// <summary>Tint over the acrylic: dark enough for white text on any wallpaper.</summary>
    public static Brush VetroFill() => Frozen(new LinearGradientBrush(
        new GradientStopCollection
        {
            new(Argb(EnvColor("ISOLA_GLASS_TINT_TOP", 0x7A, 0x14, 0x14, 0x18)), 0),
            new(Argb(EnvColor("ISOLA_GLASS_TINT", 0x99, 0x0C, 0x0C, 0x0F)), 0.55),
            new(Argb(EnvColor("ISOLA_GLASS_TINT", 0x99, 0x0C, 0x0C, 0x0F)), 1),
        }, new Point(0, 0), new Point(0, 1)));

    /// <summary>Composition glass of "Vetro": tint and rim drawn with the blur (see
    /// HostBackdropVisuals). Same colours as <see cref="VetroFill"/> / <see cref="Rim"/>.</summary>
    public static GlassLook VetroLook()
    {
        var top = EnvColor("ISOLA_GLASS_TINT_TOP", 0x7A, 0x14, 0x14, 0x18);
        var body = EnvColor("ISOLA_GLASS_TINT", 0x99, 0x0C, 0x0C, 0x0F);
        static Windows.UI.Color W((byte A, byte R, byte G, byte B) c) => Windows.UI.Color.FromArgb(c.A, c.R, c.G, c.B);
        static Windows.UI.Color White(double a) => Windows.UI.Color.FromArgb(A(a), 255, 255, 255);
        return new GlassLook(
            new[] { (0f, W(top)), (0.55f, W(body)), (1f, W(body)) },
            new[] { (0f, White(0x70)), (0.35f, White(0x1E)), (0.7f, White(0x12)), (1f, White(0x2A)) });
    }

    /// <summary>Island fill when the glass is drawn behind it: invisible, but not fully
    /// transparent, so the layered island window still receives the mouse over its shape.</summary>
    public static Brush HitFill() => Frozen(new SolidColorBrush(Color.FromArgb(0x01, 0, 0, 0)));

    /// <summary>1 px inner rim: brighter on top (light from above), faint at the sides, a soft
    /// return at the bottom, like the edge of a pane of glass.</summary>
    public static Brush Rim(double strength = 1) => Frozen(new LinearGradientBrush(
        new GradientStopCollection
        {
            new(Color.FromArgb(A(0x66 * strength), 255, 255, 255), 0),
            new(Color.FromArgb(A(0x1C * strength), 255, 255, 255), 0.35),
            new(Color.FromArgb(A(0x10 * strength), 255, 255, 255), 0.7),
            new(Color.FromArgb(A(0x26 * strength), 255, 255, 255), 1),
        }, new Point(0, 0), new Point(0, 1)));

    /// <summary>Surfaces inside the island (tabs, buttons) become frosted white instead of the
    /// opaque greys of "Nero", so they don't punch dark holes in the glass.</summary>
    public static void OverrideSurfaces(ResourceDictionary res)
    {
        res["Isola.Brush.Surface"] = Frozen(new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)));
        res["Isola.Brush.SurfaceHover"] = Frozen(new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)));
        res["Isola.Brush.Muted"] = Frozen(new SolidColorBrush(Color.FromRgb(0xB4, 0xB4, 0xBC)));
    }

    /// <summary>Win10 accent tint, AABBGGRR.</summary>
    public const uint Win10TintAbgr = 0x660F0C0C;

    private static byte A(double v) => (byte)Math.Clamp(Math.Round(v), 0, 255);

    private static Color Argb((byte A, byte R, byte G, byte B) c) => Color.FromArgb(c.A, c.R, c.G, c.B);

    /// <summary>Dev knob: ISOLA_GLASS_TINT=AARRGGBB overrides a tint without rebuilding.</summary>
    private static (byte, byte, byte, byte) EnvColor(string name, byte a, byte r, byte g, byte b)
    {
        var v = Environment.GetEnvironmentVariable(name)?.Trim().TrimStart('#');
        if (v is { Length: 8 } && uint.TryParse(v, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out uint x))
            return ((byte)(x >> 24), (byte)(x >> 16), (byte)(x >> 8), (byte)x);
        return (a, r, g, b);
    }

    private static T Frozen<T>(T b) where T : Freezable
    {
        b.Freeze();
        return b;
    }
}
