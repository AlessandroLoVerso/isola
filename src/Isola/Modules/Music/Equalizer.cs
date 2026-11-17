using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Isola.Modules.Music;

/// <summary>Four little bars that bounce while <see cref="IsActive"/> is true AND the element is on
/// screen. Animations are removed otherwise, so a paused or hidden equalizer costs nothing.</summary>
internal sealed class Equalizer : StackPanel
{
    public static readonly DependencyProperty IsActiveProperty = DependencyProperty.Register(
        nameof(IsActive), typeof(bool), typeof(Equalizer), new PropertyMetadata(false, (d, _) => ((Equalizer)d).Update()));

    public bool IsActive { get => (bool)GetValue(IsActiveProperty); set => SetValue(IsActiveProperty, value); }

    // Key frames (fraction of full height) per bar; different lengths so the bars never sync up.
    private static readonly double[][] Patterns =
    {
        new[] { 0.35, 0.9, 0.5, 1.0, 0.4, 0.75, 0.35 },
        new[] { 0.8, 0.4, 1.0, 0.55, 0.85, 0.3, 0.8 },
        new[] { 0.5, 1.0, 0.35, 0.7, 0.95, 0.45, 0.5 },
        new[] { 0.7, 0.35, 0.65, 1.0, 0.5, 0.9, 0.7 },
    };
    private static readonly double[] Durations = { 1.15, 0.95, 1.3, 1.05 };

    private readonly ScaleTransform[] _scales = new ScaleTransform[4];
    private readonly AnimationTimeline[] _animations = new AnimationTimeline[4];
    private bool _running;

    public Equalizer(double barHeight = 14, double barWidth = 3, double gap = 2.5)
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        for (int i = 0; i < 4; i++)
        {
            var scale = new ScaleTransform(1, 0.35);
            var bar = new Rectangle
            {
                Width = barWidth, Height = barHeight, RadiusX = barWidth / 2, RadiusY = barWidth / 2,
                Margin = new Thickness(i == 0 ? 0 : gap, 0, 0, 0),
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = scale,
            };
            bar.SetBinding(Shape.FillProperty, new Binding(nameof(MusicViewModel.AccentBrush)));
            Children.Add(bar);
            _scales[i] = scale;
            _animations[i] = Build(Patterns[i], Durations[i]);
        }
        IsVisibleChanged += (_, _) => Update();
    }

    private static AnimationTimeline Build(double[] values, double seconds)
    {
        var anim = new DoubleAnimationUsingKeyFrames { RepeatBehavior = RepeatBehavior.Forever, Duration = TimeSpan.FromSeconds(seconds) };
        for (int k = 0; k < values.Length; k++)
        {
            anim.KeyFrames.Add(new EasingDoubleKeyFrame(values[k],
                KeyTime.FromTimeSpan(TimeSpan.FromSeconds(seconds * k / (values.Length - 1))),
                new SineEase { EasingMode = EasingMode.EaseInOut }));
        }
        Timeline.SetDesiredFrameRate(anim, 30);
        anim.Freeze();
        return anim;
    }

    private void Update()
    {
        bool run = IsActive && IsVisible;
        if (run == _running) return;
        _running = run;
        for (int i = 0; i < 4; i++)
        {
            _scales[i].BeginAnimation(ScaleTransform.ScaleYProperty, run ? _animations[i] : null);
            if (!run) _scales[i].ScaleY = 0.35;
        }
    }
}
