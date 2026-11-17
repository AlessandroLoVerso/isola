using static Isola.Native.NativeMethods;
using Forms = System.Windows.Forms;

namespace Isola.Island;

/// <summary>A monitor in physical pixels (the process is PerMonitorV2 aware).</summary>
public sealed record MonitorInfo(string DeviceName, string Label, bool IsPrimary,
    int Left, int Top, int Width, int Height, double Scale);

public static class MonitorService
{
    /// <summary>Every monitor, the primary first, then left to right (top to bottom on ties), so
    /// "Monitor 1" in Settings is always the main screen.</summary>
    public static IReadOnlyList<MonitorInfo> All()
    {
        var screens = Forms.Screen.AllScreens
            .OrderByDescending(s => s.Primary)
            .ThenBy(s => s.Bounds.Left)
            .ThenBy(s => s.Bounds.Top)
            .ToArray();
        if (screens.Length == 0 && Forms.Screen.PrimaryScreen is { } primary) screens = new[] { primary };
        var list = new List<MonitorInfo>(screens.Length);
        for (int i = 0; i < screens.Length; i++)
        {
            var s = screens[i];
            var b = s.Bounds;
            double scale = ScaleAt(b.Left + b.Width / 2, b.Top + b.Height / 2);
            var label = $"Monitor {i + 1}" + (s.Primary ? " (principale)" : "") + $" · {b.Width}×{b.Height}";
            list.Add(new MonitorInfo(s.DeviceName, label, s.Primary, b.Left, b.Top, b.Width, b.Height, scale));
        }
        return list;
    }

    /// <summary>The chosen monitor, falling back to the primary one.</summary>
    public static MonitorInfo Resolve(string? deviceName)
    {
        var all = All();
        return all.FirstOrDefault(m => deviceName != null && string.Equals(m.DeviceName, deviceName, StringComparison.OrdinalIgnoreCase))
            ?? all.FirstOrDefault(m => m.IsPrimary)
            ?? all.FirstOrDefault()
            // No monitor at all (e.g. every display asleep / RDP reconnecting): a safe 1080p guess.
            ?? new MonitorInfo("", "Monitor", true, 0, 0, 1920, 1080, 1.0);
    }

    /// <summary>Effective DPI scale (1.0 = 96 DPI) of the monitor containing the point.</summary>
    public static double ScaleAt(int x, int y)
    {
        var mon = MonitorFromPoint(new POINT(x, y), MONITOR_DEFAULTTONEAREST);
        if (mon != IntPtr.Zero && GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, out uint dpiX, out _) == 0 && dpiX > 0)
            return dpiX / 96.0;
        return 1.0;
    }

    internal static RECT? MonitorRectOf(IntPtr hmonitor)
    {
        var mi = MONITORINFO.Create();
        return GetMonitorInfo(hmonitor, ref mi) ? mi.rcMonitor : null;
    }
}
