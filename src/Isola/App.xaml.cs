using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Isola.Core;
using Isola.Island;
using Isola.Settings;
using Isola.Tray;

namespace Isola;

public partial class App : System.Windows.Application
{
    private const string MutexName = @"Local\Isola.SingleInstance.7f3c2a1e";

    private Mutex? _mutex;
    private bool _ownsMutex;
    private GlobalSettingsStore? _settings;
    private ModuleManager? _modules;
    private IslandWindow? _island;
    private TrayIcon? _tray;
    private SettingsWindow? _settingsWindow;
    private bool _shuttingDown;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Dev helper: `Isola.exe --export-icon <path>` writes the generated .ico and exits.
        int iconArg = Array.IndexOf(e.Args, "--export-icon");
        if (iconArg >= 0 && iconArg + 1 < e.Args.Length)
        {
            IconFactory.WriteIco(e.Args[iconArg + 1]);
            Shutdown();
            return;
        }

        InstallExceptionHandlers();

        if (!AcquireSingleInstance(waitForPrevious: e.Args.Contains("--restart")))
        {
            Log.Info("Isola è già in esecuzione: esco");
            Shutdown();
            return;
        }

        Log.Info($"Avvio di Isola {typeof(App).Assembly.GetName().Version}");

        _settings = GlobalSettingsStore.Load();
        Isola.Settings.StartupRegistration.RepairInBackground();
        _modules = new ModuleManager(_settings, Dispatcher);
        _modules.Discover();

        _island = new IslandWindow(_settings, _modules);
        _island.SettingsRequested += (_, _) => OpenSettings();
        _modules.Attach(_island);
        _island.Show();                     // creates the HWND (SourceInitialized) before modules start
        ThemeManager.Apply(_settings.Current.Theme);

        _modules.StartEnabled();

        _tray = new TrayIcon(OpenSettings, Restart, ExitApp);
    }

    private bool AcquireSingleInstance(bool waitForPrevious)
    {
        _mutex = new Mutex(false, MutexName);
        try
        {
            _ownsMutex = _mutex.WaitOne(waitForPrevious ? TimeSpan.FromSeconds(10) : TimeSpan.Zero);
        }
        catch (AbandonedMutexException)
        {
            _ownsMutex = true; // previous instance crashed
        }
        return _ownsMutex;
    }

    private void InstallExceptionHandlers()
    {
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            Log.Error($"Eccezione non gestita (terminating={args.IsTerminating})", args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Error("Eccezione in un Task non osservato", args.Exception);
            args.SetObserved();
        };
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        // Keep the app alive: log, and switch off the module whose code threw (if any).
        e.Handled = true;
        try
        {
            var culprit = _modules?.FindCulprit(e.Exception);
            if (culprit is { IsRunning: true } && _modules != null)
                _modules.Fail(culprit, "eccezione non gestita", e.Exception);
            else
                Log.Error("Eccezione non gestita sul thread dell'interfaccia", e.Exception);
        }
        catch (Exception ex)
        {
            Log.Error("Errore nel gestore delle eccezioni", ex);
        }
    }

    private void OpenSettings()
    {
        if (_settings == null || _modules == null || _shuttingDown) return;
        try
        {
            if (_settingsWindow == null)
            {
                _settingsWindow = new SettingsWindow(_settings, _modules);
                _settingsWindow.Closed += (_, _) => _settingsWindow = null;
                _settingsWindow.Show();
            }
            if (_settingsWindow.WindowState == WindowState.Minimized) _settingsWindow.WindowState = WindowState.Normal;
            _settingsWindow.Activate();
        }
        catch (Exception ex)
        {
            Log.Error("Impossibile aprire le impostazioni", ex);
        }
    }

    private void Restart()
    {
        var exe = Environment.ProcessPath;
        Log.Info("Riavvio richiesto");
        Cleanup();
        if (exe != null)
        {
            try { Process.Start(new ProcessStartInfo(exe, "--restart") { UseShellExecute = false }); }
            catch (Exception ex) { Log.Error("Riavvio non riuscito", ex); }
        }
        Shutdown();
    }

    private void ExitApp()
    {
        Log.Info("Uscita richiesta");
        Cleanup();
        Shutdown();
    }

    private void Cleanup()
    {
        if (_shuttingDown) return;
        _shuttingDown = true;
        try { _settingsWindow?.Close(); } catch (Exception ex) { Log.Error("Chiusura impostazioni", ex); }
        try { _modules?.StopAll(); } catch (Exception ex) { Log.Error("Arresto moduli", ex); }
        try { ThemeManager.Shutdown(); } catch (Exception ex) { Log.Error("Arresto tema", ex); }
        try { _island?.Shutdown(); } catch (Exception ex) { Log.Error("Chiusura isola", ex); }
        try { _tray?.Dispose(); } catch (Exception ex) { Log.Error("Rimozione icona", ex); }
        _tray = null;
        ReleaseMutex();
    }

    private void ReleaseMutex()
    {
        if (_mutex == null) return;
        try { if (_ownsMutex) _mutex.ReleaseMutex(); } catch { /* not owned */ }
        _mutex.Dispose();
        _mutex = null;
        _ownsMutex = false;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Cleanup();
        base.OnExit(e);
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        Cleanup();
        base.OnSessionEnding(e);
    }
}
