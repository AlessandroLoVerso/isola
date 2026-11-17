using System.Windows;
using System.Windows.Media;
using Isola.Island;

namespace Isola.Backdrops;

/// <summary>Applies island outlines slightly late, to line the backdrop up with the island.
/// The island is a layered WPF window: a frame computed in CompositionTarget.Rendering reaches
/// the screen through the render thread and UpdateLayeredWindow about 1.5 WPF frames after a
/// composition / swap-chain change made in the same tick would (measured on a 180 Hz screen
/// with burst captures: 1 frame leaves the glass ahead, 2 leaves it behind). The delay is
/// fractional: the outline is interpolated between the two recorded ticks around it.
/// Hooked to Rendering only while outlines are pending, so it costs nothing at rest.
/// Hiding is never delayed.</summary>
internal sealed class ShapeDelay : IDisposable
{
    private readonly Action<IslandShapeInfo> _apply;
    private readonly List<(long Tick, IslandShapeInfo Shape)> _history = new();
    private long _tick;
    private TimeSpan _lastRender;
    private bool _hooked;

    public ShapeDelay(Action<IslandShapeInfo> apply, double frames)
    {
        _apply = apply;
        Frames = frames;
    }

    /// <summary>WPF frames of delay (0 = apply at once).</summary>
    public double Frames { get; set; }

    /// <summary>Default delay; ISOLA_GLASS_DELAY=n (frames, may be fractional) overrides it.</summary>
    public static double DefaultFrames(double fallback)
        => double.TryParse(Environment.GetEnvironmentVariable("ISOLA_GLASS_DELAY"), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out double d) ? Math.Clamp(d, 0, 6) : fallback;

    public void Push(in IslandShapeInfo shape)
    {
        if (Frames <= 0 || !shape.IsVisible)
        {
            _history.Clear();
            Unhook();
            _apply(shape);
            return;
        }
        if (_history.Count > 0 && _history[^1].Tick == _tick) _history[^1] = (_tick, shape);
        else _history.Add((_tick, shape));
        if (!_hooked)
        {
            _hooked = true;
            CompositionTarget.Rendering += OnRendering;
        }
    }

    private void OnRendering(object? sender, EventArgs e)
    {
        // Runs every frame while hooked: an exception here would come back on every frame (and
        // fill the log), so it is logged once and the pending outlines are dropped.
        try { RenderingCore(e); }
        catch (Exception ex)
        {
            _history.Clear();
            Unhook();
            Isola.Core.Log.Error("Vetro: errore applicando la forma", ex);
        }
    }

    private void RenderingCore(EventArgs e)
    {
        if (e is RenderingEventArgs re)
        {
            if (re.RenderingTime == _lastRender) return; // Rendering can fire twice per frame
            _lastRender = re.RenderingTime;
        }
        _tick++;
        double target = _tick - Frames;

        int a = -1;
        for (int i = 0; i < _history.Count; i++)
            if (_history[i].Tick <= target) a = i;
        if (a < 0) return; // nothing old enough yet

        if (a > 0) _history.RemoveRange(0, a); // keep the one at/below target
        var (ta, sa) = _history[0];
        if (_history.Count > 1)
        {
            var (tb, sb) = _history[1];
            double t = Math.Clamp((target - ta) / Math.Max(1, tb - ta), 0, 1);
            _apply(Lerp(sa, sb, t));
        }
        else
        {
            _apply(sa);
            _history.Clear();
            Unhook();
        }
    }

    private static IslandShapeInfo Lerp(in IslandShapeInfo a, in IslandShapeInfo b, double t)
    {
        static double L(double x, double y, double t) => x + (y - x) * t;
        static Rect R(Rect x, Rect y, double t) => new(L(x.X, y.X, t), L(x.Y, y.Y, t), Math.Max(0, L(x.Width, y.Width, t)), Math.Max(0, L(x.Height, y.Height, t)));
        if (a.DpiScale != b.DpiScale || !a.IsVisible) return b;
        return new IslandShapeInfo(R(a.Bounds, b.Bounds, t), R(a.BodyBounds, b.BodyBounds, t),
            L(a.BottomRadius, b.BottomRadius, t), L(a.TopCorner, b.TopCorner, t), b.IsVisible, b.DpiScale);
    }

    private void Unhook()
    {
        if (!_hooked) return;
        _hooked = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    public void Dispose()
    {
        _history.Clear();
        Unhook();
    }
}
