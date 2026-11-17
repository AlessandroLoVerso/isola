using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using Isola.Core;
using Microsoft.Win32;

namespace Isola.Modules.Widgets;

public enum DesktopWidgetKind { Day, WorldClocks }

/// <summary>"Widget": world clocks, weather (Open-Meteo), battery, focus timer, to-do; the Day clock
/// and the world clocks can be pinned on the desktop.
/// Timers: clocks tick once a minute only while something shows them (card open or a desktop
/// widget pinned); weather every 30 minutes; the focus timer ticks every second only while the card
/// is open, otherwise it sleeps until the phase ends.</summary>
public sealed class WidgetsModule : IIslandModule, IRestingFaceProvider
{
    private static readonly TimeSpan FocusLength = TimeSpan.FromMinutes(25);
    private static readonly TimeSpan BreakLength = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan WeatherEvery = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan AlertLength = TimeSpan.FromSeconds(8);

    private readonly WidgetsViewModel _vm = new();
    private IIslandHost? _host;
    private WidgetsSettings _settings = new();
    private TodoStore? _todo;
    private WidgetsCard? _card;
    private bool _cardVisible;
    private DispatcherTimer? _minuteTimer, _weatherTimer, _focusTimer, _alertTimer, _restoreTimer;
    private int _restoreTries;
    private CancellationTokenSource? _weatherCts;
    private bool _weatherBusy;
    private DateTime _weatherFetched;
    private DesktopWidgetWindow? _dayWindow, _clocksWindow;
    private DayClockView? _dayView;
    private WorldClocksView? _clocksView;
    private bool _editing;

    // Focus timer state
    private bool _focusOnBreak, _focusRunning;
    private DateTime _focusEndsAt;
    private TimeSpan _focusRemaining = FocusLength;

    public string Id => "widgets";
    public string Title => "Widget";
    public string Glyph => "";
    public int Order => 60;
    public bool EnabledByDefault => true;

    public int RestingPriority => _settings.RestingFace == WidgetsFace.Weather && _vm.HasWeather ? 2 : 0;

    // =====================================================================================
    // Lifecycle
    // =====================================================================================

    public void Start(IIslandHost host)
    {
        _host = host;
        _settings = host.LoadSettings<WidgetsSettings>(Id);
        _settings.TimeZones = _settings.TimeZones.Where(z => Zones.Find(z) != null).Distinct().Take(4).ToList();
        _todo = new TodoStore(host.DataDirectory(Id));
        _vm.DayPinned = _settings.Day.Pinned;
        _vm.ClocksPinned = _settings.WorldClocks.Pinned;
        if (!string.IsNullOrEmpty(_settings.CityLabel)) _vm.WeatherCity = ShortCity(_settings.CityLabel);

        var d = host.Dispatcher;
        _minuteTimer = new DispatcherTimer(DispatcherPriority.Background, d);
        _minuteTimer.Tick += (_, _) => MinuteTick();
        _weatherTimer = new DispatcherTimer(DispatcherPriority.Background, d);
        _weatherTimer.Tick += (_, _) => RefreshWeather(force: true);
        _focusTimer = new DispatcherTimer(DispatcherPriority.Normal, d);
        _focusTimer.Tick += (_, _) => FocusTick();
        _alertTimer = new DispatcherTimer(DispatcherPriority.Background, d) { Interval = AlertLength };
        _alertTimer.Tick += (_, _) => { _alertTimer!.Stop(); _vm.AlertActive = false; };
        _restoreTimer = new DispatcherTimer(DispatcherPriority.Background, d) { Interval = TimeSpan.FromSeconds(2) };
        _restoreTimer.Tick += (_, _) => RestoreTick();

        SystemEvents.TimeChanged += OnTimeChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        UpdateClocks();
        UpdateBattery();
        UpdateFocusView();
        ScheduleMinute();
        RefreshWeather(force: true);
        if (_settings.Day.Pinned) ShowDesktop(DesktopWidgetKind.Day, true);
        if (_settings.WorldClocks.Pinned) ShowDesktop(DesktopWidgetKind.WorldClocks, true);
    }

    public void Stop()
    {
        SystemEvents.TimeChanged -= OnTimeChanged;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        foreach (var t in new[] { _minuteTimer, _weatherTimer, _focusTimer, _alertTimer, _restoreTimer }) t?.Stop();
        _minuteTimer = _weatherTimer = _focusTimer = _alertTimer = _restoreTimer = null;
        _weatherCts?.Cancel();
        _weatherCts = null;
        _weatherBusy = false;
        ShowDesktop(DesktopWidgetKind.Day, false);
        ShowDesktop(DesktopWidgetKind.WorldClocks, false);
        _editing = false;
        _focusRunning = false;
        _vm.AlertActive = false;
        _card = null;
        _cardVisible = false;
        _host = null;
    }

    public FrameworkElement? CreateCard()
    {
        _card = new WidgetsCard(this, _vm);
        _card.RefreshTodo(_todo?.Items ?? new List<TodoItem>());
        return _card;
    }

    public FrameworkElement? CreateSettingsPage() => new WidgetsSettingsPage(this, _settings);

    internal void CardVisibilityChanged(bool visible)
    {
        _cardVisible = visible;
        if (visible)
        {
            UpdateClocks();
            UpdateBattery();
            RefreshWeather(force: false);
        }
        ScheduleMinute();
        ScheduleFocus();
    }

    internal void RequestKeyboardFocus() => _host?.RequestKeyboardFocus();

    // =====================================================================================
    // System events
    // =====================================================================================

    private void OnTimeChanged(object? sender, EventArgs e) => _host?.Dispatcher.BeginInvoke(() =>
    {
        TimeZoneInfo.ClearCachedData();
        UpdateClocks();
        ScheduleMinute();
        ScheduleFocus();
    });

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e) => _host?.Dispatcher.BeginInvoke(() =>
    {
        if (_host == null) return;
        UpdateBattery();
        if (e.Mode != PowerModes.Resume) return;
        UpdateClocks();
        ScheduleMinute();
        ScheduleFocus();
        // The network needs a moment after resume.
        _weatherTimer?.Stop();
        if (_weatherTimer != null) { _weatherTimer.Interval = TimeSpan.FromSeconds(15); _weatherTimer.Start(); }
        _dayWindow?.SendToBottom();
        _clocksWindow?.SendToBottom();
    });

    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category != UserPreferenceCategory.Locale) return;
        _host?.Dispatcher.BeginInvoke(() =>
        {
            CultureInfo.CurrentCulture.ClearCachedData(); // 12/24 h follows Windows
            UpdateClocks();
        });
    }

    // =====================================================================================
    // Clocks
    // =====================================================================================

    private bool ClocksShown => _cardVisible || _dayWindow != null || _clocksWindow != null;

    private void ScheduleMinute()
    {
        if (_minuteTimer == null) return;
        _minuteTimer.Stop();
        if (!ClocksShown) return;
        var now = DateTime.Now;
        _minuteTimer.Interval = TimeSpan.FromSeconds(60 - now.Second) - TimeSpan.FromMilliseconds(now.Millisecond) + TimeSpan.FromMilliseconds(40);
        _minuteTimer.Start();
    }

    private void MinuteTick()
    {
        UpdateClocks();
        if (_cardVisible) UpdateBattery();
        ScheduleMinute();
    }

    private void UpdateClocks()
    {
        var now = DateTime.Now;
        var utc = DateTime.UtcNow;
        var rows = new List<ClockRow>();
        foreach (var id in _settings.TimeZones)
        {
            var tz = Zones.Find(id);
            if (tz == null) continue;
            var t = TimeZoneInfo.ConvertTimeFromUtc(utc, tz);
            int dayDiff = (t.Date - now.Date).Days;
            string hint = dayDiff switch { > 0 => "+1g", < 0 => "−1g", _ => "" };
            rows.Add(new ClockRow(Zones.Name(id), TimeText.Time(t), hint));
        }
        _vm.Clocks = rows;
        _vm.Weekday = TimeText.WeekdayUpper(now);
        _vm.DateLine = TimeText.LongDate(now);
        _vm.LocalTime = TimeText.Time(now);
    }

    internal void SetTimeZones(List<string> zones)
    {
        _settings.TimeZones = zones;
        Save();
        UpdateClocks();
    }

    // =====================================================================================
    // Battery
    // =====================================================================================

    private void UpdateBattery()
    {
        var ps = System.Windows.Forms.SystemInformation.PowerStatus;
        bool has = (ps.BatteryChargeStatus & System.Windows.Forms.BatteryChargeStatus.NoSystemBattery) == 0
                   && ps.BatteryChargeStatus != System.Windows.Forms.BatteryChargeStatus.Unknown;
        _vm.HasBattery = has;
        if (!has) return;
        int pct = (int)Math.Round(Math.Clamp(ps.BatteryLifePercent, 0f, 1f) * 100);
        bool charging = ps.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online;
        int level = (int)Math.Round(pct / 10.0);
        _vm.BatteryText = $"{pct}%";
        _vm.BatteryGlyph = charging
            ? (level >= 10 ? "" : level == 9 ? "" : ((char)(0xE85A + level)).ToString())
            : (level >= 10 ? "" : ((char)(0xE850 + level)).ToString());
        if (charging) _vm.BatterySub = pct >= 100 ? "Carica completa" : "In carica";
        else if (ps.BatteryLifeRemaining > 0)
        {
            var left = TimeSpan.FromSeconds(ps.BatteryLifeRemaining);
            _vm.BatterySub = left.TotalHours >= 1 ? $"Ancora {(int)left.TotalHours} h {left.Minutes:00} min" : $"Ancora {left.Minutes} min";
        }
        else _vm.BatterySub = "A batteria";
    }

    // =====================================================================================
    // Weather
    // =====================================================================================

    internal async void RefreshWeather(bool force)
    {
        if (_host == null || _weatherBusy) return;
        if (!force && _vm.HasWeather && DateTime.Now - _weatherFetched < TimeSpan.FromMinutes(25)) return;
        _weatherTimer?.Stop();
        _weatherBusy = true;
        _weatherCts?.Cancel();
        var cts = _weatherCts = new CancellationTokenSource();
        var host = _host;
        bool ok = false;
        if (!_vm.HasWeather) _vm.WeatherStatus = "Caricamento del meteo…";
        try
        {
            if (_settings.Latitude == null || _settings.Longitude == null)
            {
                var city = string.IsNullOrWhiteSpace(_settings.City) ? "Roma" : _settings.City;
                var place = await WeatherClient.GeocodeAsync(city, cts.Token);
                if (cts.IsCancellationRequested || _host != host) return;
                if (place == null)
                {
                    _vm.HasWeather = false;
                    _vm.WeatherStatus = $"Città non trovata: {city}";
                    _settings.CityLabel = null;
                    Save();
                    host.RefreshRestingFace();
                    ok = true; // nothing to retry soon
                    return;
                }
                _settings.Latitude = place.Latitude;
                _settings.Longitude = place.Longitude;
                _settings.CityLabel = place.Label;
                Save();
            }
            var w = await WeatherClient.ForecastAsync(_settings.Latitude!.Value, _settings.Longitude!.Value, cts.Token);
            if (cts.IsCancellationRequested || _host != host) return;
            bool had = _vm.HasWeather;
            _vm.Temperature = w.TemperatureText;
            _vm.WeatherLabel = w.Label;
            _vm.WeatherKind = w.Kind;
            _vm.IsDay = w.IsDay;
            _vm.MaxMin = w.Max is { } mx && w.Min is { } mn ? $"{Math.Round(mx):0}° / {Math.Round(mn):0}°" : "";
            _vm.WeatherCity = ShortCity(_settings.CityLabel ?? _settings.City);
            _vm.HasWeather = true;
            _weatherFetched = DateTime.Now;
            ok = true;
            if (!had) host.RefreshRestingFace();
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested) { return; }
        catch (Exception ex)
        {
            host.Log(Id, $"meteo non disponibile: {ex.GetType().Name}: {ex.Message}");
            if (!_vm.HasWeather) _vm.WeatherStatus = "Meteo non disponibile. Tocca per riprovare.";
        }
        finally
        {
            if (_host == host && ReferenceEquals(_weatherCts, cts))
            {
                _weatherBusy = false;
                if (_weatherTimer != null)
                {
                    _weatherTimer.Interval = ok ? WeatherEvery : TimeSpan.FromMinutes(5);
                    _weatherTimer.Start();
                }
            }
        }
    }

    internal void SetCity(string city)
    {
        city = city.Trim();
        if (city.Length == 0) return;
        _settings.City = city;
        _settings.Latitude = _settings.Longitude = null;
        _settings.CityLabel = null;
        _vm.HasWeather = false;
        _vm.WeatherCity = city;
        Save();
        _weatherBusy = false; // a new city cancels the request in flight
        RefreshWeather(force: true);
        _host?.RefreshRestingFace();
    }

    internal string? CityLabel => _settings.CityLabel;
    internal WidgetsViewModel ViewModel => _vm;

    private static string ShortCity(string label) => label.Split(',')[0].Trim();

    internal void SetRestingFace(WidgetsFace face)
    {
        _settings.RestingFace = face;
        Save();
        _host?.RefreshRestingFace();
    }

    // =====================================================================================
    // Focus timer (25/5)
    // =====================================================================================

    internal void FocusToggle()
    {
        var now = DateTime.Now;
        if (_focusRunning)
        {
            _focusRemaining = _focusEndsAt - now;
            if (_focusRemaining < TimeSpan.Zero) _focusRemaining = TimeSpan.Zero;
            _focusRunning = false;
        }
        else
        {
            if (_focusRemaining <= TimeSpan.Zero) _focusRemaining = _focusOnBreak ? BreakLength : FocusLength;
            _focusEndsAt = now + _focusRemaining;
            _focusRunning = true;
        }
        UpdateFocusView();
        ScheduleFocus();
    }

    internal void FocusReset()
    {
        _focusRunning = false;
        _focusOnBreak = false;
        _focusRemaining = FocusLength;
        UpdateFocusView();
        ScheduleFocus();
    }

    private void FocusTick()
    {
        if (_focusRunning && DateTime.Now >= _focusEndsAt.AddMilliseconds(-50)) FocusPhaseEnded();
        UpdateFocusView();
        ScheduleFocus();
    }

    private void FocusPhaseEnded()
    {
        if (!_focusOnBreak)
        {
            // Focus done: the break starts by itself.
            _focusOnBreak = true;
            _focusRemaining = BreakLength;
            _focusEndsAt = DateTime.Now + BreakLength;
            _focusRunning = true;
            Alert("Pausa", "25 minuti fatti · 5 di pausa");
        }
        else
        {
            _focusOnBreak = false;
            _focusRemaining = FocusLength;
            _focusRunning = false;
            Alert("Pausa finita", "Pronto per altri 25 minuti");
        }
    }

    private void ScheduleFocus()
    {
        if (_focusTimer == null) return;
        _focusTimer.Stop();
        if (!_focusRunning) return;
        var left = _focusEndsAt - DateTime.Now;
        if (left <= TimeSpan.Zero) { _focusTimer.Interval = TimeSpan.FromMilliseconds(10); _focusTimer.Start(); return; }
        // Card open: tick on each displayed second. Otherwise sleep until the phase ends.
        var wait = _cardVisible ? TimeSpan.FromMilliseconds(left.TotalMilliseconds % 1000 + 20) : left;
        _focusTimer.Interval = wait;
        _focusTimer.Start();
    }

    private void UpdateFocusView()
    {
        var left = _focusRunning ? _focusEndsAt - DateTime.Now : _focusRemaining;
        if (left < TimeSpan.Zero) left = TimeSpan.Zero;
        var total = _focusOnBreak ? BreakLength : FocusLength;
        int secs = (int)Math.Ceiling(left.TotalSeconds - 0.001);
        _vm.FocusTime = $"{secs / 60:00}:{secs % 60:00}";
        _vm.FocusPhase = _focusOnBreak ? "Pausa" : _focusRunning || left < total ? "Concentrazione" : "Timer 25 / 5";
        _vm.FocusRunning = _focusRunning;
        _vm.FocusBreak = _focusOnBreak;
        _vm.FocusProgress = Math.Clamp(1 - left.TotalSeconds / total.TotalSeconds, 0, 1);
    }

    private void Alert(string title, string text)
    {
        _vm.AlertTitle = title;
        _vm.AlertText = text;
        _vm.AlertActive = true;
        _alertTimer?.Stop();
        _alertTimer?.Start();
        _host?.Attention(Id, AlertLength);
    }

    // =====================================================================================
    // To-do
    // =====================================================================================

    internal bool TodoAdd(string text)
    {
        text = text.Trim();
        if (_todo == null || text.Length == 0) return false;
        _todo.Items.Add(new TodoItem { Text = text });
        _todo.Save();
        _card?.RefreshTodo(_todo.Items);
        return true;
    }

    internal void TodoToggle(Guid id)
    {
        var item = _todo?.Items.FirstOrDefault(i => i.Id == id);
        if (item == null) return;
        item.Done = !item.Done;
        _todo!.Save();
        _card?.RefreshTodo(_todo.Items);
    }

    internal void TodoDelete(Guid id)
    {
        if (_todo == null) return;
        _todo.Items.RemoveAll(i => i.Id == id);
        _todo.Save();
        _card?.RefreshTodo(_todo.Items);
    }

    // =====================================================================================
    // Desktop widgets
    // =====================================================================================

    internal bool IsPinned(DesktopWidgetKind kind) => kind == DesktopWidgetKind.Day ? _settings.Day.Pinned : _settings.WorldClocks.Pinned;

    internal void TogglePin(DesktopWidgetKind kind) => SetPinned(kind, !IsPinned(kind));

    internal void SetPinned(DesktopWidgetKind kind, bool pinned)
    {
        if (kind == DesktopWidgetKind.Day) { _settings.Day.Pinned = pinned; _vm.DayPinned = pinned; }
        else { _settings.WorldClocks.Pinned = pinned; _vm.ClocksPinned = pinned; }
        Save();
        ShowDesktop(kind, pinned);
    }

    internal DayClockSettings DayLook => _settings.Day;

    internal void SetDesktopLook(string? color, double? size)
    {
        if (color != null) _settings.Day.Color = color;
        if (size != null) _settings.Day.Size = size.Value;
        Save();
        _dayView?.Apply(_settings.Day.Color, _settings.Day.Size);
        _clocksView?.Apply(_settings.Day.Color, _settings.Day.Size);
    }

    internal bool Editing
    {
        get => _editing;
        set
        {
            _editing = value;
            if (_dayWindow != null) _dayWindow.Editing = value;
            if (_clocksWindow != null) _clocksWindow.Editing = value;
        }
    }

    private void ShowDesktop(DesktopWidgetKind kind, bool show)
    {
        bool day = kind == DesktopWidgetKind.Day;
        var existing = day ? _dayWindow : _clocksWindow;
        if (!show)
        {
            if (existing != null)
            {
                // Forget it first: Closed below then knows this close was ours.
                if (day) { _dayWindow = null; _dayView = null; }
                else { _clocksWindow = null; _clocksView = null; }
                existing.Close();
            }
            ScheduleMinute();
            return;
        }
        if (existing != null || _host == null) return;

        UpdateClocks();
        DesktopView view = day ? new DayClockView(_vm) : new WorldClocksView(_vm);
        view.Apply(_settings.Day.Color, _settings.Day.Size);
        var placement = day ? (DesktopWidgetPlacement)_settings.Day : _settings.WorldClocks;
        var win = new DesktopWidgetWindow(view, day ? "Isola · Day" : "Isola · Fusi orari");
        var (left, top) = InitialPosition(placement, day);
        if (day) win.CenterX = left; // the Day clock stores its centre
        win.Left = day ? left - 300 : left;
        win.Top = top;
        win.Moved += (l, t) =>
        {
            placement.Left = l;
            placement.Top = t;
            Save();
        };
        win.Closed += (_, _) =>
        {
            // Closed by someone else: the desktop window that owns it went away (explorer.exe
            // restarted, which destroys owned windows). Put it back once the new desktop exists.
            if (!ReferenceEquals(day ? _dayWindow : _clocksWindow, win)) return;
            if (day) { _dayWindow = null; _dayView = null; }
            else { _clocksWindow = null; _clocksView = null; }
            _host?.Log(Id, "widget sul desktop chiuso dal sistema (explorer riavviato?): lo rimetto");
            ScheduleMinute();
            _restoreTries = 0;
            _restoreTimer?.Stop();
            _restoreTimer?.Start();
        };
        win.Show();
        if (!day && placement.Left == null)
        {
            // Default place of the world clocks: top-right corner of the primary work area
            // (desktop icons usually fill the left side). Needs the measured width.
            var work = SystemParameters.WorkArea;
            win.UpdateLayout();
            win.Left = work.Right - win.ActualWidth - 24;
            win.Top = work.Top + 24;
        }
        win.Editing = _editing;
        if (day) { _dayWindow = win; _dayView = (DayClockView)view; }
        else { _clocksWindow = win; _clocksView = (WorldClocksView)view; }
        ScheduleMinute();
    }

    /// <summary>Every 2 s after a widget was lost, until the new desktop window (its owner) exists
    /// (at most ~1 min), then shows the pinned widgets again.</summary>
    private void RestoreTick()
    {
        if (_host == null) { _restoreTimer?.Stop(); return; }
        if (NativeDesktop.GetShellWindow() == IntPtr.Zero && ++_restoreTries < 30) return;
        _restoreTimer?.Stop();
        if (_settings.Day.Pinned) ShowDesktop(DesktopWidgetKind.Day, true);
        if (_settings.WorldClocks.Pinned) ShowDesktop(DesktopWidgetKind.WorldClocks, true);
    }

    private static (double Left, double Top) InitialPosition(DesktopWidgetPlacement p, bool day)
    {
        var work = SystemParameters.WorkArea;
        if (p.Left is { } l && p.Top is { } t &&
            l > SystemParameters.VirtualScreenLeft - 100 && l < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 40 &&
            t > SystemParameters.VirtualScreenTop - 40 && t < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 40)
            return (l, t);
        // Defaults: Day centred in the upper part of the primary screen, below the island; clocks
        // top-right (moved there once measured, see ShowDesktop). Desktop icons fill the left side.
        return day ? (work.Left + work.Width / 2, work.Top + work.Height * 0.14) : (work.Right - 620, work.Top + 24);
    }

    private void Save() => _host?.SaveSettings(Id, _settings);

    // =====================================================================================
    // Resting face: weather (temp + icon), or the focus-timer alert while it peeks.
    // =====================================================================================

    public FrameworkElement CreateRestingFace() => new WidgetsFaceView(_vm);
}

/// <summary>Pill content: weather on the left/right, replaced by the focus alert while active.</summary>
internal sealed class WidgetsFaceView : Grid
{
    private readonly WidgetsViewModel _vm;
    private readonly Border _icon = new() { Width = 17, Height = 17, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };

    public WidgetsFaceView(WidgetsViewModel vm)
    {
        _vm = vm;
        DataContext = vm;

        var temp = new TextBlock { FontSize = 13.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        temp.SetBinding(TextBlock.TextProperty, new Binding(nameof(WidgetsViewModel.Temperature)) { Mode = BindingMode.OneWay });
        var left = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left };
        left.Children.Add(_icon);
        left.Children.Add(temp);
        var label = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(64, 0, 0, 0) };
        label.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        label.SetBinding(TextBlock.TextProperty, new Binding(nameof(WidgetsViewModel.WeatherCity)) { Mode = BindingMode.OneWay });
        var weather = new Grid();
        weather.Children.Add(left);
        weather.Children.Add(label);
        weather.SetBinding(VisibilityProperty, new Binding(nameof(WidgetsViewModel.AlertActive)) { Converter = new BoolToVisibility(invert: true) });

        var glyph = new TextBlock { Text = "", FontSize = 14, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 8, 0) };
        glyph.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        glyph.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Accent");
        var title = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        title.SetBinding(TextBlock.TextProperty, new Binding(nameof(WidgetsViewModel.AlertTitle)) { Mode = BindingMode.OneWay });
        var text = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(10, 0, 0, 0) };
        text.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        text.SetBinding(TextBlock.TextProperty, new Binding(nameof(WidgetsViewModel.AlertText)) { Mode = BindingMode.OneWay });
        var alert = new DockPanel();
        DockPanel.SetDock(glyph, Dock.Left);
        DockPanel.SetDock(title, Dock.Left);
        alert.Children.Add(glyph);
        alert.Children.Add(title);
        alert.Children.Add(text);
        alert.SetBinding(VisibilityProperty, new Binding(nameof(WidgetsViewModel.AlertActive)) { Converter = new BoolToVisibility() });

        Children.Add(weather);
        Children.Add(alert);

        PropertyChangedEventManager.AddHandler(vm, (_, _) => UpdateIcon(), nameof(WidgetsViewModel.WeatherKind));
        PropertyChangedEventManager.AddHandler(vm, (_, _) => UpdateIcon(), nameof(WidgetsViewModel.IsDay));
        UpdateIcon();
    }

    private void UpdateIcon() => _icon.Child = WeatherIcon.Create(_vm.WeatherKind, _vm.IsDay, 17);
}
