using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Threading;
using Isola.Settings;

namespace Isola.Core;

/// <summary>What the module manager needs from the island window.</summary>
internal interface IIslandSurface
{
    IntPtr Hwnd { get; }
    bool IsFullscreenAppActive { get; }
    void RefreshRestingFace();
    void OpenTab(string moduleId);
    void Attention(string moduleId, TimeSpan duration);
    void RequestKeyboardFocus();
}

/// <summary>State of one discovered module.</summary>
public sealed class ModuleEntry
{
    internal ModuleEntry(IIslandModule module, string id)
    {
        Module = module;
        Id = id;
    }

    public IIslandModule Module { get; }
    public string Id { get; }
    public bool IsRunning { get; internal set; }

    /// <summary>Set when the module threw; it stays off for this session.</summary>
    public string? LastError { get; internal set; }

    /// <summary>The card created after Start (null = no tab).</summary>
    public FrameworkElement? Card { get; internal set; }

    internal ModuleHost? Host { get; set; }

    public string Title => Safe(() => Module.Title, Id);
    public string Glyph => Safe(() => Module.Glyph, "");
    public int Order => Safe(() => Module.Order, 1000);

    private static T Safe<T>(Func<T> f, T fallback)
    {
        try { return f() ?? fallback; } catch { return fallback; }
    }
}

/// <summary>Discovers modules by reflection, starts/stops them and isolates their failures.</summary>
public sealed class ModuleManager
{
    private readonly GlobalSettingsStore _settings;
    private readonly List<ModuleEntry> _entries = new();
    private IIslandSurface? _surface;
    private bool _changePosted;

    public ModuleManager(GlobalSettingsStore settings, Dispatcher dispatcher)
    {
        _settings = settings;
        Dispatcher = dispatcher;
    }

    public Dispatcher Dispatcher { get; }

    /// <summary>All discovered modules, sorted by Order.</summary>
    public IReadOnlyList<ModuleEntry> Entries => _entries;

    public IEnumerable<ModuleEntry> Running => _entries.Where(e => e.IsRunning);

    /// <summary>Raised (deferred, on the UI thread) when modules start/stop/fail.</summary>
    public event EventHandler? Changed;

    internal IIslandSurface? Surface => _surface;

    internal void Attach(IIslandSurface surface) => _surface = surface;

    // ---- Discovery -----------------------------------------------------------------------

    public void Discover()
    {
        IEnumerable<Type> types;
        try
        {
            types = Assembly.GetExecutingAssembly().GetTypes();
        }
        catch (ReflectionTypeLoadException ex)
        {
            Log.Error("Alcuni tipi non si caricano", ex);
            types = ex.Types.Where(t => t != null)!;
        }

        foreach (var type in types)
        {
            if (type.IsAbstract || type.IsInterface || !typeof(IIslandModule).IsAssignableFrom(type)) continue;
            if (type.GetConstructor(Type.EmptyTypes) is not { IsPublic: true }) continue;

            try
            {
                var module = (IIslandModule)Activator.CreateInstance(type)!;
                var id = module.Id?.Trim();
                if (string.IsNullOrEmpty(id))
                {
                    Log.Warn($"Modulo {type.FullName} senza Id: ignorato");
                    continue;
                }
                if (_entries.Any(e => string.Equals(e.Id, id, StringComparison.OrdinalIgnoreCase)))
                {
                    Log.Warn($"Id di modulo duplicato '{id}' ({type.FullName}): ignorato");
                    continue;
                }
                _entries.Add(new ModuleEntry(module, id));
            }
            catch (Exception ex)
            {
                Log.Error($"Impossibile creare il modulo {type.FullName}", ex);
            }
        }

        _entries.Sort((a, b) => a.Order != b.Order ? a.Order.CompareTo(b.Order) : string.CompareOrdinal(a.Id, b.Id));
        Log.Info($"Moduli trovati: {string.Join(", ", _entries.Select(e => e.Id))}");
    }

    public ModuleEntry? Find(string moduleId)
        => _entries.FirstOrDefault(e => string.Equals(e.Id, moduleId, StringComparison.OrdinalIgnoreCase));

    public bool IsEnabled(ModuleEntry entry)
        => _settings.Current.Modules.TryGetValue(entry.Id, out var on)
            ? on
            : Call(entry, "EnabledByDefault", () => entry.Module.EnabledByDefault, false);

    // ---- Lifecycle -----------------------------------------------------------------------

    public void StartEnabled()
    {
        foreach (var e in _entries)
            if (IsEnabled(e)) Start(e);
        PostChanged();
    }

    /// <summary>Toggle from the Settings window: persisted and applied live.</summary>
    public void SetEnabled(string moduleId, bool enabled)
    {
        var e = Find(moduleId);
        if (e == null) return;
        _settings.SaveQuietly(s => s.Modules[e.Id] = enabled);
        if (enabled)
        {
            e.LastError = null;
            Start(e);
        }
        else
        {
            Stop(e);
        }
        PostChanged();
    }

    private void Start(ModuleEntry e)
    {
        if (e.IsRunning) return;
        var host = new ModuleHost(this, e);
        e.Host = host;
        try
        {
            e.Module.Start(host);
            e.IsRunning = true;
        }
        catch (Exception ex)
        {
            Fail(e, "Start", ex);
            return;
        }

        e.Card = Call(e, "CreateCard", () => e.Module.CreateCard(), null);
        if (e.IsRunning) Log.Info($"Modulo avviato: {e.Id}");
    }

    private void Stop(ModuleEntry e)
    {
        // Host is set by Start even when Start throws, so a half-started module is stopped too.
        if (e.Host == null) return;
        e.IsRunning = false;
        e.Card = null;
        e.Host.Dispose();
        e.Host = null;
        try { e.Module.Stop(); }
        catch (Exception ex) { Log.Error($"[{e.Id}] Stop ha lanciato un'eccezione", ex); }
        Log.Info($"Modulo fermato: {e.Id}");
    }

    public void StopAll()
    {
        foreach (var e in _entries.AsEnumerable().Reverse()) Stop(e);
    }

    /// <summary>Disables a module for this session after it threw.</summary>
    internal void Fail(ModuleEntry e, string where, Exception ex)
    {
        Log.Error($"[{e.Id}] errore in {where}: il modulo viene disattivato", ex);
        e.LastError = $"{where}: {ex.GetType().Name}: {ex.Message}";
        Stop(e);
        PostChanged();
    }

    /// <summary>Runs module code; on exception the module is disabled and fallback returned.</summary>
    public T Call<T>(ModuleEntry e, string where, Func<T> f, T fallback)
    {
        try { return f(); }
        catch (Exception ex)
        {
            Fail(e, where, ex);
            return fallback;
        }
    }

    public bool Call(ModuleEntry e, string where, Action a)
    {
        try { a(); return true; }
        catch (Exception ex)
        {
            Fail(e, where, ex);
            return false;
        }
    }

    private void PostChanged()
    {
        if (_changePosted) return;
        _changePosted = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Normal, () =>
        {
            _changePosted = false;
            try { Changed?.Invoke(this, EventArgs.Empty); }
            catch (Exception ex) { Log.Error("Errore aggiornando l'isola dopo un cambio di moduli", ex); }
        });
    }

    // ---- Routing -------------------------------------------------------------------------

    /// <summary>WndProc of the island: offers the message to every running module's hooks.</summary>
    internal bool DispatchMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        foreach (var e in _entries)
        {
            if (!e.IsRunning || e.Host == null) continue;
            if (e.Host.DispatchMessage(msg, wParam, lParam)) return true;
        }
        return false;
    }

    internal void RaiseFullscreenChanged()
    {
        foreach (var e in _entries.ToList())
            if (e.IsRunning) e.Host?.RaiseFullscreenChanged();
    }

    /// <summary>For unhandled exceptions: finds the module whose code is on the stack.</summary>
    public ModuleEntry? FindCulprit(Exception ex)
    {
        for (var cur = ex; cur != null; cur = cur.InnerException)
        {
            StackFrame[] frames;
            try { frames = new StackTrace(cur, false).GetFrames(); }
            catch { continue; }

            foreach (var frame in frames)
            {
                var type = frame.GetMethod()?.DeclaringType;
                while (type?.DeclaringType != null) type = type.DeclaringType; // lambdas, async state machines
                if (type == null) continue;
                foreach (var e in _entries)
                {
                    var mt = e.Module.GetType();
                    if (type == mt || (mt.Namespace != null && mt.Namespace.StartsWith("Isola.Modules.", StringComparison.Ordinal)
                                       && type.Namespace == mt.Namespace))
                        return e;
                }
            }
        }
        return null;
    }
}
