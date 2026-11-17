using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using Isola.Core;

namespace Isola.Modules.Clock;

/// <summary>Sample module: tab "Ora" with a big clock and the date; resting face priority 1.
/// Shows the whole contract: Start/Stop, card, resting face, settings page, settings JSON.</summary>
public sealed class ClockModule : IIslandModule, IRestingFaceProvider
{
    private static readonly CultureInfo Italian = CultureInfo.GetCultureInfo("it-IT");

    private readonly ClockViewModel _vm = new();
    private IIslandHost? _host;
    private DispatcherTimer? _timer;
    private ClockSettings _settings = new();
    private FrameworkElement? _card;
    private TextBlock? _secondsText;

    public string Id => "clock";
    public string Title => "Ora";
    public string Glyph => "";
    public int Order => 100;
    public bool EnabledByDefault => true;

    public int RestingPriority => 1;

    public void Start(IIslandHost host)
    {
        _host = host;
        _settings = host.LoadSettings<ClockSettings>(Id);
        _timer = new DispatcherTimer(DispatcherPriority.Background, host.Dispatcher);
        _timer.Tick += (_, _) => Tick();
        Tick();
    }

    public void Stop()
    {
        _timer?.Stop();
        _timer = null;
        _card = null;
        _secondsText = null;
        _host = null;
    }

    /// <summary>Updates the texts and schedules the next tick: every second while the card is on
    /// screen and seconds are shown, otherwise once a minute. Nothing runs in between.</summary>
    private void Tick()
    {
        if (_timer == null) return;
        var now = DateTime.Now;
        _vm.Update(now, Italian);

        bool fast = _settings.ShowSeconds && _card is { IsVisible: true };
        var next = fast
            ? TimeSpan.FromMilliseconds(1000 - now.Millisecond + 15)
            : TimeSpan.FromSeconds(60 - now.Second) - TimeSpan.FromMilliseconds(now.Millisecond) + TimeSpan.FromMilliseconds(30);
        _timer.Stop();
        _timer.Interval = next;
        _timer.Start();
    }

    public FrameworkElement? CreateCard()
    {
        var time = Text(nameof(ClockViewModel.Time), 64, FontWeights.Light);
        time.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        time.Margin = new Thickness(-3, -10, 0, 0);

        var seconds = Text(nameof(ClockViewModel.Seconds), 22, FontWeights.Normal);
        seconds.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        seconds.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        seconds.VerticalAlignment = VerticalAlignment.Bottom;
        seconds.Margin = new Thickness(8, 0, 0, 12);
        seconds.Visibility = _settings.ShowSeconds ? Visibility.Visible : Visibility.Collapsed;
        _secondsText = seconds;

        var timeRow = new StackPanel { Orientation = Orientation.Horizontal };
        timeRow.Children.Add(time);
        timeRow.Children.Add(seconds);

        var date = Text(nameof(ClockViewModel.Date), 16, FontWeights.Normal);
        date.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        date.Margin = new Thickness(0, 2, 0, 0);

        var week = Text(nameof(ClockViewModel.Week), 12, FontWeights.Normal);
        week.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        week.Opacity = 0.75;
        week.Margin = new Thickness(0, 6, 0, 0);

        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 4) };
        stack.Children.Add(timeRow);
        stack.Children.Add(date);
        stack.Children.Add(week);

        var root = new Grid { DataContext = _vm };
        root.Children.Add(stack);
        root.IsVisibleChanged += (_, _) => Tick(); // speed up / slow down the timer
        _card = root;
        return root;
    }

    public FrameworkElement CreateRestingFace()
    {
        var time = Text(nameof(ClockViewModel.Time), 13.5, FontWeights.SemiBold);
        time.HorizontalAlignment = HorizontalAlignment.Left;

        var date = Text(nameof(ClockViewModel.ShortDate), 12, FontWeights.Normal);
        date.HorizontalAlignment = HorizontalAlignment.Right;
        date.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");

        var grid = new Grid { DataContext = _vm };
        grid.Children.Add(time);
        grid.Children.Add(date);
        return grid;
    }

    public FrameworkElement? CreateSettingsPage()
    {
        var toggle = new CheckBox { IsChecked = _settings.ShowSeconds, Content = "Mostra i secondi nella scheda" };
        toggle.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.ToggleSwitch");
        void Changed(object s, RoutedEventArgs e)
        {
            _settings.ShowSeconds = toggle.IsChecked == true;
            _host?.SaveSettings(Id, _settings);
            if (_secondsText != null)
                _secondsText.Visibility = _settings.ShowSeconds ? Visibility.Visible : Visibility.Collapsed;
            Tick();
        }
        toggle.Checked += Changed;
        toggle.Unchecked += Changed;

        var card = new Border { Child = new StackPanel { Margin = new Thickness(0, 14, 0, 14), Children = { toggle } } };
        card.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SettingCard");
        return card;
    }

    private static TextBlock Text(string path, double size, FontWeight weight)
    {
        var t = new TextBlock { FontSize = size, FontWeight = weight, VerticalAlignment = VerticalAlignment.Center };
        t.SetBinding(TextBlock.TextProperty, new Binding(path) { Mode = BindingMode.OneWay });
        return t;
    }
}

public sealed class ClockSettings
{
    public bool ShowSeconds { get; set; } = true;
}

internal sealed class ClockViewModel : INotifyPropertyChanged
{
    public string Time { get; private set; } = "";
    public string Seconds { get; private set; } = "";
    public string Date { get; private set; } = "";
    public string ShortDate { get; private set; } = "";
    public string Week { get; private set; } = "";

    public event PropertyChangedEventHandler? PropertyChanged;

    public void Update(DateTime now, CultureInfo culture)
    {
        var changed = new List<string>();
        Time = Set(Time, now.ToString("HH:mm", culture), nameof(Time), changed);
        Seconds = Set(Seconds, now.ToString("ss", culture), nameof(Seconds), changed);
        Date = Set(Date, Capitalize(now.ToString("dddd d MMMM", culture), culture), nameof(Date), changed);
        ShortDate = Set(ShortDate, now.ToString("ddd d MMM", culture).Replace(".", ""), nameof(ShortDate), changed);
        Week = Set(Week, $"Settimana {ISOWeek.GetWeekOfYear(now)} · giorno {now.DayOfYear} dell'anno", nameof(Week), changed);
        // Raise after all values are stored, so bindings read the new ones.
        foreach (var name in changed) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private static string Set(string old, string value, string name, List<string> changed)
    {
        if (old != value) changed.Add(name);
        return value;
    }

    private static string Capitalize(string s, CultureInfo c) => s.Length == 0 ? s : char.ToUpper(s[0], c) + s[1..];
}
