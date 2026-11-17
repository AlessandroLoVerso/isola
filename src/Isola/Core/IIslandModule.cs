using System.Windows;

namespace Isola.Core;

// The module contract. Keep this file stable: every feature module under src/Isola/Modules/
// is written against it. See MODULES.md next to this file for the rules.

/// <summary>A feature of the island. Discovered by reflection: any public, non-abstract type
/// implementing this interface with a public parameterless constructor is loaded.</summary>
public interface IIslandModule
{
    /// <summary>Stable, unique, lowercase id, e.g. "music". Used for settings and data paths.</summary>
    string Id { get; }

    /// <summary>Short Italian tab label, e.g. "Musica".</summary>
    string Title { get; }

    /// <summary>Segoe Fluent Icons glyph, e.g. "".</summary>
    string Glyph { get; }

    /// <summary>Tab order (ascending). Also breaks ties between resting faces.</summary>
    int Order { get; }

    /// <summary>Whether the module is on when the user has never toggled it.</summary>
    bool EnabledByDefault { get; }

    /// <summary>Called on the UI thread when the module is switched on.</summary>
    void Start(IIslandHost host);

    /// <summary>Called on the UI thread when the module is switched off or the app exits.
    /// Release timers, hooks, event subscriptions and native resources here.</summary>
    void Stop();

    /// <summary>Content of the module's tab in the open card (about 424x186 DIP).
    /// Called once after Start. Return null for "no tab".</summary>
    FrameworkElement? CreateCard();

    /// <summary>Content of the module's page in the Settings window. Called each time the page
    /// is shown. Return null for "no page".</summary>
    FrameworkElement? CreateSettingsPage();
}

/// <summary>Optional: the module can fill the CLOSED pill (and the "peek" shown by Attention).</summary>
public interface IRestingFaceProvider
{
    /// <summary>Current priority; 0 = nothing to show. The highest priority wins.</summary>
    int RestingPriority { get; }

    /// <summary>Returns a NEW element each call (the host may need several: pill and peek).
    /// It is stretched over the whole pill; lay out left/right/centre content yourself.</summary>
    FrameworkElement CreateRestingFace();
}

/// <summary>Optional: the module can fill the slim strip shown above fullscreen apps.</summary>
public interface IStripProvider
{
    /// <summary>Returns a NEW element each call, stretched over the strip (about 272x24 DIP).</summary>
    FrameworkElement CreateStrip();

    /// <summary>True when the module has something to show in the strip right now.</summary>
    bool WantsStrip { get; }
}

/// <summary>What the island offers to a module. Each module gets its own instance.
/// All members are safe to call from any thread unless noted.</summary>
public interface IIslandHost
{
    /// <summary>The UI thread dispatcher. Marshal UI updates through it.</summary>
    System.Windows.Threading.Dispatcher Dispatcher { get; }

    /// <summary>Handle of the island window (for RegisterHotKey, AddClipboardFormatListener...).</summary>
    IntPtr Hwnd { get; }

    /// <summary>Adds a hook on the island window's WndProc: (msg, wParam, lParam) => handled.
    /// Return true to mark the message handled. Removed automatically when the module stops.</summary>
    void AddMessageHook(Func<int, IntPtr, IntPtr, bool> hook);

    /// <summary>Re-evaluates RestingPriority of all modules (and WantsStrip) and updates the pill.</summary>
    void RefreshRestingFace();

    /// <summary>Opens the card on the given module's tab.</summary>
    void OpenTab(string moduleId);

    /// <summary>Briefly expands the pill to a "peek" showing the module's resting face
    /// (notification, reminder...). Also shown above fullscreen apps.</summary>
    void Attention(string moduleId, TimeSpan duration);

    /// <summary>Lets the open card receive keyboard input (text boxes). Call it when the user
    /// clicks into a text field. Restored automatically when the card closes.</summary>
    void RequestKeyboardFocus();

    /// <summary>True while an app covers the island's monitor (game, video...).</summary>
    bool IsFullscreenAppActive { get; }

    /// <summary>Raised on the UI thread when IsFullscreenAppActive changes.</summary>
    event EventHandler? FullscreenChanged;

    /// <summary>Reads %LocalAppData%\Isola\settings\{moduleId}.json, or new T() if missing/corrupt.</summary>
    T LoadSettings<T>(string moduleId) where T : new();

    /// <summary>Writes %LocalAppData%\Isola\settings\{moduleId}.json.</summary>
    void SaveSettings<T>(string moduleId, T value);

    /// <summary>%LocalAppData%\Isola\data\{moduleId}\ (created if missing).</summary>
    string DataDirectory(string moduleId);

    /// <summary>Appends a line to %LocalAppData%\Isola\logs\isola.log.</summary>
    void Log(string moduleId, string message);
}
