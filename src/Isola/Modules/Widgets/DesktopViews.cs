using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace Isola.Modules.Widgets;

/// <summary>Content of the desktop widgets. No background: only text in the chosen colour, with a
/// faint shadow so it stays readable on light wallpapers.</summary>
internal abstract class DesktopView : Grid
{
    protected readonly WidgetsViewModel Vm;
    protected Brush Fill = Brushes.White;
    protected double Size = 120;

    protected DesktopView(WidgetsViewModel vm)
    {
        Vm = vm;
        PropertyChangedEventManager.AddHandler(vm, (_, _) => Rebuild(), "");
    }

    public void Apply(string hexColor, double size)
    {
        Fill = ParseColor(hexColor) is { } c ? Frozen(new SolidColorBrush(c)) : Brushes.White;
        Size = Math.Clamp(size, 40, 320);
        Effect = new DropShadowEffect { BlurRadius = Math.Max(8, Size * 0.12), ShadowDepth = 0, Opacity = 0.35, Color = Colors.Black };
        Rebuild();
    }

    protected abstract void Rebuild();

    protected static FontFamily DisplayFont => new("Segoe UI Variable Display, Segoe UI");

    /// <summary>One TextBlock per letter: WPF has no letter spacing.</summary>
    protected StackPanel Spaced(string text, double fontSize, double spacing, FontWeight weight, double opacity = 1)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Opacity = opacity };
        var chars = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        var list = new List<string>();
        while (chars.MoveNext()) list.Add((string)chars.Current);
        for (int i = 0; i < list.Count; i++)
        {
            panel.Children.Add(new TextBlock
            {
                Text = list[i],
                FontFamily = DisplayFont,
                FontWeight = weight,
                FontSize = fontSize,
                Foreground = Fill,
                Margin = new Thickness(0, 0, i == list.Count - 1 ? 0 : spacing, 0),
            });
        }
        return panel;
    }

    public static Color? ParseColor(string? hex)
    {
        if (string.IsNullOrWhiteSpace(hex)) return null;
        hex = hex.Trim();
        if (!hex.StartsWith('#')) hex = "#" + hex;
        if (hex.Length is not (4 or 7 or 9)) return null;
        try { return (Color)ColorConverter.ConvertFromString(hex); }
        catch { return null; }
    }

    private static Brush Frozen(Brush b) { b.Freeze(); return b; }
}

/// <summary>"MARTEDÌ" in huge, widely spaced light capitals with the date underneath.</summary>
internal sealed class DayClockView : DesktopView
{
    private string _built = "";

    public DayClockView(WidgetsViewModel vm) : base(vm) { }

    protected override void Rebuild()
    {
        var key = $"{Vm.Weekday}|{Vm.DateLine}|{Size}|{Fill}";
        if (key == _built) return;
        _built = key;
        Children.Clear();
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(Spaced(Vm.Weekday, Size, Size * 0.32, FontWeights.Light));
        var date = Spaced(Vm.DateLine.ToUpperInvariant(), Math.Max(11, Size * 0.13), Math.Max(3, Size * 0.07), FontWeights.Normal, 0.85);
        date.Margin = new Thickness(0, Size * 0.02, 0, 0);
        stack.Children.Add(date);
        Children.Add(stack);
    }
}

/// <summary>World clocks side by side: city in small spaced capitals, time below.</summary>
internal sealed class WorldClocksView : DesktopView
{
    private string _built = "";

    public WorldClocksView(WidgetsViewModel vm) : base(vm) { }

    protected override void Rebuild()
    {
        var key = string.Join(";", Vm.Clocks) + $"|{Size}|{Fill}";
        if (key == _built) return;
        _built = key;
        Children.Clear();
        double timeSize = Size * 0.3;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        for (int i = 0; i < Vm.Clocks.Count; i++)
        {
            var c = Vm.Clocks[i];
            var col = new StackPanel { Margin = new Thickness(i == 0 ? 0 : timeSize * 0.9, 0, 0, 0) };
            var city = Spaced(c.City.ToUpperInvariant() + (c.DayHint.Length > 0 ? "  " + c.DayHint : ""), Math.Max(10, timeSize * 0.24), Math.Max(2, timeSize * 0.06), FontWeights.Normal, 0.8);
            city.HorizontalAlignment = HorizontalAlignment.Left;
            col.Children.Add(city);
            col.Children.Add(new TextBlock { Text = c.Time, FontFamily = DisplayFont, FontWeight = FontWeights.Light, FontSize = timeSize, Foreground = Fill, Margin = new Thickness(-timeSize * 0.04, -timeSize * 0.06, 0, 0) });
            row.Children.Add(col);
        }
        Children.Add(row);
    }
}
