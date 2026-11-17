using Isola.Core;
using Microsoft.Win32;

namespace Isola.Settings;

/// <summary>"Avvia con Windows": HKCU\Software\Microsoft\Windows\CurrentVersion\Run, value "Isola".</summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Isola";

    private static string Command => $"\"{Environment.ProcessPath}\"";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(ValueName) is string s && s.Length > 0;
        }
        catch (Exception ex)
        {
            Log.Warn("Impossibile leggere la voce di avvio", ex);
            return false;
        }
    }

    /// <summary>True when the Run entry exists but points to another exe (e.g. an old build).</summary>
    public static bool PointsElsewhere()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(ValueName) is string s && s.Length > 0
                && !string.Equals(s, Command, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    public static bool SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (enabled) key.SetValue(ValueName, Command, RegistryValueKind.String);
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
            Log.Info(enabled ? "Avvio con Windows attivato" : "Avvio con Windows disattivato");
            return true;
        }
        catch (Exception ex)
        {
            Log.Error("Impossibile cambiare la voce di avvio", ex);
            return false;
        }
    }
}
