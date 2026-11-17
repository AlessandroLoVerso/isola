using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Isola.Core;
using Windows.Devices.Radios;

namespace Isola.Modules.Audio;

/// <summary>"Controlli": global microphone mute (Ctrl+Alt+M or Ctrl+Shift+Alt+M), call timer, volume pop-up and the
/// quick controls card (volume, brightness, Wi-Fi, Bluetooth, shortcuts). Everything is event
/// driven; the only timers run during a call (1 Hz) or for the volume pop-up.</summary>
public sealed class AudioModule : IIslandModule, IRestingFaceProvider
{
    private const int HotkeyId = 0x4155; // "AU"
    private static readonly TimeSpan MuteAttention = TimeSpan.FromSeconds(1.5);
    private static readonly TimeSpan VolumeAttention = TimeSpan.FromSeconds(1.2);

    private enum HotkeyStatus { Off, Active, Taken, Error }

    private IIslandHost? _host;
    private AudioSettings _settings = new();
    private AudioViewModel _vm = new();
    private AudioEndpoints? _endpoints;
    private CallWatcher? _calls;
    private BrightnessController? _brightness;
    private RadioController? _radios;
    private DispatcherTimer? _callTimer;
    private DispatcherTimer? _flashTimer;
    private FrameworkElement? _card;
    private HotkeyStatus _hotkey = HotkeyStatus.Off;
    private int _hotkeyError;
    private int _activeVariant;
    private bool _muted;
    private DateTime? _callStartUtc;
    private bool _volumeFlash;
    private DateTime _peekEnd;
    private int _generation;

    public string Id => "audio";
    public string Title => "Controlli";
    public string Glyph => "";
    public int Order => 40;
    public bool EnabledByDefault => true;

    public int RestingPriority => _host == null ? 0
        : _volumeFlash ? 80
        : _muted ? 70
        : _callStartUtc != null ? 60
        : 0;

    // =====================================================================================
    // Lifecycle
    // =====================================================================================

    public void Start(IIslandHost host)
    {
        _host = host;
        int gen = ++_generation;
        _settings = host.LoadSettings<AudioSettings>(Id);
        _vm = new AudioViewModel();
        _vm.VolumeRequested = v => _endpoints?.SetVolume((float)(v / 100.0));
        _vm.BrightnessRequested = v => _brightness?.Set((int)v);

        // Core Audio
        try
        {
            _endpoints = new AudioEndpoints(host.Dispatcher, Log);
            _endpoints.VolumeChanged += OnVolumeChanged;
            _endpoints.CaptureMuteChanged += OnCaptureMuteChanged;
            _endpoints.CaptureDeviceArrived += OnCaptureDeviceArrived;
            _muted = _endpoints.DefaultCaptureMuted ?? false;
            _vm.HasOutput = _endpoints.HasRender;
            _vm.SetVolumeFromSystem(_endpoints.Volume * 100, _endpoints.RenderMuted);
        }
        catch (Exception ex)
        {
            Log("Core Audio non disponibile: " + ex.Message);
            _endpoints?.Dispose();
            _endpoints = null;
            _vm.HasOutput = false;
        }
        _vm.Muted = _muted;

        // Hotkey
        host.AddMessageHook(OnMessage);
        if (_settings.HotkeyEnabled) RegisterHotkey();
        else SetHotkeyStatus(HotkeyStatus.Off);

        // Calls
        _callTimer = new DispatcherTimer(DispatcherPriority.Background, host.Dispatcher) { Interval = TimeSpan.FromSeconds(1) };
        _callTimer.Tick += (_, _) => UpdateCallTime();
        _flashTimer = new DispatcherTimer(DispatcherPriority.Normal, host.Dispatcher);
        _flashTimer.Tick += (_, _) => OnFlashTimer();
        _calls = new CallWatcher(
            (start, app) => host.Dispatcher.BeginInvoke(() => { if (gen == _generation && _host != null) OnCall(start, app); }),
            Log);
        _calls.Start();

        // Brightness (slow: off the UI thread)
        var brightness = _brightness = new BrightnessController(Log);
        Task.Run(() =>
        {
            int? level = brightness.Initialize();
            host.Dispatcher.BeginInvoke(() =>
            {
                if (gen != _generation || _host == null) return;
                _vm.BrightnessAvailable = brightness.Available && level != null;
                if (level != null) _vm.SetBrightnessFromSystem(level.Value);
            });
        });

        // Radios
        _radios = new RadioController(host.Dispatcher, Log);
        _radios.Changed += (wifi, bt) =>
        {
            _vm.HasWifi = wifi != null;
            _vm.WifiOn = wifi == true;
            _vm.HasBluetooth = bt != null;
            _vm.BluetoothOn = bt == true;
        };
        _ = _radios.InitializeAsync();

        UpdateFace();
        host.RefreshRestingFace();
    }

    public void Stop()
    {
        _generation++;
        UnregisterHotkey();
        _callTimer?.Stop();
        _callTimer = null;
        _flashTimer?.Stop();
        _flashTimer = null;
        _calls?.Dispose();
        _calls = null;
        _endpoints?.Dispose();
        _endpoints = null;
        _brightness?.Dispose();
        _brightness = null;
        _radios?.Dispose();
        _radios = null;
        _card = null;
        _volumeFlash = false;
        _callStartUtc = null;
        _host = null;
    }

    // =====================================================================================
    // Microphone mute
    // =====================================================================================

    private bool OnMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg != NativeAudio.WM_HOTKEY || wParam.ToInt64() != HotkeyId) return false;
        ToggleMute(HotkeyName);
        return true;
    }

    internal void ToggleMute(string source) => SetMuted(!_muted, source);

    private void SetMuted(bool muted, string source)
    {
        if (_host == null) return;
        _muted = muted;
        if (_endpoints != null)
        {
            var (ok, total, detail) = _endpoints.SetAllCaptureMuted(muted);
            Log($"microfoni {(muted ? "MUTI" : "ATTIVI")} ({source}): {ok}/{total} applicati [{detail}]");
        }
        else Log($"microfoni {(muted ? "muti" : "attivi")} ({source}): nessun dispositivo audio");
        _vm.Muted = muted;
        EndFlash(refresh: false);
        UpdateFace();
        _host.RefreshRestingFace();
        _host.Attention(Id, MuteAttention);
    }

    private void OnCaptureMuteChanged(bool muted)
    {
        if (_host == null || muted == _muted) return;
        // Changed outside Isola (Windows settings, a headset button...): follow it.
        Log($"muto del microfono predefinito cambiato da fuori: {(muted ? "muto" : "attivo")}");
        _muted = muted;
        _vm.Muted = muted;
        UpdateFace();
        _host.RefreshRestingFace();
        if (!IsCardVisible) _host.Attention(Id, MuteAttention);
    }

    private void OnCaptureDeviceArrived(string deviceId)
    {
        // A new or newly default microphone takes the current state (only when muted:
        // never unmute a device the user muted on purpose).
        if (_muted) _endpoints?.SetCaptureMuted(deviceId, true);
    }

    private void RegisterHotkey()
    {
        if (_host == null || _hotkey == HotkeyStatus.Active) return;
        // Automatico (-1): Ctrl+Alt+M, and Ctrl+Shift+Alt+M when another app already owns it.
        int[] variants = _settings.HotkeyVariant switch { 0 => new[] { 0 }, 1 => new[] { 1 }, _ => new[] { 0, 1 } };
        bool taken = false;
        foreach (var v in variants)
        {
            if (NativeAudio.RegisterHotKey(_host.Hwnd, HotkeyId, ModifiersFor(v), NativeAudio.VK_M))
            {
                _activeVariant = v;
                Log(v != variants[0]
                    ? $"{NameFor(variants[0])} è già usata da un'altra app: uso {NameFor(v)}"
                    : $"scorciatoia {NameFor(v)} registrata");
                SetHotkeyStatus(HotkeyStatus.Active);
                return;
            }
            _hotkeyError = Marshal.GetLastWin32Error();
            taken = _hotkeyError == 1409; // ERROR_HOTKEY_ALREADY_REGISTERED
            if (!taken) break;
        }
        _activeVariant = variants[^1];
        Log(taken
            ? $"{string.Join(" e ", variants.Select(NameFor))}: già usate da altre app, scorciatoia non disponibile"
            : $"RegisterHotKey fallita (errore {_hotkeyError})");
        SetHotkeyStatus(taken ? HotkeyStatus.Taken : HotkeyStatus.Error);
    }

    private static uint ModifiersFor(int variant) => NativeAudio.MOD_CONTROL | NativeAudio.MOD_ALT | NativeAudio.MOD_NOREPEAT
        | (variant == 1 ? NativeAudio.MOD_SHIFT : 0);

    private static string NameFor(int variant) => variant == 1 ? "Ctrl+Maiusc+Alt+M" : "Ctrl+Alt+M";

    /// <summary>The combination in use (or the last one tried).</summary>
    private string HotkeyName => NameFor(_activeVariant);

    private void UnregisterHotkey()
    {
        if (_hotkey == HotkeyStatus.Active && _host != null)
            NativeAudio.UnregisterHotKey(_host.Hwnd, HotkeyId);
        SetHotkeyStatus(HotkeyStatus.Off);
    }

    private void SetHotkeyStatus(HotkeyStatus s)
    {
        _hotkey = s;
        _vm.HotkeyHint = s switch
        {
            HotkeyStatus.Active => HotkeyName,
            HotkeyStatus.Taken => "Scorciatoia occupata",
            HotkeyStatus.Error => "Scorciatoia non attiva",
            _ => "Tocca per il muto",
        };
    }

    private string HotkeyStatusText => _hotkey switch
    {
        HotkeyStatus.Active => $"Attiva: premi {HotkeyName} in qualsiasi app.",
        HotkeyStatus.Taken => _settings.HotkeyVariant is 0 or 1
            ? $"{HotkeyName} è già usata da un'altra app. Scegli un'altra combinazione o chiudi quell'app e riattiva l'interruttore."
            : "Ctrl+Alt+M e Ctrl+Maiusc+Alt+M sono già usate da altre app. Chiudi quell'app e riattiva l'interruttore.",
        HotkeyStatus.Error => $"Non è stato possibile registrarla (errore {_hotkeyError}).",
        _ => "Spenta.",
    };

    // =====================================================================================
    // Calls
    // =====================================================================================

    private void OnCall(DateTime? startUtc, string? app)
    {
        bool was = _callStartUtc != null;
        _callStartUtc = startUtc;
        _vm.InCall = startUtc != null;
        _vm.CallApp = app ?? "";
        if (startUtc != null)
        {
            if (!was) Log("microfono in uso da un'app: timer della chiamata avviato");
            UpdateCallTime();
            _callTimer?.Start();
        }
        else
        {
            if (was) Log("microfono non più in uso: timer della chiamata fermo");
            _callTimer?.Stop();
        }
        UpdateFace();
        _host?.RefreshRestingFace();
    }

    private void UpdateCallTime()
    {
        if (_callStartUtc is not { } start) return;
        var t = DateTime.UtcNow - start;
        if (t < TimeSpan.Zero) t = TimeSpan.Zero;
        _vm.CallTime = t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"mm\:ss");
    }

    // =====================================================================================
    // Volume pop-up
    // =====================================================================================

    private void OnVolumeChanged(float level, bool muted, bool own)
    {
        if (_host == null) return;
        _vm.HasOutput = _endpoints?.HasRender ?? false;
        _vm.SetVolumeFromSystem(level * 100, muted);
        if (own || !_settings.ShowVolumePopup || IsCardVisible) return;
        Flash();
    }

    private void Flash()
    {
        if (_host == null || _flashTimer == null) return;
        var now = DateTime.UtcNow;
        bool was = _volumeFlash;
        _volumeFlash = true;
        UpdateFace();
        if (!was)
        {
            _host.RefreshRestingFace();
            _host.Attention(Id, VolumeAttention);
            _peekEnd = now + VolumeAttention;
        }
        else if (_peekEnd - now < TimeSpan.FromMilliseconds(500))
        {
            // Still changing near the end of the peek: extend it (a fresh Attention restarts it).
            _host.Attention(Id, VolumeAttention);
            _peekEnd = now + VolumeAttention;
        }
        _flashTimer.Stop();
        _flashTimer.Interval = _peekEnd - now + TimeSpan.FromMilliseconds(150);
        _flashTimer.Start();
    }

    private void OnFlashTimer() => EndFlash(refresh: true);

    private void EndFlash(bool refresh)
    {
        _flashTimer?.Stop();
        if (!_volumeFlash) return;
        _volumeFlash = false;
        UpdateFace();
        if (refresh) _host?.RefreshRestingFace();
    }

    private void UpdateFace()
    {
        _vm.Face = _volumeFlash ? FaceKind.Volume
            : _muted ? FaceKind.Muted
            : _callStartUtc != null ? FaceKind.Call
            : FaceKind.MicOn;
    }

    // =====================================================================================
    // UI
    // =====================================================================================

    private bool IsCardVisible => _card is { IsVisible: true };

    public FrameworkElement? CreateCard()
    {
        var card = new AudioCard(_vm, this);
        card.IsVisibleChanged += (_, e) =>
        {
            if (e.NewValue is not true || _host == null) return;
            EndFlash(refresh: true);
            // Pick up changes made while the card was closed.
            if (_endpoints != null) _vm.SetVolumeFromSystem(_endpoints.Volume * 100, _endpoints.RenderMuted);
            var b = _brightness;
            int gen = _generation;
            if (b is { Available: true })
                Task.Run(() =>
                {
                    int? level = b.Read();
                    _host?.Dispatcher.BeginInvoke(() =>
                    {
                        if (gen == _generation && level != null) _vm.SetBrightnessFromSystem(level.Value);
                    });
                });
        };
        _card = card;
        return card;
    }

    public FrameworkElement CreateRestingFace() => new AudioFace(_vm);

    internal void ToggleRadio(RadioKind kind) => _radios?.Toggle(kind);

    internal static void OpenUri(string uri)
    {
        try { Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true }); }
        catch (Exception ex) { Core.Log.Info($"[audio] impossibile aprire {uri}: {ex.Message}"); }
    }

    public FrameworkElement? CreateSettingsPage()
    {
        var root = new StackPanel();

        // Hotkey
        var hotkey = Toggle("Scorciatoia globale per il muto del microfono", _settings.HotkeyEnabled);
        var status = Note("");
        void ShowStatus()
        {
            status.Text = HotkeyStatusText;
            if (_hotkey is HotkeyStatus.Taken or HotkeyStatus.Error)
                status.Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0xFF, 0x6B, 0x61));
            else status.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");
        }
        ShowStatus();
        void Reregister()
        {
            UnregisterHotkey();
            if (_settings.HotkeyEnabled) RegisterHotkey();
            ShowStatus();
        }
        void HotkeyChanged(object s, RoutedEventArgs e)
        {
            _settings.HotkeyEnabled = hotkey.IsChecked == true;
            _host?.SaveSettings(Id, _settings);
            Reregister();
        }
        hotkey.Checked += HotkeyChanged;
        hotkey.Unchecked += HotkeyChanged;

        var chords = new StackPanel { Orientation = Orientation.Horizontal };
        string group = "audio-hotkey-" + Guid.NewGuid().ToString("N");
        foreach (var (label, variant) in new[] { ("Automatica", -1), ("Ctrl+Alt+M", 0), ("Ctrl+Maiusc+Alt+M", 1) })
        {
            var rb = new RadioButton { Content = label, GroupName = group, IsChecked = Normalize(_settings.HotkeyVariant) == variant };
            rb.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.Segmented");
            int v = variant;
            rb.Checked += (_, _) =>
            {
                if (Normalize(_settings.HotkeyVariant) == v) return;
                _settings.HotkeyVariant = v;
                _host?.SaveSettings(Id, _settings);
                Reregister();
            };
            chords.Children.Add(rb);
        }
        var chordHost = new Border { Child = chords, Margin = new Thickness(0, 10, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        chordHost.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SegmentedHost");

        root.Children.Add(Card(hotkey, chordHost, status,
            Note("«Automatica» usa Ctrl+Alt+M e, se un'altra app l'ha già presa, Ctrl+Maiusc+Alt+M. " +
                 "Agisce sul dispositivo, quindi vale per tutte le app insieme (Discord, Teams, Meet, giochi). " +
                 "Anche i microfoni collegati dopo prendono lo stato muto.")));

        // Volume pop-up
        var popup = Toggle("Mostra popup volume", _settings.ShowVolumePopup);
        void PopupChanged(object s, RoutedEventArgs e)
        {
            _settings.ShowVolumePopup = popup.IsChecked == true;
            _host?.SaveSettings(Id, _settings);
        }
        popup.Checked += PopupChanged;
        popup.Unchecked += PopupChanged;
        root.Children.Add(Card(popup, Note("Quando cambi il volume, l'isola mostra il livello per un attimo.")));

        return root;
    }

    private static int Normalize(int variant) => variant is 0 or 1 ? variant : -1;

    private static CheckBox Toggle(string text, bool value)
    {
        var t = new CheckBox { IsChecked = value, Content = text };
        t.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.ToggleSwitch");
        return t;
    }

    private static TextBlock Note(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");
        return t;
    }

    private static Border Card(params UIElement[] children)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 14, 0, 14) };
        foreach (var c in children) stack.Children.Add(c);
        var card = new Border { Child = stack };
        card.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SettingCard");
        return card;
    }

    private void Log(string message) => _host?.Log(Id, message);
}

public sealed class AudioSettings
{
    public bool HotkeyEnabled { get; set; } = true;
    /// <summary>-1 = automatic (Ctrl+Alt+M, else Ctrl+Shift+Alt+M when another app owns it),
    /// 0 = only Ctrl+Alt+M, 1 = only Ctrl+Shift+Alt+M.</summary>
    public int HotkeyVariant { get; set; } = -1;
    public bool ShowVolumePopup { get; set; } = true;
}
