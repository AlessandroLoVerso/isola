using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;

namespace Isola.Modules.Widgets;

/// <summary>The "Widget" tab: a grid of small tiles (world clocks, weather, focus timer, battery or
/// Day clock) and a to-do list on the right.</summary>
internal sealed class WidgetsCard : Grid
{
    private static readonly Uri StylesUri = new("/Isola;component/Modules/Widgets/WidgetsStyles.xaml", UriKind.Relative);

    private readonly WidgetsModule _owner;
    private readonly WidgetsViewModel _vm;
    private readonly StackPanel _clockRows = new();
    private readonly Border _weatherIconHost = new() { Width = 28, Height = 28, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _todoList = new();
    private readonly TextBlock _todoCount;
    private readonly TextBox _todoBox;
    private readonly TextBlock _todoPlaceholder;
    private readonly Button _clocksPin;
    private readonly Button _dayPin;
    private readonly Button _focusPlay;
    private readonly StackPanel _dayLetters = new() { Orientation = Orientation.Horizontal };
    private readonly Border _batteryTile;
    private readonly Border _dayTile;
    private readonly Border _progress;
    private readonly Grid _progressTrack;

    public WidgetsCard(WidgetsModule owner, WidgetsViewModel vm)
    {
        _owner = owner;
        _vm = vm;
        DataContext = vm;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = StylesUri });

        for (int i = 0; i < 3; i++) ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Insert(1, new ColumnDefinition { Width = new GridLength(8) });
        ColumnDefinitions.Insert(3, new ColumnDefinition { Width = new GridLength(8) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(8) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // ---- World clocks ------------------------------------------------------------------
        _clocksPin = IconButton("", () => _owner.TogglePin(DesktopWidgetKind.WorldClocks));
        var clocks = new DockPanel();
        clocks.Children.Add(Header("Fusi orari", _clocksPin));
        clocks.Children.Add(_clockRows);
        Place(Tile(clocks), 0, 0);

        // ---- Weather --------------------------------------------------------------------------
        var temp = Bound(nameof(WidgetsViewModel.Temperature), 24, FontWeights.Light);
        temp.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        temp.Margin = new Thickness(8, -3, 0, 0);
        var tempRow = new StackPanel { Orientation = Orientation.Horizontal };
        tempRow.Children.Add(_weatherIconHost);
        tempRow.Children.Add(temp);
        var label = Bound(nameof(WidgetsViewModel.WeatherLabel), 11.5, FontWeights.Normal);
        label.Margin = new Thickness(0, 3, 0, 0);
        var city = Bound(nameof(WidgetsViewModel.WeatherCity), 11, FontWeights.Normal, muted: true);
        var status = Bound(nameof(WidgetsViewModel.WeatherStatus), 11.5, FontWeights.Normal, muted: true);
        status.TextWrapping = TextWrapping.Wrap;
        status.TextTrimming = TextTrimming.None;
        var weatherOk = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        weatherOk.Children.Add(tempRow);
        weatherOk.Children.Add(label);
        weatherOk.Children.Add(city);
        weatherOk.SetBinding(VisibilityProperty, new Binding(nameof(WidgetsViewModel.HasWeather)) { Converter = new BoolToVisibility() });
        status.SetBinding(VisibilityProperty, new Binding(nameof(WidgetsViewModel.HasWeather)) { Converter = new BoolToVisibility(invert: true) });
        status.VerticalAlignment = VerticalAlignment.Center;
        var weather = new Grid();
        weather.Children.Add(weatherOk);
        weather.Children.Add(status);
        var weatherTile = Tile(weather);
        weatherTile.Cursor = Cursors.Hand;
        weatherTile.ToolTip = "Aggiorna il meteo";
        weatherTile.MouseLeftButtonUp += (_, _) => _owner.RefreshWeather(force: true);
        Place(weatherTile, 2, 0);

        // ---- Focus timer ----------------------------------------------------------------------
        var phase = Bound(nameof(WidgetsViewModel.FocusPhase), 11, FontWeights.Normal, muted: true);
        var focusTime = Bound(nameof(WidgetsViewModel.FocusTime), 24, FontWeights.Light);
        focusTime.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        focusTime.Margin = new Thickness(-1, -2, 0, 0);
        _focusPlay = new Button { Content = "", ToolTip = "Avvia" };
        _focusPlay.SetResourceReference(StyleProperty, "Wid.PlayButton");
        _focusPlay.Click += (_, _) => _owner.FocusToggle();
        var reset = IconButton("", () => _owner.FocusReset());
        reset.ToolTip = "Ricomincia";
        var focusButtons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        focusButtons.Children.Add(reset);
        focusButtons.Children.Add(_focusPlay);
        var progress = _progress = new Border { Height = 3, CornerRadius = new CornerRadius(1.5), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom };
        progress.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Accent");
        var progressTrack = _progressTrack = new Grid { Height = 3, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 4, 0, 0) };
        var trackBg = new Border { CornerRadius = new CornerRadius(1.5), Background = new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF)) };
        progressTrack.Children.Add(trackBg);
        progressTrack.Children.Add(progress);
        progressTrack.SizeChanged += (_, _) => UpdateProgress();
        var focus = new Grid();
        focus.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        focus.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        focus.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        focus.Children.Add(phase);
        var timeRow = new Grid { VerticalAlignment = VerticalAlignment.Center };
        timeRow.Children.Add(focusTime);
        timeRow.Children.Add(focusButtons);
        SetRow(timeRow, 1);
        focus.Children.Add(timeRow);
        SetRow(progressTrack, 2);
        focus.Children.Add(progressTrack);
        Place(Tile(focus), 0, 2);

        // ---- Battery ---------------------------------------------------------------------------
        var batGlyph = Bound(nameof(WidgetsViewModel.BatteryGlyph), 20, FontWeights.Normal);
        batGlyph.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        batGlyph.Margin = new Thickness(0, 2, 8, 0);
        var batText = Bound(nameof(WidgetsViewModel.BatteryText), 24, FontWeights.Light);
        batText.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        var batRow = new StackPanel { Orientation = Orientation.Horizontal };
        batRow.Children.Add(batGlyph);
        batRow.Children.Add(batText);
        var batSub = Bound(nameof(WidgetsViewModel.BatterySub), 11, FontWeights.Normal, muted: true);
        var battery = new DockPanel();
        battery.Children.Add(Header("Batteria", null));
        var batBody = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        batBody.Children.Add(batRow);
        batBody.Children.Add(batSub);
        battery.Children.Add(batBody);
        _batteryTile = Tile(battery);
        Place(_batteryTile, 2, 2);

        // ---- Day clock (in place of the battery on desktops) -----------------------------------
        _dayPin = IconButton("", () => _owner.TogglePin(DesktopWidgetKind.Day));
        var dayDate = Bound(nameof(WidgetsViewModel.DateLine), 11, FontWeights.Normal, muted: true);
        dayDate.HorizontalAlignment = HorizontalAlignment.Center;
        dayDate.Margin = new Thickness(0, 2, 0, 0);
        _dayLetters.HorizontalAlignment = HorizontalAlignment.Center;
        var dayBody = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 0, 4) };
        dayBody.Children.Add(_dayLetters);
        dayBody.Children.Add(dayDate);
        var day = new DockPanel();
        day.Children.Add(Header("Day", _dayPin));
        day.Children.Add(dayBody);
        _dayTile = Tile(day);
        Place(_dayTile, 2, 2);

        // ---- To-do ------------------------------------------------------------------------------
        _todoCount = new TextBlock { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
        _todoCount.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        _todoBox = new TextBox { MaxLength = 120, Height = 26, FontSize = 12, Padding = new Thickness(8, 0, 8, 0) };
        _todoBox.SetResourceReference(StyleProperty, "Wid.TextBox");
        _todoBox.PreviewMouseDown += (_, _) => _owner.RequestKeyboardFocus();
        _todoBox.GotKeyboardFocus += (_, _) => _owner.RequestKeyboardFocus();
        _todoBox.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            if (_owner.TodoAdd(_todoBox.Text)) _todoBox.Clear();
        };
        _todoPlaceholder = new TextBlock { Text = "Aggiungi…", FontSize = 12, Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        _todoPlaceholder.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        _todoBox.TextChanged += (_, _) => _todoPlaceholder.Visibility = _todoBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var boxHost = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        boxHost.Children.Add(_todoBox);
        boxHost.Children.Add(_todoPlaceholder);
        DockPanel.SetDock(boxHost, Dock.Top);
        var scroll = new ScrollViewer { Content = _todoList };
        scroll.SetResourceReference(StyleProperty, "Wid.Scroll");
        var todo = new DockPanel();
        todo.Children.Add(Header("Da fare", _todoCount));
        todo.Children.Add(boxHost);
        todo.Children.Add(scroll);
        var todoTile = Tile(todo);
        Place(todoTile, 4, 0);
        SetRowSpan(todoTile, 3);

        PropertyChangedEventManager.AddHandler(vm, OnVmChanged, "");
        IsVisibleChanged += (_, _) => _owner.CardVisibilityChanged(IsVisible);
        RebuildAll();
    }

    // =====================================================================================

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(WidgetsViewModel.Clocks): RebuildClocks(); break;
            case nameof(WidgetsViewModel.WeatherKind):
            case nameof(WidgetsViewModel.IsDay): RebuildWeatherIcon(); break;
            case nameof(WidgetsViewModel.FocusRunning): UpdateFocusButton(); break;
            case nameof(WidgetsViewModel.FocusProgress): UpdateProgress(); break;
            case nameof(WidgetsViewModel.Weekday): RebuildDayLetters(); break;
            case nameof(WidgetsViewModel.HasBattery): UpdateBatterySlot(); break;
            case nameof(WidgetsViewModel.DayPinned):
            case nameof(WidgetsViewModel.ClocksPinned): UpdatePins(); break;
        }
    }

    private void RebuildAll()
    {
        RebuildClocks();
        RebuildWeatherIcon();
        UpdateFocusButton();
        RebuildDayLetters();
        UpdateBatterySlot();
        UpdatePins();
    }

    private void RebuildClocks()
    {
        _clockRows.Children.Clear();
        var compact = _vm.Clocks.Count > 3;
        foreach (var c in _vm.Clocks)
        {
            var g = new Grid { Height = compact ? 13 : 17 };
            var name = new TextBlock { Text = c.City, FontSize = compact ? 10.5 : 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 44, 0) };
            var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            if (c.DayHint.Length > 0)
            {
                var hint = new TextBlock { Text = c.DayHint, FontSize = 10, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 5, 0) };
                hint.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
                right.Children.Add(hint);
            }
            right.Children.Add(new TextBlock { Text = c.Time, FontSize = compact ? 11.5 : 12.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            g.Children.Add(name);
            g.Children.Add(right);
            _clockRows.Children.Add(g);
        }
        if (_vm.Clocks.Count == 0)
        {
            var none = new TextBlock { Text = "Scegli i fusi nelle impostazioni.", FontSize = 11, TextWrapping = TextWrapping.Wrap };
            none.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
            _clockRows.Children.Add(none);
        }
    }

    private void RebuildWeatherIcon()
        => _weatherIconHost.Child = WeatherIcon.Create(_vm.WeatherKind, _vm.IsDay, 28);

    private void UpdateProgress() => _progress.Width = Math.Max(0, _progressTrack.ActualWidth * _vm.FocusProgress);

    private void UpdateFocusButton()
    {
        _focusPlay.Content = _vm.FocusRunning ? "" : "";
        _focusPlay.ToolTip = _vm.FocusRunning ? "Pausa" : "Avvia";
    }

    private void RebuildDayLetters()
    {
        _dayLetters.Children.Clear();
        var letters = _vm.Weekday;
        for (int i = 0; i < letters.Length; i++)
        {
            var t = new TextBlock { Text = letters[i].ToString(), FontSize = 17, FontWeight = FontWeights.Light, Margin = new Thickness(0, 0, i == letters.Length - 1 ? 0 : 4, 0) };
            t.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
            _dayLetters.Children.Add(t);
        }
    }

    private void UpdateBatterySlot()
    {
        _batteryTile.Visibility = _vm.HasBattery ? Visibility.Visible : Visibility.Collapsed;
        _dayTile.Visibility = _vm.HasBattery ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdatePins()
    {
        SetPin(_clocksPin, _vm.ClocksPinned);
        SetPin(_dayPin, _vm.DayPinned);
    }

    private static void SetPin(Button b, bool pinned)
    {
        b.Content = pinned ? "" : "";
        b.ToolTip = pinned ? "Togli dal desktop" : "Fissa sul desktop";
        if (pinned) b.SetResourceReference(Control.ForegroundProperty, "Isola.Brush.Accent");
        else b.ClearValue(Control.ForegroundProperty);
    }

    public void RefreshTodo(IReadOnlyList<TodoItem> items)
    {
        _todoList.Children.Clear();
        foreach (var item in items.OrderBy(i => i.Done).ThenBy(i => i.Done ? -i.Created.Ticks : i.Created.Ticks))
            _todoList.Children.Add(TodoRow(item));
        int open = items.Count(i => !i.Done);
        _todoCount.Text = open == 0 ? "" : open.ToString();
        if (items.Count == 0)
        {
            var none = new TextBlock { Text = "Niente da fare.", FontSize = 11.5, Margin = new Thickness(2, 6, 0, 0) };
            none.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
            _todoList.Children.Add(none);
        }
    }

    private FrameworkElement TodoRow(TodoItem item)
    {
        var check = new TextBlock { Text = item.Done ? "" : "", FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 7, 0) };
        check.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        check.SetResourceReference(TextBlock.ForegroundProperty, item.Done ? "Isola.Brush.Accent" : "Isola.Brush.Muted");
        var text = new TextBlock { Text = item.Text, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        if (item.Done)
        {
            text.TextDecorations = TextDecorations.Strikethrough;
            text.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        }
        var delete = new Button { Content = "", ToolTip = "Elimina", Visibility = Visibility.Hidden };
        delete.SetResourceReference(StyleProperty, "Wid.IconButton");
        var id = item.Id;
        delete.Click += (_, _) => _owner.TodoDelete(id);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(check);
        SetColumn(text, 1);
        grid.Children.Add(text);
        SetColumn(delete, 2);
        grid.Children.Add(delete);
        var row = new Border { Child = grid, Height = 24, Padding = new Thickness(4, 0, 0, 0), CornerRadius = new CornerRadius(7), Background = Brushes.Transparent, Cursor = Cursors.Hand };
        row.MouseEnter += (_, _) => { row.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.SurfaceHover"); delete.Visibility = Visibility.Visible; };
        row.MouseLeave += (_, _) => { row.Background = Brushes.Transparent; delete.Visibility = Visibility.Hidden; };
        row.MouseLeftButtonUp += (_, e) => { if (e.OriginalSource is not DependencyObject d || !IsInside(d, delete)) _owner.TodoToggle(id); };
        return row;
    }

    private static bool IsInside(DependencyObject d, DependencyObject container)
    {
        for (var cur = d; cur != null; cur = VisualTreeHelper.GetParent(cur))
            if (ReferenceEquals(cur, container)) return true;
        return false;
    }

    // ---- Building blocks ----------------------------------------------------------------

    private void Place(UIElement e, int col, int row)
    {
        SetColumn(e, col);
        SetRow(e, row);
        Children.Add(e);
    }

    private static Border Tile(UIElement child)
    {
        var b = new Border { Child = child, CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 6, 8, 7) };
        b.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Surface");
        return b;
    }

    private static FrameworkElement Header(string title, FrameworkElement? right)
    {
        var t = new TextBlock { Text = title, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var g = new Grid { Height = 18, Margin = new Thickness(0, 0, 0, 1) };
        g.Children.Add(t);
        if (right != null)
        {
            right.HorizontalAlignment = HorizontalAlignment.Right;
            g.Children.Add(right);
        }
        DockPanel.SetDock(g, Dock.Top);
        return g;
    }

    private Button IconButton(string glyph, Action click)
    {
        var b = new Button { Content = glyph };
        b.SetResourceReference(StyleProperty, "Wid.IconButton");
        b.Click += (_, _) => click();
        return b;
    }

    private static TextBlock Bound(string path, double size, FontWeight weight, bool muted = false)
    {
        var t = new TextBlock { FontSize = size, FontWeight = weight, TextTrimming = TextTrimming.CharacterEllipsis };
        t.SetBinding(TextBlock.TextProperty, new Binding(path) { Mode = BindingMode.OneWay });
        if (muted) t.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        return t;
    }
}

internal sealed class BoolToVisibility : IValueConverter
{
    private readonly bool _invert;
    public BoolToVisibility(bool invert = false) => _invert = invert;
    public object Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture)
        => (value is true) ^ _invert ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture)
        => throw new NotSupportedException();
}
