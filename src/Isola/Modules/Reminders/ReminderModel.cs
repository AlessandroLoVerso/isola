using System.Globalization;
using Isola.Core;

namespace Isola.Modules.Reminders;

public enum ReminderRepeat { None, Daily, Weekdays, Weekly }

/// <summary>One reminder. <see cref="Due"/> is local wall-clock time (a reminder for 20:00 stays at
/// 20:00 if the time zone or DST changes). <see cref="Anchor"/> keeps the time of day (and weekday)
/// a repeating reminder was created for, so a snooze doesn't shift the series.</summary>
public sealed class Reminder
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public DateTime Due { get; set; }
    public DateTime Anchor { get; set; }
    public ReminderRepeat Repeat { get; set; }
}

public sealed class ReminderData
{
    public List<Reminder> Items { get; set; } = new();
}

/// <summary>JSON file in the module's data folder.</summary>
internal sealed class ReminderStore
{
    private readonly string _path;
    public List<Reminder> Items { get; }

    public ReminderStore(string dataDirectory)
    {
        _path = Path.Combine(dataDirectory, "reminders.json");
        Items = JsonStore.Load<ReminderData>(_path).Items
            .Where(r => !string.IsNullOrWhiteSpace(r.Text) && r.Due != default)
            .ToList();
        foreach (var r in Items)
        {
            r.Due = DateTime.SpecifyKind(r.Due, DateTimeKind.Local);
            if (r.Anchor == default) r.Anchor = r.Due;
        }
    }

    public void Save() => JsonStore.Save(_path, new ReminderData { Items = Items });
}

internal static class Recurrence
{
    public static bool Matches(ReminderRepeat repeat, DateTime day, DateTime anchor) => repeat switch
    {
        ReminderRepeat.Weekdays => day.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday),
        ReminderRepeat.Weekly => day.DayOfWeek == anchor.DayOfWeek,
        _ => true,
    };

    /// <summary>First occurrence of the series strictly after <paramref name="after"/>.</summary>
    public static DateTime NextAfter(Reminder r, DateTime after)
    {
        var candidate = after.Date + r.Anchor.TimeOfDay;
        for (int i = 0; i < 9; i++, candidate = candidate.AddDays(1))
            if (candidate > after && Matches(r.Repeat, candidate, r.Anchor)) return candidate;
        return after.AddDays(1);
    }

    /// <summary>For a new repeating reminder: the chosen moment, moved forward to a matching day.</summary>
    public static DateTime FirstOnOrAfter(ReminderRepeat repeat, DateTime chosen)
    {
        var c = chosen;
        for (int i = 0; i < 8 && !Matches(repeat, c, chosen); i++) c = c.AddDays(1);
        return c;
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

    public static string Day(DateTime t, DateTime now)
    {
        if (t.Date == now.Date) return "oggi";
        if (t.Date == now.Date.AddDays(1)) return "domani";
        if (t.Date == now.Date.AddDays(-1)) return "ieri";
        if (t.Date > now.Date && t.Date < now.Date.AddDays(7)) return t.ToString("dddd", Italian);
        return t.ToString("ddd d MMM", Italian).Replace(".", "");
    }

    public static string When(DateTime t, DateTime now) => $"{Day(t, now)} {Time(t)}";

    public static string RepeatLabel(ReminderRepeat r) => r switch
    {
        ReminderRepeat.Daily => "Ogni giorno",
        ReminderRepeat.Weekdays => "Giorni feriali",
        ReminderRepeat.Weekly => "Ogni settimana",
        _ => "Mai",
    };

    public static bool TryParseTime(string s, out TimeSpan time)
    {
        time = default;
        s = s.Trim().Replace('.', ':').Replace(',', ':');
        if (s.Length == 0) return false;
        string[] formats = { "H:mm", "HH:mm", "H", "HH", "Hmm", "HHmm" };
        if (DateTime.TryParseExact(s, formats, Italian, DateTimeStyles.None, out var dt)) { time = dt.TimeOfDay; return true; }
        if (DateTime.TryParse(s, CultureInfo.CurrentCulture, DateTimeStyles.NoCurrentDateDefault, out dt)) { time = dt.TimeOfDay; return true; }
        return false;
    }

    /// <summary>Parses "oggi", "domani", "dd/mm", "dd/mm/yyyy". Empty = null (next occurrence).</summary>
    public static bool TryParseDate(string s, DateTime now, out DateTime? date)
    {
        date = null;
        s = s.Trim().ToLowerInvariant().Replace('.', '/').Replace('-', '/');
        if (s.Length == 0) return true;
        if (s == "oggi") { date = now.Date; return true; }
        if (s == "domani") { date = now.Date.AddDays(1); return true; }
        if (s == "dopodomani") { date = now.Date.AddDays(2); return true; }
        if (DateTime.TryParseExact(s, new[] { "d/M/yyyy", "d/M/yy" }, Italian, DateTimeStyles.None, out var dt)) { date = dt.Date; return true; }
        if (DateTime.TryParseExact(s, new[] { "d/M" }, Italian, DateTimeStyles.None, out dt))
        {
            var d = new DateTime(now.Year, dt.Month, dt.Day);
            if (d < now.Date) d = d.AddYears(1);
            date = d;
            return true;
        }
        return false;
    }
}
