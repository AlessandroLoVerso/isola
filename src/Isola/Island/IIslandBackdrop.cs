using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace Isola.Island;

/// <summary>Current visible shape of the island, in SCREEN PIXELS.</summary>
/// <param name="Bounds">Visible bounds (flares of the notch included).</param>
/// <param name="BodyBounds">The body without the notch flares.</param>
/// <param name="BottomRadius">Radius of the bottom corners, px.</param>
/// <param name="TopCorner">Signed top corner radius, px: &gt; 0 rounded (isola), &lt; 0 notch flare.</param>
/// <param name="IsVisible">False while the island is hidden (e.g. above a fullscreen app).</param>
/// <param name="DpiScale">Pixels per DIP of the island's monitor.</param>
public readonly record struct IslandShapeInfo(Rect Bounds, Rect BodyBounds, double BottomRadius,
    double TopCorner, bool IsVisible, double DpiScale)
{
    /// <summary>Convenience: the corner radius to use for a plain rounded rectangle.</summary>
    public double CornerRadius => BottomRadius;
}

/// <summary>Extension point for themes that need their own backdrop window behind the island
/// (e.g. a later "Vetro"/glass theme with Acrylic or a capture + shader). Implementations are
/// discovered by reflection (public, non-abstract, parameterless ctor) and appear in the
/// "Tema" list of the Settings window with their Name. While attached, the backdrop follows the
/// island through <see cref="IIslandBackdropSite.ShapeChanged"/>.</summary>
public interface IIslandBackdrop
{
    /// <summary>Stable lowercase id stored in settings.json ("vetro").</summary>
    string Id { get; }

    /// <summary>Italian name shown in Settings ("Vetro").</summary>
    string Name { get; }

    /// <summary>Called on the UI thread when the user picks this theme.</summary>
    void Attach(IIslandBackdropSite site);

    /// <summary>Called on the UI thread when another theme is picked or the app exits.</summary>
    void Detach();
}

/// <summary>What the island exposes to a backdrop.</summary>
public interface IIslandBackdropSite
{
    Dispatcher Dispatcher { get; }

    /// <summary>The island window. Put the backdrop window just below it in Z order.</summary>
    IntPtr IslandHwnd { get; }

    IslandShapeInfo CurrentShape { get; }

    /// <summary>Raised on every animation frame, on move/DPI change and on show/hide.</summary>
    event EventHandler<IslandShapeInfo>? ShapeChanged;

    /// <summary>Overrides the island's fill (e.g. a translucent tint so the backdrop shows
    /// through). Null restores the theme background.</summary>
    void SetIslandFill(Brush? fill);

    /// <summary>Draws a line of <paramref name="thickness"/> DIP just inside the island's outline
    /// (e.g. a light rim for glass), under the content. Null removes it.</summary>
    void SetIslandEdge(Brush? brush, double thickness);
}

/// <summary>Optional, for backdrops: adjust the Isola.Brush.* resources after the base palette
/// ("Nero") was applied, e.g. translucent surfaces on glass. Called on every theme apply.</summary>
public interface IIslandBackdropPalette
{
    void OverrideResources(ResourceDictionary resources);
}
