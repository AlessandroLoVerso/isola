using Isola.Core;

namespace Isola.Settings;

public enum IslandShape { Isola, Notch }

public enum FullscreenBehavior { Striscia, Nascondi }

/// <summary>Global settings, stored in %LocalAppData%\Isola\settings.json.</summary>
public sealed class GlobalSettings
{
    public const double MaxEdgeOffset = 24;

    public IslandShape Shape { get; set; } = IslandShape.Isola;

    /// <summary>"nero", "grafite", or the Id of an IIslandBackdrop.</summary>
    public string Theme { get; set; } = DefaultTheme;

    /// <summary>First run: "vetro" (frosted glass) on Windows 11, "nero" on Windows 10.</summary>
    public static string DefaultTheme => Environment.OSVersion.Version.Build >= 22000 ? "vetro" : "nero";

    /// <summary>Screen.DeviceName of the chosen monitor; null = primary.</summary>
    public string? Monitor { get; set; }

    /// <summary>Distance from the top edge in DIP (shape "isola" only).</summary>
    public double EdgeOffset { get; set; } = 8;

    public FullscreenBehavior Fullscreen { get; set; } = FullscreenBehavior.Striscia;

    /// <summary>Glass themes: keep the island visible to screenshots/recordings ("Liquido"
    /// then falls back to "Vetro", since real refraction needs the island hidden from capture).</summary>
    public bool ShowInScreenshots { get; set; }

    /// <summary>Module id → enabled. Missing = the module's EnabledByDefault.</summary>
    public Dictionary<string, bool> Modules { get; set; } = new();
}

/// <summary>Holds the current settings, saves them and notifies listeners (applied live).</summary>
public sealed class GlobalSettingsStore
{
    public GlobalSettings Current { get; private set; }

    /// <summary>The store loaded by the app (for code without a reference to it, e.g. backdrops).</summary>
    public static GlobalSettingsStore? Instance { get; private set; }

    public event EventHandler? Changed;

    private GlobalSettingsStore(GlobalSettings current) => Current = current;

    public static GlobalSettingsStore Load()
    {
        var s = JsonStore.Load<GlobalSettings>(AppPaths.GlobalSettingsFile);
        s.Modules ??= new();
        s.Theme = string.IsNullOrWhiteSpace(s.Theme) ? GlobalSettings.DefaultTheme : s.Theme.Trim().ToLowerInvariant();
        s.EdgeOffset = Math.Clamp(double.IsFinite(s.EdgeOffset) ? s.EdgeOffset : 8, 0, GlobalSettings.MaxEdgeOffset);
        return Instance = new GlobalSettingsStore(s);
    }

    public void Update(Action<GlobalSettings> change)
    {
        change(Current);
        Current.EdgeOffset = Math.Clamp(Current.EdgeOffset, 0, GlobalSettings.MaxEdgeOffset);
        JsonStore.Save(AppPaths.GlobalSettingsFile, Current);
        try { Changed?.Invoke(this, EventArgs.Empty); }
        catch (Exception ex) { Log.Error("Errore applicando le impostazioni", ex); }
    }

    /// <summary>Saves without raising Changed (for bookkeeping such as module toggles).</summary>
    public void SaveQuietly(Action<GlobalSettings> change)
    {
        change(Current);
        JsonStore.Save(AppPaths.GlobalSettingsFile, Current);
    }
}
