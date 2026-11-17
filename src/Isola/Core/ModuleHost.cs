using System.Windows.Threading;

namespace Isola.Core;

/// <summary>The IIslandHost given to one module. Tracks what the module registered so it can be
/// removed when the module stops, and isolates the module's exceptions.</summary>
internal sealed class ModuleHost : IIslandHost, IDisposable
{
    private readonly ModuleManager _manager;
    private readonly ModuleEntry _entry;
    private readonly List<Func<int, IntPtr, IntPtr, bool>> _hooks = new();
    private readonly List<EventHandler> _fullscreenHandlers = new();
    private volatile bool _disposed;

    public ModuleHost(ModuleManager manager, ModuleEntry entry)
    {
        _manager = manager;
        _entry = entry;
    }

    public Dispatcher Dispatcher => _manager.Dispatcher;

    public IntPtr Hwnd => _manager.Surface?.Hwnd ?? IntPtr.Zero;

    public bool IsFullscreenAppActive => _manager.Surface?.IsFullscreenAppActive ?? false;

    public event EventHandler? FullscreenChanged
    {
        add { if (value != null) lock (_fullscreenHandlers) _fullscreenHandlers.Add(value); }
        remove { if (value != null) lock (_fullscreenHandlers) _fullscreenHandlers.Remove(value); }
    }

    public void AddMessageHook(Func<int, IntPtr, IntPtr, bool> hook)
    {
        ArgumentNullException.ThrowIfNull(hook);
        if (_disposed) return;
        lock (_hooks) _hooks.Add(hook);
    }

    public void RefreshRestingFace() => OnUi(s => s.RefreshRestingFace());

    public void OpenTab(string moduleId) => OnUi(s => s.OpenTab(moduleId));

    public void Attention(string moduleId, TimeSpan duration) => OnUi(s => s.Attention(moduleId, duration));

    public void RequestKeyboardFocus() => OnUi(s => s.RequestKeyboardFocus());

    public T LoadSettings<T>(string moduleId) where T : new()
        => JsonStore.Load<T>(AppPaths.ModuleSettingsFile(moduleId));

    public void SaveSettings<T>(string moduleId, T value)
        => JsonStore.Save(AppPaths.ModuleSettingsFile(moduleId), value);

    public string DataDirectory(string moduleId) => AppPaths.ModuleDataDirectory(moduleId);

    public void Log(string moduleId, string message) => Core.Log.Info($"[{moduleId}] {message}");

    // ---- Internal ------------------------------------------------------------------------

    private void OnUi(Action<IIslandSurface> action)
    {
        if (_disposed) return;
        void Run()
        {
            if (_disposed || _manager.Surface is not { } surface) return;
            try { action(surface); }
            catch (Exception ex) { Core.Log.Error($"[{_entry.Id}] errore dell'isola", ex); }
        }
        if (Dispatcher.CheckAccess()) Run();
        else Dispatcher.BeginInvoke(Run);
    }

    internal bool DispatchMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        Func<int, IntPtr, IntPtr, bool>[] hooks;
        lock (_hooks)
        {
            if (_hooks.Count == 0) return false;
            hooks = _hooks.ToArray();
        }
        foreach (var hook in hooks)
        {
            if (_disposed) return false;
            try
            {
                if (hook(msg, wParam, lParam)) return true;
            }
            catch (Exception ex)
            {
                _manager.Fail(_entry, $"message hook (0x{msg:X4})", ex);
                return false;
            }
        }
        return false;
    }

    internal void RaiseFullscreenChanged()
    {
        EventHandler[] handlers;
        lock (_fullscreenHandlers) handlers = _fullscreenHandlers.ToArray();
        foreach (var h in handlers)
        {
            if (_disposed) return;
            if (!_manager.Call(_entry, "FullscreenChanged", () => h(this, EventArgs.Empty))) return;
        }
    }

    public void Dispose()
    {
        _disposed = true;
        lock (_hooks) _hooks.Clear();
        lock (_fullscreenHandlers) _fullscreenHandlers.Clear();
    }
}
