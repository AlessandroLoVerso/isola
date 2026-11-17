using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Isola.Modules.Widgets;

internal sealed record ClockRow(string City, string Time, string DayHint);

/// <summary>Everything the card, the pill and the desktop widgets show. Updated by the module on the
/// UI thread; views bind to it (or listen to PropertyChanged for the parts they rebuild).</summary>
internal sealed class WidgetsViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }

    // ---- Clocks -----------------------------------------------------------------------
    private IReadOnlyList<ClockRow> _clocks = Array.Empty<ClockRow>();
    public IReadOnlyList<ClockRow> Clocks { get => _clocks; set { if (!_clocks.SequenceEqual(value)) { _clocks = value; PropertyChanged?.Invoke(this, new(nameof(Clocks))); } } }

    private string _weekday = "", _dateLine = "", _localTime = "";
    public string Weekday { get => _weekday; set => Set(ref _weekday, value); }
    public string DateLine { get => _dateLine; set => Set(ref _dateLine, value); }
    public string LocalTime { get => _localTime; set => Set(ref _localTime, value); }

    // ---- Weather ----------------------------------------------------------------------
    private bool _hasWeather;
    private string _temperature = "--°", _weatherLabel = "", _weatherCity = "", _weatherStatus = "Caricamento…", _maxMin = "";
    private WeatherKind _weatherKind = WeatherKind.Cloudy;
    private bool _isDay = true;
    public bool HasWeather { get => _hasWeather; set => Set(ref _hasWeather, value); }
    public string Temperature { get => _temperature; set => Set(ref _temperature, value); }
    public string WeatherLabel { get => _weatherLabel; set => Set(ref _weatherLabel, value); }
    public string WeatherCity { get => _weatherCity; set => Set(ref _weatherCity, value); }
    public string WeatherStatus { get => _weatherStatus; set => Set(ref _weatherStatus, value); }
    public string MaxMin { get => _maxMin; set => Set(ref _maxMin, value); }
    public WeatherKind WeatherKind { get => _weatherKind; set => Set(ref _weatherKind, value); }
    public bool IsDay { get => _isDay; set => Set(ref _isDay, value); }

    // ---- Battery ----------------------------------------------------------------------
    private bool _hasBattery;
    private string _batteryText = "", _batteryGlyph = "", _batterySub = "";
    public bool HasBattery { get => _hasBattery; set => Set(ref _hasBattery, value); }
    public string BatteryText { get => _batteryText; set => Set(ref _batteryText, value); }
    public string BatteryGlyph { get => _batteryGlyph; set => Set(ref _batteryGlyph, value); }
    public string BatterySub { get => _batterySub; set => Set(ref _batterySub, value); }

    // ---- Focus timer ------------------------------------------------------------------
    private string _focusTime = "25:00", _focusPhase = "Concentrazione";
    private bool _focusRunning, _focusBreak;
    private double _focusProgress;
    public string FocusTime { get => _focusTime; set => Set(ref _focusTime, value); }
    public string FocusPhase { get => _focusPhase; set => Set(ref _focusPhase, value); }
    public bool FocusRunning { get => _focusRunning; set => Set(ref _focusRunning, value); }
    public bool FocusBreak { get => _focusBreak; set => Set(ref _focusBreak, value); }
    /// <summary>0..1 of the current phase elapsed.</summary>
    public double FocusProgress { get => _focusProgress; set => Set(ref _focusProgress, value); }

    // ---- Pill alert (focus timer finished) --------------------------------------------
    private bool _alertActive;
    private string _alertTitle = "", _alertText = "";
    public bool AlertActive { get => _alertActive; set => Set(ref _alertActive, value); }
    public string AlertTitle { get => _alertTitle; set => Set(ref _alertTitle, value); }
    public string AlertText { get => _alertText; set => Set(ref _alertText, value); }

    // ---- Settings mirrored for views --------------------------------------------------
    private bool _dayPinned, _clocksPinned;
    public bool DayPinned { get => _dayPinned; set => Set(ref _dayPinned, value); }
    public bool ClocksPinned { get => _clocksPinned; set => Set(ref _clocksPinned, value); }
}
