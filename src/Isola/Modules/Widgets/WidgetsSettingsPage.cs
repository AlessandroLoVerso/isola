using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace Isola.Modules.Widgets;

/// <summary>Settings → Widget: city, resting face, time zones, desktop widgets (Day clock).</summary>
internal sealed class WidgetsSettingsPage : StackPanel
{
    private static readonly Uri StylesUri = new("/Isola;component/Modules/Widgets/WidgetsStyles.xaml", UriKind.Relative);

    private static readonly (string Hex, string Name)[] Swatches =
    {
        ("#FFFFFF", "Bianco"), ("#F3E9D2", "Panna"), ("#FFC56B", "Ambra"), ("#FF7A6B", "Corallo"),
        ("#F5A3C7", "Rosa"), ("#C3A6FF", "Lilla"), ("#7FB8FF", "Cielo"), ("#7BE0B0", "Menta"), ("#111114", "Nero"),
    };

    private readonly WidgetsModule _module;
    private readonly WidgetsSettings _settings;
    private readonly TextBlock _cityStatus;
    private readonly WrapPanel _zones = new();
    private readonly TextBox _hex;
    private readonly List<RadioButton> _swatches = new();
    private bool _syncing;

    public WidgetsSettingsPage(WidgetsModule module, WidgetsSettings settings)
    {
        _module = module;
        _settings = settings;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = StylesUri });

        // ---- Weather -----------------------------------------------------------------------
        var city = new TextBox { Text = settings.City, Width = 190 };
        city.SetResourceReference(StyleProperty, "Isola.Style.TextBox");
        var search = new Button { Content = "Cerca", Margin = new Thickness(8, 0, 0, 0) };
        search.SetResourceReference(StyleProperty, "Isola.Style.Button");
        search.Click += (_, _) => _module.SetCity(city.Text);
        city.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; _module.SetCity(city.Text); } };
        var cityControl = new StackPanel { Orientation = Orientation.Horizontal };
        cityControl.Children.Add(city);
        cityControl.Children.Add(search);
        _cityStatus = Description("");
        UpdateCityStatus();
        System.ComponentModel.PropertyChangedEventManager.AddHandler(module.ViewModel, (_, _) => UpdateCityStatus(), "");

        var face = Segmented(new[] { (WidgetsFace.Clock, "Orologio"), (WidgetsFace.Weather, "Meteo") }, settings.RestingFace, module.SetRestingFace);

        Children.Add(Section("Meteo"));
        Children.Add(Card(
            Row("Città", _cityStatus, cityControl, ""),
            Row("Faccia a riposo", Description("Cosa mostra la pillola chiusa quando non succede niente: l'ora (modulo Ora) o il meteo."), face, "")));

        // ---- Time zones ---------------------------------------------------------------------
        BuildZones();
        var zonesBox = new StackPanel { Margin = new Thickness(0, 14, 0, 10) };
        var zonesTitle = new TextBlock { Text = "Fusi orari", FontSize = 13.5 };
        zonesBox.Children.Add(zonesTitle);
        zonesBox.Children.Add(Description("Fino a 4, nell'ordine in cui li scegli. Il formato 12 o 24 ore segue le impostazioni di Windows."));
        _zones.Margin = new Thickness(0, 12, 0, 0);
        zonesBox.Children.Add(_zones);
        Children.Add(Section("Fusi orari"));
        Children.Add(Card(zonesBox));

        // ---- Desktop --------------------------------------------------------------------------
        var dayToggle = Toggle(module.IsPinned(DesktopWidgetKind.Day));
        dayToggle.Checked += (_, _) => module.SetPinned(DesktopWidgetKind.Day, true);
        dayToggle.Unchecked += (_, _) => module.SetPinned(DesktopWidgetKind.Day, false);
        var clocksToggle = Toggle(module.IsPinned(DesktopWidgetKind.WorldClocks));
        clocksToggle.Checked += (_, _) => module.SetPinned(DesktopWidgetKind.WorldClocks, true);
        clocksToggle.Unchecked += (_, _) => module.SetPinned(DesktopWidgetKind.WorldClocks, false);

        var swatchPanel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var group = "swatch-" + Guid.NewGuid().ToString("N");
        foreach (var (hex, name) in Swatches)
        {
            var rb = new RadioButton { GroupName = group, Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)), ToolTip = name, Tag = hex };
            rb.SetResourceReference(StyleProperty, "Wid.Swatch");
            rb.Checked += (_, _) => { if (!_syncing) SetColor(hex); };
            _swatches.Add(rb);
            swatchPanel.Children.Add(rb);
        }
        _hex = new TextBox { Width = 92, Margin = new Thickness(8, 0, 0, 0), Text = settings.Day.Color };
        _hex.SetResourceReference(StyleProperty, "Isola.Style.TextBox");
        _hex.ToolTip = "Colore esadecimale, es. #FFC56B";
        _hex.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; ApplyHex(); } };
        _hex.LostKeyboardFocus += (_, _) => ApplyHex();
        swatchPanel.Children.Add(_hex);
        SyncSwatches(settings.Day.Color);

        var size = new Slider { Minimum = 60, Maximum = 240, Value = settings.Day.Size, Width = 220, SmallChange = 5, LargeChange = 20 };
        size.SetResourceReference(StyleProperty, "Isola.Style.Slider");
        var sizeText = new TextBlock { Width = 44, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Text = $"{settings.Day.Size:0}" };
        size.ValueChanged += (_, e) =>
        {
            sizeText.Text = $"{e.NewValue:0}";
            module.SetDesktopLook(null, Math.Round(e.NewValue));
        };
        var sizeRow = new StackPanel { Orientation = Orientation.Horizontal };
        sizeRow.Children.Add(size);
        sizeRow.Children.Add(sizeText);

        var edit = Toggle(module.Editing);
        edit.Checked += (_, _) => module.Editing = true;
        edit.Unchecked += (_, _) => module.Editing = false;
        // Leaving the page locks the widgets again (clicks pass through).
        Unloaded += (_, _) => { module.Editing = false; };

        Children.Add(Section("Sul desktop"));
        Children.Add(Card(
            Row("Orologio Day", Description("Il giorno della settimana in grande, a lettere spaziate, sopra lo sfondo del desktop."), dayToggle, ""),
            Row("Fusi orari", Description("Gli orologi dei fusi scelti sopra, sul desktop."), clocksToggle, ""),
            Row("Colore", null, swatchPanel, ""),
            Row("Dimensione", null, sizeRow, ""),
            Row("Modifica posizione", Description("Accendi e trascina i widget dove vuoi. Spento, i clic passano attraverso."), edit, "")));
    }

    // ---- City -------------------------------------------------------------------------------

    private void UpdateCityStatus()
    {
        var vm = _module.ViewModel;
        if (_module.CityLabel is { Length: > 0 } label)
            _cityStatus.Text = vm.HasWeather ? $"{label} · {vm.Temperature}, {vm.WeatherLabel.ToLower(CultureInfo.GetCultureInfo("it-IT"))}" : label;
        else
            _cityStatus.Text = vm.HasWeather ? "" : vm.WeatherStatus;
    }

    // ---- Time zones ---------------------------------------------------------------------------

    private void BuildZones()
    {
        _zones.Children.Clear();
        var chosen = _settings.TimeZones;
        foreach (var (id, name) in Zones.Known)
        {
            if (Zones.Find(id) == null) continue;
            int index = chosen.IndexOf(id);
            var tb = new ToggleButton { Content = name, IsChecked = index >= 0, Tag = id };
            if (Zones.Find(id) is { } tz)
            {
                var off = tz.GetUtcOffset(DateTime.UtcNow);
                tb.ToolTip = $"UTC{(off < TimeSpan.Zero ? "−" : "+")}{off.Duration():hh\\:mm}";
            }
            tb.SetResourceReference(StyleProperty, "Wid.SettingsChip");
            tb.IsEnabled = index >= 0 || chosen.Count < 4;
            tb.Click += (_, _) =>
            {
                var list = _settings.TimeZones.ToList();
                if (tb.IsChecked == true) { if (!list.Contains(id) && list.Count < 4) list.Add(id); }
                else list.Remove(id);
                _module.SetTimeZones(list);
                BuildZones();
            };
            _zones.Children.Add(tb);
        }
    }

    // ---- Colour -------------------------------------------------------------------------------

    private void SetColor(string hex)
    {
        _hex.Text = hex;
        _hex.ClearValue(Control.ForegroundProperty);
        _module.SetDesktopLook(hex, null);
    }

    private void ApplyHex()
    {
        var text = _hex.Text.Trim();
        if (!text.StartsWith('#')) text = "#" + text;
        if (DesktopView.ParseColor(text) == null || text.Length is not (7 or 9))
        {
            _hex.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x6B));
            return;
        }
        text = text.ToUpperInvariant();
        _hex.ClearValue(Control.ForegroundProperty);
        _hex.Text = text;
        SyncSwatches(text);
        _module.SetDesktopLook(text, null);
    }

    private void SyncSwatches(string hex)
    {
        _syncing = true;
        foreach (var s in _swatches) s.IsChecked = string.Equals((string)s.Tag, hex, StringComparison.OrdinalIgnoreCase);
        _syncing = false;
    }

    // ---- Building blocks (same look as the built-in pages) --------------------------------------

    private static Brush Muted => (Brush)Application.Current.FindResource("Settings.Brush.Muted");

    private static TextBlock Section(string text) => new()
    {
        Text = text,
        FontSize = 13,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(2, 6, 0, 8),
    };

    private static TextBlock Description(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Foreground = Muted,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 2, 0, 0),
    };

    private static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(new Border { Height = 1, Background = new SolidColorBrush(Color.FromRgb(0x2A, 0x2A, 0x30)) });
            stack.Children.Add(rows[i]);
        }
        var card = new Border { Child = stack };
        card.SetResourceReference(StyleProperty, "Isola.Style.SettingCard");
        return card;
    }

    private static FrameworkElement Row(string title, TextBlock? description, UIElement control, string? glyph = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 13, 0, 13) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (glyph != null)
        {
            var icon = new Border
            {
                Width = 34,
                Height = 34,
                CornerRadius = new CornerRadius(9),
                Background = new SolidColorBrush(Color.FromRgb(0x2A, 0x2A, 0x30)),
                Margin = new Thickness(0, 0, 14, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            var gt = new TextBlock { Text = glyph, FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            gt.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
            icon.Child = gt;
            grid.Children.Add(icon);
        }
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 24, 0) };
        text.Children.Add(new TextBlock { Text = title, FontSize = 13.5, TextWrapping = TextWrapping.Wrap });
        if (description != null) text.Children.Add(description);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 2);
        grid.Children.Add(control);
        return grid;
    }

    private static CheckBox Toggle(bool isChecked)
    {
        var t = new CheckBox { IsChecked = isChecked };
        t.SetResourceReference(StyleProperty, "Isola.Style.ToggleSwitch");
        return t;
    }

    private static Border Segmented<T>(IEnumerable<(T Value, string Label)> options, T current, Action<T> onChange)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        var group = "seg-" + Guid.NewGuid().ToString("N");
        foreach (var (value, label) in options)
        {
            var rb = new RadioButton { Content = label, GroupName = group, IsChecked = EqualityComparer<T>.Default.Equals(value, current) };
            rb.SetResourceReference(StyleProperty, "Isola.Style.Segmented");
            var v = value;
            rb.Checked += (_, _) => onChange(v);
            panel.Children.Add(rb);
        }
        var host = new Border { Child = panel };
        host.SetResourceReference(StyleProperty, "Isola.Style.SegmentedHost");
        return host;
    }
}
