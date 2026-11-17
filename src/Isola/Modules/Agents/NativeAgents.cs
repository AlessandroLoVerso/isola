using System.Runtime.InteropServices;
using System.Text;

namespace Isola.Modules.Agents;

/// <summary>Finds the terminal / editor window that most likely hosts a Claude Code session and
/// brings it to the front.</summary>
internal static class NativeAgents
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(int pid);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

    private const int SW_RESTORE = 9;
    private const uint GW_OWNER = 4;
    private const byte VK_MENU = 0x12;
    private const uint KEYEVENTF_KEYUP = 2;

    /// <summary>Returns true if a window was found and activated.</summary>
    public static bool FocusFor(string folder)
    {
        IntPtr best = IntPtr.Zero;
        int bestScore = 0;
        EnumWindows((h, _) =>
        {
            if (!IsWindowVisible(h) || GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
            var title = Read(h, GetWindowText);
            if (title.Length == 0) return true;
            var cls = Read(h, GetClassName);
            int score = 0;
            if (folder.Length > 0 && title.Contains(folder, StringComparison.OrdinalIgnoreCase)) score += 100;
            if (title.Contains("Claude", StringComparison.OrdinalIgnoreCase)) score += 10;
            if (cls == "CASCADIA_HOSTING_WINDOW_CLASS" || cls == "ConsoleWindowClass") score += 5;
            GetWindowThreadProcessId(h, out int pid);
            if (pid == Environment.ProcessId) return true;
            if (score > bestScore) { bestScore = score; best = h; }
            return true;
        }, IntPtr.Zero);
        if (best == IntPtr.Zero) return false;

        if (IsIconic(best)) ShowWindow(best, SW_RESTORE);
        AllowSetForegroundWindow(-1);
        if (!SetForegroundWindow(best))
        {
            // The "ALT trick": a synthetic key press makes Windows treat us as the input owner.
            keybd_event(VK_MENU, 0, 0, IntPtr.Zero);
            keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, IntPtr.Zero);
            SetForegroundWindow(best);
        }
        return true;
    }

    private static string Read(IntPtr h, Func<IntPtr, StringBuilder, int, int> f)
    {
        var sb = new StringBuilder(256);
        f(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
