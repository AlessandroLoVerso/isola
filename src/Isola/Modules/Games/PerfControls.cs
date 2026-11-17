using System.Windows;
using System.Windows.Media;

namespace Isola.Modules.Games;

/// <summary>A tiny horizontal usage bar (track + fill). Turns orange near the top.</summary>
internal sealed class MiniBar : FrameworkElement
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(MiniBar), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
        nameof(Fill), typeof(Brush), typeof(MiniBar), new FrameworkPropertyMetadata(Brushes.DodgerBlue, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty TrackProperty = DependencyProperty.Register(
        nameof(Track), typeof(Brush), typeof(MiniBar), new FrameworkPropertyMetadata(Brushes.Gray, FrameworkPropertyMetadataOptions.AffectsRender));

    private static readonly Brush Hot = Frozen(Color.FromRgb(0xFF, 0x9F, 0x0A));

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public Brush Fill { get => (Brush)GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public Brush Track { get => (Brush)GetValue(TrackProperty); set => SetValue(TrackProperty, value); }

    public MiniBar()
    {
        SetResourceReference(FillProperty, "Isola.Brush.Accent");
        SetResourceReference(TrackProperty, "Isola.Brush.Surface");
        SnapsToDevicePixels = true;
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        double r = h / 2;
        dc.DrawRoundedRectangle(Track, null, new Rect(0, 0, w, h), r, r);
        double v = Math.Clamp(Value, 0, 1);
        if (v <= 0) return;
        double fw = Math.Max(h, w * v);
        dc.DrawRoundedRectangle(v >= 0.9 ? Hot : Fill, null, new Rect(0, 0, fw, h), r, r);
    }

    internal static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}

/// <summary>Line + soft area of the last 60 s. Newest point on the right; fills in from the right
/// while the history is still short.</summary>
internal sealed class Sparkline : FrameworkElement
{
    public static readonly DependencyProperty StrokeProperty = DependencyProperty.Register(
        nameof(Stroke), typeof(Brush), typeof(Sparkline), new FrameworkPropertyMetadata(Brushes.DodgerBlue, FrameworkPropertyMetadataOptions.AffectsRender));

    public Brush Stroke { get => (Brush)GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }

    private readonly History _main;
    private readonly History? _second;
    private readonly double _fixedMax; // 0 = auto scale

    public Sparkline(History main, double fixedMax, History? second = null)
    {
        _main = main;
        _second = second;
        _fixedMax = fixedMax;
        SetResourceReference(StrokeProperty, "Isola.Brush.Accent");
        IsHitTestVisible = false;
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        double max = _fixedMax;
        if (max <= 0)
        {
            // Auto scale for network speeds, never below 64 KB/s so idle noise stays flat.
            max = Math.Max(64 * 1024, Math.Max(_main.Max(), _second?.Max() ?? 0)) * 1.1;
        }

        var color = Stroke is SolidColorBrush sb ? sb.Color : Colors.DodgerBlue;
        // Faint baseline so an empty chart still reads as a chart.
        var baseline = new Pen(MiniBar.Frozen(Color.FromArgb(0x30, 0x8E, 0x8E, 0x96)), 1);
        baseline.Freeze();
        dc.DrawLine(baseline, new Point(0, h - 0.5), new Point(w, h - 0.5));

        if (_second != null)
            Draw(dc, _second, w, h, max, Color.FromArgb(0x90, color.R, color.G, color.B), fill: false, thickness: 1);
        Draw(dc, _main, w, h, max, color, fill: true, thickness: 1.5);
    }

    private static void Draw(DrawingContext dc, History hist, double w, double h, double max, Color color, bool fill, double thickness)
    {
        int n = hist.Count, cap = hist.Capacity;
        if (n < 2) return;
        double step = w / (cap - 1);
        double x0 = w - (n - 1) * step;
        double top = thickness; // keep the stroke inside the box at 100%
        double Y(double v) => h - Math.Clamp(v / max, 0, 1) * (h - top) ;

        var line = new StreamGeometry();
        var area = new StreamGeometry();
        using (var lc = line.Open())
        using (var ac = area.Open())
        {
            bool open = false;
            double startX = 0, lastX = 0;
            for (int i = 0; i < n; i++)
            {
                double v = hist[i];
                double x = x0 + i * step;
                if (double.IsNaN(v))
                {
                    if (open) { ac.LineTo(new Point(lastX, h), false, false); open = false; }
                    continue;
                }
                var p = new Point(x, Y(v));
                if (!open)
                {
                    lc.BeginFigure(p, false, false);
                    ac.BeginFigure(new Point(x, h), true, true);
                    ac.LineTo(p, false, false);
                    startX = x;
                    open = true;
                }
                else
                {
                    lc.LineTo(p, true, true);
                    ac.LineTo(p, false, false);
                }
                lastX = x;
            }
            if (open) ac.LineTo(new Point(lastX, h), false, false);
            _ = startX;
        }
        line.Freeze();
        area.Freeze();

        if (fill)
        {
            var grad = new LinearGradientBrush(Color.FromArgb(0x55, color.R, color.G, color.B), Color.FromArgb(0x00, color.R, color.G, color.B), 90);
            grad.Freeze();
            dc.DrawGeometry(grad, null, area);
        }
        var pen = new Pen(new SolidColorBrush(color), thickness) { LineJoin = PenLineJoin.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        pen.Freeze();
        dc.DrawGeometry(null, pen, line);
    }
}
