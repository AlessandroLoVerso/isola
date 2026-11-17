using System.Windows.Threading;
using Windows.Devices.Radios;

namespace Isola.Modules.Audio;

/// <summary>Wi-Fi and Bluetooth radios (Windows.Devices.Radios). State changes are pushed by the
/// system (Radio.StateChanged) and forwarded on the UI thread.</summary>
internal sealed class RadioController : IDisposable
{
    private readonly Dispatcher _dispatcher;
    private readonly Action<string> _log;
    private Radio? _wifi;
    private Radio? _bluetooth;
    private bool _disposed;

    /// <summary>(wifi on/off or null if missing, bluetooth on/off or null if missing)</summary>
    public event Action<bool?, bool?>? Changed;

    public RadioController(Dispatcher dispatcher, Action<string> log)
    {
        _dispatcher = dispatcher;
        _log = log;
    }

    public async Task InitializeAsync()
    {
        try
        {
            var access = await Radio.RequestAccessAsync();
            if (access != RadioAccessStatus.Allowed)
            {
                _log($"accesso alle radio negato ({access})");
                Raise();
                return;
            }
            foreach (var r in await Radio.GetRadiosAsync())
            {
                if (r.Kind == RadioKind.WiFi && _wifi == null) _wifi = r;
                else if (r.Kind == RadioKind.Bluetooth && _bluetooth == null) _bluetooth = r;
            }
            if (_disposed) return;
            if (_wifi != null) _wifi.StateChanged += OnStateChanged;
            if (_bluetooth != null) _bluetooth.StateChanged += OnStateChanged;
            _log($"radio: Wi-Fi {Describe(_wifi)}, Bluetooth {Describe(_bluetooth)}");
            Raise();
        }
        catch (Exception ex)
        {
            _log("radio non disponibili: " + ex.Message);
            Raise();
        }
    }

    private static string Describe(Radio? r) => r == null ? "assente" : r.State.ToString();

    private void OnStateChanged(Radio sender, object args) => Raise();

    /// <summary>May run on a WinRT worker thread (StateChanged): reads local copies (Dispose can
    /// null the fields meanwhile) and never throws (a radio that vanished throws on State).</summary>
    private void Raise()
    {
        if (_disposed) return;
        var w = _wifi;
        var b = _bluetooth;
        bool? wifi = StateOf(w);
        bool? bt = StateOf(b);
        try { _dispatcher.BeginInvoke(() => { if (!_disposed) Changed?.Invoke(wifi, bt); }); }
        catch { /* dispatcher shut down */ }
    }

    private static bool? StateOf(Radio? r)
    {
        if (r == null) return null;
        try { return r.State == RadioState.On; }
        catch { return null; }
    }

    public async void Toggle(RadioKind kind)
    {
        var r = kind == RadioKind.WiFi ? _wifi : _bluetooth;
        if (r == null) return;
        try
        {
            var target = r.State == RadioState.On ? RadioState.Off : RadioState.On;
            var result = await r.SetStateAsync(target);
            _log($"radio {kind} -> {target}: {result}");
            Raise();
        }
        catch (Exception ex) { _log($"radio {kind}: {ex.Message}"); }
    }

    public void Dispose()
    {
        _disposed = true;
        if (_wifi != null) _wifi.StateChanged -= OnStateChanged;
        if (_bluetooth != null) _bluetooth.StateChanged -= OnStateChanged;
        _wifi = null;
        _bluetooth = null;
    }
}
