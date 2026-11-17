namespace Isola.Core;

/// <summary>Where Isola keeps its files: everything under %LocalAppData%\Isola.</summary>
public static class AppPaths
{
    public static string Root { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Isola");

    public static string LogsDirectory => Path.Combine(Root, "logs");
    public static string LogFile => Path.Combine(LogsDirectory, "isola.log");
    public static string GlobalSettingsFile => Path.Combine(Root, "settings.json");
    public static string ModuleSettingsDirectory => Path.Combine(Root, "settings");
    public static string DataRoot => Path.Combine(Root, "data");

    public static string ModuleSettingsFile(string moduleId)
        => Path.Combine(ModuleSettingsDirectory, SafeName(moduleId) + ".json");

    public static string ModuleDataDirectory(string moduleId)
    {
        var dir = Path.Combine(DataRoot, SafeName(moduleId));
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>Turns a module id into a safe file name (no separators, no "..").</summary>
    public static string SafeName(string id)
    {
        if (string.IsNullOrWhiteSpace(id)) return "_";
        var invalid = Path.GetInvalidFileNameChars();
        var chars = id.Trim().Select(c => invalid.Contains(c) || c == '.' ? '_' : c).ToArray();
        return new string(chars);
    }
}
