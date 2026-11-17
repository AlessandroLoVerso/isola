using System.Text;

namespace Isola.Core;

/// <summary>Tiny thread-safe file logger: %LocalAppData%\Isola\logs\isola.log (rolled at 1 MB,
/// one old file kept). The user profile folder is replaced by "%USERPROFILE%" in every line, so
/// paths in messages and stack traces don't carry the account name.</summary>
public static class Log
{
    private const long MaxBytes = 1024 * 1024;
    private static readonly object Gate = new();
    private static readonly string? Profile = ProfileFolder();

    private static string? ProfileFolder()
    {
        try
        {
            var p = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd('\\', '/');
            return p.Length > 3 ? p : null; // never scrub a bare drive root
        }
        catch { return null; }
    }

    private static string Scrub(string s)
        => Profile == null ? s : s.Replace(Profile, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);

    public static void Info(string message) => Write("INFO", message, null);

    public static void Warn(string message, Exception? ex = null) => Write("WARN", message, ex);

    public static void Error(string message, Exception? ex = null) => Write("ERROR", message, ex);

    private static void Write(string level, string message, Exception? ex)
    {
        try
        {
            var sb = new StringBuilder();
            sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")).Append(" [").Append(level).Append("] ")
              .Append(message);
            if (ex != null) sb.AppendLine().Append(ex);
            sb.AppendLine();
            var line = Scrub(sb.ToString());

            lock (Gate)
            {
                Directory.CreateDirectory(AppPaths.LogsDirectory);
                var file = new FileInfo(AppPaths.LogFile);
                if (file.Exists && file.Length > MaxBytes)
                {
                    var old = AppPaths.LogFile + ".1";
                    File.Delete(old);
                    File.Move(AppPaths.LogFile, old);
                }
                File.AppendAllText(AppPaths.LogFile, line, Encoding.UTF8);
            }
#if DEBUG
            System.Diagnostics.Debug.Write(line);
#endif
        }
        catch
        {
            // Logging must never take the app down.
        }
    }
}
