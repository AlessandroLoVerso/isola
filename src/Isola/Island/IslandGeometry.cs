using System.Windows;
using System.Windows.Media;

namespace Isola.Island;

/// <summary>Outline of the island in window DIPs.
/// TopCorner is a signed radius: &gt; 0 = convex rounded top corners (shape "isola"),
/// &lt; 0 = outward concave flares at the top corners (shape "notch", like a MacBook notch).
/// Animating it through 0 morphs one into the other.</summary>
internal readonly record struct IslandOutline(double CenterX, double Top, double Width, double Height,
    double BottomRadius, double TopCorner)
{
    public double Flare => Math.Max(0, Math.Min(-TopCorner, Math.Max(0, Height) / 2));

    /// <summary>Visible bounds including the flares.</summary>
    public Rect Bounds
    {
        get
        {
            double w = Math.Max(0, Width), h = Math.Max(0, Height), f = Flare;
            return new Rect(CenterX - w / 2 - f, Top, w + 2 * f, h);
        }
    }

    public Geometry Build()
    {
        double w = Math.Max(0, Width), h = Math.Max(0, Height);
        if (w < 0.5 || h < 0.5) return Geometry.Empty;

        double x0 = CenterX - w / 2, x1 = CenterX + w / 2, y0 = Top, y1 = Top + h;
        double rt = Math.Min(Math.Max(0, TopCorner), Math.Min(w / 2, h / 2));
        double f = Flare;
        double rb = Math.Max(0, Math.Min(BottomRadius, Math.Min(w / 2, h - Math.Max(rt, f))));

        var g = new StreamGeometry { FillRule = FillRule.Nonzero };
        using (var c = g.Open())
        {
            if (f > 0.01)
            {
                c.BeginFigure(new Point(x0 - f, y0), true, true);
                c.LineTo(new Point(x1 + f, y0), true, false);
                c.ArcTo(new Point(x1, y0 + f), new Size(f, f), 0, false, SweepDirection.Counterclockwise, true, false);
            }
            else
            {
                c.BeginFigure(new Point(x0 + rt, y0), true, true);
                c.LineTo(new Point(x1 - rt, y0), true, false);
                if (rt > 0.01)
                    c.ArcTo(new Point(x1, y0 + rt), new Size(rt, rt), 0, false, SweepDirection.Clockwise, true, false);
            }

            c.LineTo(new Point(x1, y1 - rb), true, false);
            if (rb > 0.01)
                c.ArcTo(new Point(x1 - rb, y1), new Size(rb, rb), 0, false, SweepDirection.Clockwise, true, false);
            c.LineTo(new Point(x0 + rb, y1), true, false);
            if (rb > 0.01)
                c.ArcTo(new Point(x0, y1 - rb), new Size(rb, rb), 0, false, SweepDirection.Clockwise, true, false);

            if (f > 0.01)
            {
                c.LineTo(new Point(x0, y0 + f), true, false);
                c.ArcTo(new Point(x0 - f, y0), new Size(f, f), 0, false, SweepDirection.Counterclockwise, true, false);
            }
            else
            {
                c.LineTo(new Point(x0, y0 + rt), true, false);
                if (rt > 0.01)
                    c.ArcTo(new Point(x0 + rt, y0), new Size(rt, rt), 0, false, SweepDirection.Clockwise, true, false);
            }
        }
        g.Freeze();
        return g;
    }
}
