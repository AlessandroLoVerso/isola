using System.Globalization;
using Isola.Core;

namespace Isola.Modules.Widgets;

public enum WidgetsFace { Clock, Weather }

/// <summary>Settings of the "Widget" module (settings\widgets.json).</summary>
public sealed class WidgetsSettings
{
    public string City { get; set; } = "Roma";
    /// <summary>Cached geocoding of <see cref="City"/>.</summary>
    public string? CityLabel { get; set; }
    public double? Latitude { get; set; }
    public double? Longitude { get; set; }

    public List<string> TimeZones { get; set; } = new() { "Europe/Rome", "America/New_York", "Asia/Tokyo" };

    /// <summary>"Clock" leaves the idle pill to the Ora module; "Weather" shows temperature + icon.</summary>
    public WidgetsFace RestingFace { get; set; } = WidgetsFace.Clock;

    public DayClockSettings Day { get; set; } = new();
    public DesktopWidgetPlacement WorldClocks { get; set; } = new();
}

public sealed class DayClockSettings : DesktopWidgetPlacement
{
    /// <summary>The Day clock is the signature look: on the desktop from the first run.</summary>
    public DayClockSettings() => Pinned = true;

    public string Color { get; set; } = "#FFFFFF";
    /// <summary>Font size of the weekday, DIP.</summary>
    public double Size { get; set; } = 120;
}

public class DesktopWidgetPlacement
{
    public bool Pinned { get; set; }
    /// <summary>Window position in DIP of the virtual screen; null = default place.</summary>
    public double? Left { get; set; }
    public double? Top { get; set; }
}

public sealed class TodoItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public bool Done { get; set; }
    public DateTime Created { get; set; } = DateTime.Now;
}

public sealed class TodoData
{
    public List<TodoItem> Items { get; set; } = new();
}

internal sealed class TodoStore
{
    private readonly string _path;
    public List<TodoItem> Items { get; }

    public TodoStore(string dataDirectory)
    {
        _path = Path.Combine(dataDirectory, "todo.json");
        Items = JsonStore.Load<TodoData>(_path).Items.Where(i => !string.IsNullOrWhiteSpace(i.Text)).ToList();
    }

    public void Save() => JsonStore.Save(_path, new TodoData { Items = Items });
}

/// <summary>Time zones offered in the settings, with Italian city names.</summary>
internal static class Zones
{
    public static readonly (string Id, string Name)[] Known =
    {
        ("Europe/Rome", "Roma"), ("Europe/London", "Londra"), ("Europe/Lisbon", "Lisbona"),
        ("Europe/Paris", "Parigi"), ("Europe/Berlin", "Berlino"), ("Europe/Madrid", "Madrid"),
        ("Europe/Athens", "Atene"), ("Europe/Istanbul", "Istanbul"), ("Europe/Moscow", "Mosca"),
        ("Atlantic/Reykjavik", "Reykjavík"), ("Africa/Cairo", "Il Cairo"), ("Africa/Johannesburg", "Johannesburg"),
        ("Asia/Dubai", "Dubai"), ("Asia/Kolkata", "Nuova Delhi"), ("Asia/Bangkok", "Bangkok"),
        ("Asia/Singapore", "Singapore"), ("Asia/Shanghai", "Pechino"), ("Asia/Hong_Kong", "Hong Kong"),
        ("Asia/Seoul", "Seul"), ("Asia/Tokyo", "Tokyo"), ("Australia/Sydney", "Sydney"),
        ("Pacific/Auckland", "Auckland"), ("Pacific/Honolulu", "Honolulu"), ("America/Los_Angeles", "Los Angeles"),
        ("America/Denver", "Denver"), ("America/Chicago", "Chicago"), ("America/Mexico_City", "Città del Messico"),
        ("America/New_York", "New York"), ("America/Toronto", "Toronto"), ("America/Sao_Paulo", "San Paolo"),
        ("America/Argentina/Buenos_Aires", "Buenos Aires"), ("Etc/UTC", "UTC"),
    };

    public static string Name(string id)
    {
        foreach (var (zid, name) in Known) if (zid == id) return name;
        var tail = id.Split('/').Last().Replace('_', ' ');
        return tail;
    }

    public static TimeZoneInfo? Find(string id)
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById(id); }
        catch { return null; }
    }
}

/// <summary>Italian date/time texts; 12/24 h follows the Windows setting.</summary>
internal static class TimeText
{
    public static readonly CultureInfo Italian = CultureInfo.GetCultureInfo("it-IT");

    public static bool Is24h
    {
        get
        {
            var p = CultureInfo.CurrentCulture.DateTimeFormat.ShortTimePattern;
            return !p.Contains('h') || p.Contains('H');
        }
    }

    public static string Time(DateTime t)
        => Is24h ? t.ToString("HH:mm", Italian) : t.ToString("h:mm tt", CultureInfo.CurrentCulture);

    /// <summary>"MARTEDÌ".</summary>
    public static string WeekdayUpper(DateTime t) => t.ToString("dddd", Italian).ToUpper(Italian);

    /// <summary>"18 novembre 2026".</summary>
    public static string LongDate(DateTime t) => t.ToString("d MMMM yyyy", Italian);

    public static string Capitalize(string s) => s.Length == 0 ? s : char.ToUpper(s[0], Italian) + s[1..];
}
