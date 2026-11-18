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
            SetTask(enabled);
            Log.Info(enabled ? "Avvio con Windows attivato" : "Avvio con Windows disattivato");
            return true;
        }
        catch (Exception ex)
        {
            Log.Error("Impossibile cambiare la voce di avvio", ex);
            return false;
        }
    }

    /// <summary>Called at every start: when autostart is on, re-points the Run value and the
    /// logon task at this exe (repairs a moved/updated install). Runs off the UI thread.</summary>
    public static void RepairInBackground()
    {
        Task.Run(() =>
        {
            try { if (IsEnabled()) SetEnabled(true); }
            catch (Exception ex) { Log.Warn("Riparazione dell'avvio non riuscita", ex); }
        });
    }

    // A second, independent path: a Task Scheduler logon task. The Run key can be switched off by
    // "App di avvio" or delayed by Windows; the task also restarts Isola if it exits with an error.
    // Both may fire at logon: the single-instance mutex keeps only one copy.
    private const string TaskName = "Isola";

    private static void SetTask(bool enabled)
    {
        try
        {
            if (!enabled) { RunSchtasks($"/delete /tn \"{TaskName}\" /f"); return; }
            var exe = Environment.ProcessPath ?? "";
            if (exe.Length == 0) return;
            string user = System.Security.Principal.WindowsIdentity.GetCurrent().Name;
            string xml = $"""
                <?xml version="1.0" encoding="UTF-16"?>
                <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
                  <RegistrationInfo><Description>Avvia Isola all'accesso</Description></RegistrationInfo>
                  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{System.Security.SecurityElement.Escape(user)}</UserId><Delay>PT10S</Delay></LogonTrigger></Triggers>
                  <Principals><Principal id="Author"><UserId>{System.Security.SecurityElement.Escape(user)}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
                  <Settings>
                    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
                    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
                    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
                    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
                    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>
                    <StartWhenAvailable>true</StartWhenAvailable>
                    <Enabled>true</Enabled>
                  </Settings>
                  <Actions Context="Author"><Exec><Command>{System.Security.SecurityElement.Escape(exe)}</Command></Exec></Actions>
                </Task>
                """;
            var file = Path.Combine(Path.GetTempPath(), "isola-task.xml");
            File.WriteAllText(file, xml, System.Text.Encoding.Unicode);
            try { RunSchtasks($"/create /tn \"{TaskName}\" /xml \"{file}\" /f"); }
            finally { try { File.Delete(file); } catch { } }
        }
        catch (Exception ex) { Log.Warn("Attività di avvio non aggiornata", ex); }
    }

    private static void RunSchtasks(string args)
    {
        var psi = new System.Diagnostics.ProcessStartInfo("schtasks.exe", args)
        {
            CreateNoWindow = true, UseShellExecute = false,
            RedirectStandardOutput = true, RedirectStandardError = true,
        };
        using var p = System.Diagnostics.Process.Start(psi);
        if (p == null) return;
        p.StandardOutput.ReadToEnd(); p.StandardError.ReadToEnd();
        if (!p.WaitForExit(10000)) { try { p.Kill(); } catch { } return; }
        if (p.ExitCode != 0) Log.Warn($"schtasks ha restituito {p.ExitCode}");
    }
}
