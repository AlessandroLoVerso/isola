using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Media;

namespace Isola.Modules.Games;

/// <summary>Builds the strip, the card and the settings page. All values come from bindings on
/// <see cref="PerfViewModel"/>, so the elements never need to be touched again.</summary>
internal static class PerfViews
{
    private static readonly BooleanToVisibilityConverter BoolToVis = new();

    // =====================================================================================
    // Strip (about 272 x 24)
    // =====================================================================================

    public static FrameworkElement BuildStrip(PerfViewModel vm)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(StripCell("CPU", nameof(PerfViewModel.Cpu), nameof(PerfViewModel.CpuFraction), nameof(PerfViewModel.ShowCpu), 31));
        row.Children.Add(StripCell("GPU", nameof(PerfViewModel.Gpu), nameof(PerfViewModel.GpuFraction), nameof(PerfViewModel.ShowGpu), 31));
        row.Children.Add(StripCell("RAM", nameof(PerfViewModel.Ram), nameof(PerfViewModel.RamFraction), nameof(PerfViewModel.ShowRam), 31));
        row.Children.Add(StripCell("↓", nameof(PerfViewModel.Down), nameof(PerfViewModel.DownFraction), nameof(PerfViewModel.ShowNet), 58));

        // Spacing only between visible cells.
        foreach (FrameworkElement c in row.Children) c.Margin = new Thickness(6, 0, 6, 0);

        return new Grid { DataContext = vm, Children = { row }, Background = Brushes.Transparent };
    }

    private static FrameworkElement StripCell(string label, string valuePath, string fractionPath, string showPath, double valueWidth)
    {
        var l = new TextBlock
        {
            Text = label,
            FontSize = 10,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 4, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        l.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");

        var v = Value(valuePath, 12, FontWeights.SemiBold);
        v.Width = valueWidth;
        v.VerticalAlignment = VerticalAlignment.Center;

        var line = new StackPanel { Orientation = Orientation.Horizontal, Children = { l, v } };

        var bar = new MiniBar { Height = 2, Margin = new Thickness(0, 1, 0, 0) };
        bar.SetBinding(MiniBar.ValueProperty, new Binding(fractionPath) { Mode = BindingMode.OneWay });
        bar.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(PerfViewModel.ShowBars)) { Converter = BoolToVis });

        var cell = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { line, bar } };
        cell.SetBinding(UIElement.VisibilityProperty, new Binding(showPath) { Converter = BoolToVis });
        return cell;
    }

    // =====================================================================================
    // Card (about 424 x 186)
    // =====================================================================================

    public static FrameworkElement BuildCard(PerfViewModel vm, List<Sparkline> sparklines)
    {
        var grid = new UniformGrid { Columns = 2, Margin = new Thickness(-4) };

        grid.Children.Add(Tile("Processore", nameof(PerfViewModel.Cpu), null,
            Environment.ProcessorCount + " thread", new Sparkline(vm.CpuHistory, 100), nameof(PerfViewModel.ShowCpu), sparklines));
        grid.Children.Add(Tile("Scheda video", nameof(PerfViewModel.Gpu), null,
            "Motore 3D", new Sparkline(vm.GpuHistory, 100), nameof(PerfViewModel.ShowGpu), sparklines));
        grid.Children.Add(Tile("Memoria", nameof(PerfViewModel.Ram), nameof(PerfViewModel.RamDetail),
            null, new Sparkline(vm.RamHistory, 100), nameof(PerfViewModel.ShowRam), sparklines));
        grid.Children.Add(NetTile(vm, sparklines));

        var empty = new TextBlock
        {
            Text = "Accendi almeno un valore nelle impostazioni.",
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        empty.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var anyBinding = new MultiBinding { Converter = new NoneVisibleConverter() };
        foreach (var p in new[] { nameof(PerfViewModel.ShowCpu), nameof(PerfViewModel.ShowGpu), nameof(PerfViewModel.ShowRam), nameof(PerfViewModel.ShowNet) })
            anyBinding.Bindings.Add(new Binding(p));
        empty.SetBinding(UIElement.VisibilityProperty, anyBinding);

        return new Grid { DataContext = vm, Children = { grid, empty }, Background = Brushes.Transparent };
    }

    private static Border Tile(string title, string valuePath, string? detailPath, string? detailText,
        Sparkline spark, string showPath, List<Sparkline> sparklines)
    {
        var header = Header(title, detailPath, detailText);
        var value = Value(valuePath, 26, FontWeights.SemiBold);
        value.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        return TileShell(header, value, spark, showPath, sparklines);
    }

    private static Border NetTile(PerfViewModel vm, List<Sparkline> sparklines)
    {
        var header = Header("Rete", null, null);

        // Upload goes in the header detail, with a dimmer second line in the chart.
        var up = Value(nameof(PerfViewModel.Up), 11, FontWeights.Normal);
        up.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var upArrow = new TextBlock { Text = "↑ ", FontSize = 11 };
        upArrow.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var upRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.8,
            Children = { upArrow, up },
        };
        Grid.SetColumn(upRow, 1);
        header.Children.Add(upRow);

        var down = Value(nameof(PerfViewModel.Down), 22, FontWeights.SemiBold);
        down.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        var arrow = new TextBlock { Text = "↓", FontSize = 18, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
        arrow.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var valueRow = new StackPanel { Orientation = Orientation.Horizontal, Children = { arrow, down } };

        return TileShell(header, valueRow, new Sparkline(vm.DownHistory, 0, vm.UpHistory), nameof(PerfViewModel.ShowNet), sparklines);
    }

    private static Grid Header(string title, string? detailPath, string? detailText)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var t = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        grid.Children.Add(t);

        if (detailPath != null || detailText != null)
        {
            var d = detailPath != null ? Value(detailPath, 11, FontWeights.Normal) : new TextBlock { Text = detailText, FontSize = 11 };
            d.HorizontalAlignment = HorizontalAlignment.Right;
            d.VerticalAlignment = VerticalAlignment.Center;
            d.TextTrimming = TextTrimming.CharacterEllipsis;
            d.Margin = new Thickness(8, 0, 0, 0);
            d.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
            d.Opacity = 0.8;
            Grid.SetColumn(d, 1);
            grid.Children.Add(d);
        }
        return grid;
    }

    private static Border TileShell(Grid header, FrameworkElement value, Sparkline spark, string showPath, List<Sparkline> sparklines)
    {
        value.VerticalAlignment = VerticalAlignment.Bottom;
        value.Margin = new Thickness(-1, 0, 0, -3);

        spark.Margin = new Thickness(14, 8, 0, 3);
        spark.VerticalAlignment = VerticalAlignment.Stretch;
        sparklines.Add(spark);

        var body = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 60 });
        body.Children.Add(value);
        Grid.SetColumn(spark, 1);
        body.Children.Add(spark);

        var stack = new Grid();
        stack.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        stack.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        stack.Children.Add(header);
        Grid.SetRow(body, 1);
        stack.Children.Add(body);

        var tile = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(13, 10, 13, 10),
            Margin = new Thickness(4),
            Child = stack,
        };
        tile.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Surface");
        tile.SetBinding(UIElement.VisibilityProperty, new Binding(showPath) { Converter = BoolToVis });
        return tile;
    }

    private static TextBlock Value(string path, double size, FontWeight weight)
    {
        var t = new TextBlock { FontSize = size, FontWeight = weight };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Foreground");
        Typography.SetNumeralAlignment(t, FontNumeralAlignment.Tabular);
        t.SetBinding(TextBlock.TextProperty, new Binding(path) { Mode = BindingMode.OneWay });
        return t;
    }

    private sealed class NoneVisibleConverter : IMultiValueConverter
    {
        public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
            => values.Any(v => v is true) ? Visibility.Collapsed : Visibility.Visible;

        public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture)
            => throw new NotSupportedException();
    }

    // =====================================================================================
    // Settings page
    // =====================================================================================

    public static FrameworkElement BuildSettings(GamesSettings s, Action<bool> changed)
    {
        var root = new StackPanel();

        var intro = new TextBlock
        {
            Text = "Sopra un gioco o un video a schermo intero l'isola diventa una striscia sottile con questi valori. " +
                   "Le letture avvengono solo mentre la striscia o la scheda sono visibili.",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, -6, 0, 16),
        };
        intro.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");
        root.Children.Add(intro);

        root.Children.Add(Section("Valori"));
        root.Children.Add(Card(
            Row("CPU", "Utilizzo del processore, come in Gestione attività.", Toggle(s.ShowCpu, v => { s.ShowCpu = v; changed(true); })),
            Row("GPU", "Utilizzo del motore 3D della scheda video più impegnata.", Toggle(s.ShowGpu, v => { s.ShowGpu = v; changed(true); })),
            Row("RAM", "Memoria in uso.", Toggle(s.ShowRam, v => { s.ShowRam = v; changed(true); })),
            Row("Rete", "Velocità di download (e upload nella scheda).", Toggle(s.ShowNet, v => { s.ShowNet = v; changed(true); }))));

        root.Children.Add(Section("Aspetto"));
        root.Children.Add(Card(
            Row("Mostra barre", "Barre sottili sotto i numeri nella striscia.", Toggle(s.ShowBars, v => { s.ShowBars = v; changed(false); })),
            Row("Frequenza", "Quante letture al secondo. Più alta è più reattiva, ma usa un po' più di CPU.",
                Segmented(new[] { (2, "2 Hz"), (5, "5 Hz"), (10, "10 Hz") }, s.RateHz, v => { s.RateHz = v; changed(true); }))));
        return root;
    }

    private static TextBlock Section(string text) => new()
    {
        Text = text,
        FontSize = 13,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(2, 6, 0, 8),
    };

    private static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0)
            {
                var sep = new Border { Height = 1 };
                sep.SetResourceReference(Border.BackgroundProperty, "Settings.Brush.CardBorder");
                stack.Children.Add(sep);
            }
            stack.Children.Add(rows[i]);
        }
        var card = new Border { Child = stack };
        card.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SettingCard");
        return card;
    }

    private static FrameworkElement Row(string title, string description, FrameworkElement control)
    {
        var grid = new Grid { Margin = new Thickness(0, 13, 0, 13) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var d = new TextBlock { Text = description, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) };
        d.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");
        var text = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 24, 0),
            Children = { new TextBlock { Text = title, FontSize = 13.5, TextWrapping = TextWrapping.Wrap }, d },
        };
        grid.Children.Add(text);

        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    private static CheckBox Toggle(bool isChecked, Action<bool> onChange)
    {
        var t = new CheckBox { IsChecked = isChecked };
        t.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.ToggleSwitch");
        t.Checked += (_, _) => onChange(true);
        t.Unchecked += (_, _) => onChange(false);
        return t;
    }

    private static Border Segmented<T>(IEnumerable<(T Value, string Label)> options, T current, Action<T> onChange)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        string group = "games-" + Guid.NewGuid().ToString("N");
        foreach (var (value, label) in options)
        {
            var v = value;
            var rb = new RadioButton { Content = label, GroupName = group, IsChecked = EqualityComparer<T>.Default.Equals(v, current) };
            rb.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.Segmented");
            rb.Checked += (_, _) => onChange(v);
            panel.Children.Add(rb);
        }
        var host = new Border { Child = panel };
        host.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SegmentedHost");
        return host;
    }
}
