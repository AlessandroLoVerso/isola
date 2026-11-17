using System.Runtime.InteropServices;
using System.Windows.Threading;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Isola.Modules.Audio;

/// <summary>Core Audio (NAudio) on the UI thread: mute of every active capture endpoint, the volume
/// of the default render endpoint, and device notifications. Callbacks arrive on system threads and
/// are marshalled to the dispatcher before touching anything.</summary>
internal sealed class AudioEndpoints : IDisposable
{
    /// <summary>Event context written with our own volume changes, to tell them apart.</summary>
    public static readonly Guid OwnContext = new("6b1c3f0e-2a4d-4c55-9f0e-15a0d10a0d10");

    private readonly Dispatcher _dispatcher;
    private readonly Action<string> _log;
    private readonly MMDeviceEnumerator _enumerator;
    private readonly DeviceNotifications _notifications;
    private MMDevice? _render;
    private MMDevice? _capture;
    private bool _disposed;

    /// <summary>Default render endpoint volume changed: (level 0..1, muted, changed by us).</summary>
    public event Action<float, bool, bool>? VolumeChanged;

    /// <summary>The default microphone's mute changed (from anywhere).</summary>
    public event Action<bool>? CaptureMuteChanged;

    /// <summary>A capture endpoint appeared, became active or became the default.</summary>
    public event Action<string>? CaptureDeviceArrived;

    public AudioEndpoints(Dispatcher dispatcher, Action<string> log)
    {
        _dispatcher = dispatcher;
        _log = log;
        _enumerator = new MMDeviceEnumerator();
        _notifications = new DeviceNotifications(this);
        int hr = _enumerator.RegisterEndpointNotificationCallback(_notifications);
        if (hr != 0) _log($"RegisterEndpointNotificationCallback: 0x{hr:X8}");
        AttachRender();
        AttachCapture();
    }

    // ---- Microphones -----------------------------------------------------------------------

    /// <summary>Mute of the default capture device, or null when there is no microphone.</summary>
    public bool? DefaultCaptureMuted
    {
        get
        {
            try { return _capture?.AudioEndpointVolume.Mute; }
            catch { return null; }
        }
    }

    /// <summary>Sets mute on every active capture endpoint. Returns (applied, total).</summary>
    public (int ok, int total, string detail) SetAllCaptureMuted(bool muted)
    {
        int ok = 0, total = 0;
        var detail = new List<string>();
        foreach (var d in _enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            total++;
            try
            {
                d.AudioEndpointVolume.Mute = muted;
                bool now = d.AudioEndpointVolume.Mute; // read back: this is what the log reports
                if (now == muted) ok++;
                detail.Add(now ? "muto" : "attivo");
            }
            catch (Exception ex)
            {
                detail.Add("errore " + ex.HResult.ToString("X8"));
            }
            finally { d.Dispose(); }
        }
        return (ok, total, string.Join("; ", detail));
    }

    public void SetCaptureMuted(string deviceId, bool muted)
    {
        try
        {
            using var d = _enumerator.GetDevice(deviceId);
            if (d.DataFlow != DataFlow.Capture || d.State != DeviceState.Active) return;
            if (d.AudioEndpointVolume.Mute != muted) d.AudioEndpointVolume.Mute = muted;
            _log($"stato del muto riapplicato a un microfono nuovo: {(muted ? "muto" : "attivo")}");
        }
        catch (Exception ex) { _log($"riapplicazione del muto fallita: {ex.Message}"); }
    }

    private void AttachCapture()
    {
        DetachCapture();
        try
        {
            if (!_enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Communications)) return;
            _capture = _enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            _capture.AudioEndpointVolume.OnVolumeNotification += OnCaptureNotification;
        }
        catch (Exception ex)
        {
            _log("microfono predefinito non disponibile: " + ex.Message);
            DetachCapture();
        }
    }

    private void DetachCapture()
    {
        if (_capture == null) return;
        try { _capture.AudioEndpointVolume.OnVolumeNotification -= OnCaptureNotification; } catch { }
        try { _capture.Dispose(); } catch { }
        _capture = null;
    }

    private void OnCaptureNotification(AudioVolumeNotificationData data)
    {
        bool muted = data.Muted;
        Post(() => CaptureMuteChanged?.Invoke(muted));
    }

    // ---- Output volume ---------------------------------------------------------------------

    public bool HasRender => _render != null;

    public float Volume
    {
        get
        {
            try { return _render?.AudioEndpointVolume.MasterVolumeLevelScalar ?? 0; }
            catch { return 0; }
        }
    }

    public bool RenderMuted
    {
        get
        {
            try { return _render?.AudioEndpointVolume.Mute ?? false; }
            catch { return false; }
        }
    }

    public void SetVolume(float level)
    {
        if (_render == null) return;
        try
        {
            var v = _render.AudioEndpointVolume;
            v.MasterVolumeLevelScalar = Math.Clamp(level, 0f, 1f);
            if (v.Mute && level > 0) v.Mute = false;
        }
        catch (Exception ex) { _log("impostazione del volume fallita: " + ex.Message); }
    }

    private void AttachRender()
    {
        DetachRender();
        try
        {
            if (!_enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)) return;
            _render = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            _render.AudioEndpointVolume.NotificationGuid = OwnContext;
            _render.AudioEndpointVolume.OnVolumeNotification += OnRenderNotification;
        }
        catch (Exception ex)
        {
            _log("uscita audio predefinita non disponibile: " + ex.Message);
            DetachRender();
        }
    }

    private void DetachRender()
    {
        if (_render == null) return;
        try { _render.AudioEndpointVolume.OnVolumeNotification -= OnRenderNotification; } catch { }
        try { _render.Dispose(); } catch { }
        _render = null;
    }

    private void OnRenderNotification(AudioVolumeNotificationData data)
    {
        float level = data.MasterVolume;
        bool muted = data.Muted;
        bool own = data.EventContext == OwnContext;
        Post(() => VolumeChanged?.Invoke(level, muted, own));
    }

    // ---- Device notifications --------------------------------------------------------------

    private void OnDefaultChanged(DataFlow flow, Role role, string id)
    {
        if (flow == DataFlow.Render && role == Role.Multimedia)
        {
            AttachRender();
            if (_render != null) VolumeChanged?.Invoke(Volume, RenderMuted, true);
        }
        else if (flow == DataFlow.Capture && role == Role.Communications)
        {
            AttachCapture();
            if (!string.IsNullOrEmpty(id)) CaptureDeviceArrived?.Invoke(id);
        }
    }

    private bool IsCapture(string id)
    {
        try
        {
            using var d = _enumerator.GetDevice(id);
            return d.DataFlow == DataFlow.Capture;
        }
        catch { return false; }
    }

    private void Post(Action a)
    {
        if (_disposed) return;
        _dispatcher.BeginInvoke(() =>
        {
            if (_disposed) return;
            a();
        });
    }


    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { _enumerator.UnregisterEndpointNotificationCallback(_notifications); } catch { }
        DetachRender();
        DetachCapture();
        try { _enumerator.Dispose(); } catch { }
    }

    /// <summary>IMMNotificationClient: called by the audio service on its own threads.</summary>
    [ComVisible(true)]
    private sealed class DeviceNotifications : IMMNotificationClient
    {
        private readonly AudioEndpoints _owner;
        public DeviceNotifications(AudioEndpoints owner) => _owner = owner;

        public void OnDeviceStateChanged(string deviceId, DeviceState newState)
        {
            if (newState != DeviceState.Active) return;
            _owner.Post(() => { if (_owner.IsCapture(deviceId)) _owner.CaptureDeviceArrived?.Invoke(deviceId); });
        }

        public void OnDeviceAdded(string pwstrDeviceId)
            => _owner.Post(() => { if (_owner.IsCapture(pwstrDeviceId)) _owner.CaptureDeviceArrived?.Invoke(pwstrDeviceId); });

        public void OnDeviceRemoved(string deviceId) { }

        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
            => _owner.Post(() => _owner.OnDefaultChanged(flow, role, defaultDeviceId));

        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }
}
