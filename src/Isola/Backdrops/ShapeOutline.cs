using Isola.Island;

namespace Isola.Backdrops;

/// <summary>The island outline in pixels relative to a window origin, resolved exactly like
/// <c>IslandOutline.Build()</c> (same clamping of the radii), so the backdrop region and the
/// shader match the WPF path the island paints.</summary>
internal readonly record struct ShapeOutline(double X0, double Y0, double X1, double Y1,
    double TopRadius, double Flare, double BottomRadius)
{
    public double Width => X1 - X0;
    public double Height => Y1 - Y0;
    public bool IsEmpty => Width < 1 || Height < 1;

    public static ShapeOutline From(in IslandShapeInfo s, int originX, int originY)
    {
        var b = s.BodyBounds;
        double w = Math.Max(0, b.Width), h = Math.Max(0, b.Height);
        double rt = Math.Min(Math.Max(0, s.TopCorner), Math.Min(w / 2, h / 2));
        double f = Math.Max(0, Math.Min(-s.TopCorner, h / 2));
        double rb = Math.Max(0, Math.Min(s.BottomRadius, Math.Min(w / 2, h - Math.Max(rt, f))));
        return new ShapeOutline(b.Left - originX, b.Top - originY, b.Left - originX + w, b.Top - originY + h, rt, f, rb);
    }

    /// <summary>Closed polygon (clockwise on screen) approximating the outline.
    /// <paramref name="grow"/> moves every edge outwards by that many pixels.</summary>
    public GlassNative.POINT[] ToPolygon(double grow = 0)
    {
        var pts = new List<GlassNative.POINT>(96);
        double x0 = X0 - grow, x1 = X1 + grow, y0 = Y0 - (Flare > 0.01 ? 0 : grow), y1 = Y1 + grow;
        double rt = TopRadius > 0.01 ? TopRadius + grow : 0;
        double rb = BottomRadius > 0.01 ? BottomRadius + grow : 0;
        double f = Flare > 0.01 ? Math.Max(0.5, Flare - grow) : 0;

        void Add(double x, double y)
        {
            var p = new GlassNative.POINT((int)Math.Round(x), (int)Math.Round(y));
            if (pts.Count > 0 && pts[^1].X == p.X && pts[^1].Y == p.Y) return;
            pts.Add(p);
        }

        void Arc(double cx, double cy, double r, double fromDeg, double toDeg)
        {
            int n = Math.Clamp((int)Math.Ceiling(r / 1.2), 2, 40);
            for (int i = 0; i <= n; i++)
            {
                double a = (fromDeg + (toDeg - fromDeg) * i / n) * Math.PI / 180;
                Add(cx + r * Math.Cos(a), cy + r * Math.Sin(a));
            }
        }

        if (f > 0)
        {
            Add(x0 - f, y0);
            Add(x1 + f, y0);
            Arc(x1 + f, y0 + f, f, -90, -180);
        }
        else
        {
            Add(x0 + rt, y0);
            Add(x1 - rt, y0);
            if (rt > 0) Arc(x1 - rt, y0 + rt, rt, -90, 0);
        }

        Add(x1, y1 - rb);
        if (rb > 0) Arc(x1 - rb, y1 - rb, rb, 0, 90);
        Add(x0 + rb, y1);
        if (rb > 0) Arc(x0 + rb, y1 - rb, rb, 90, 180);

        if (f > 0)
        {
            Add(x0, y0 + f);
            Arc(x0 - f, y0 + f, f, 0, -90);
        }
        else
        {
            Add(x0, y0 + rt);
            if (rt > 0) Arc(x0 + rt, y0 + rt, rt, 180, 270);
        }
        return pts.ToArray();
    }
}
