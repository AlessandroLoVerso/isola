using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Isola.Modules.Audio;

internal enum FaceKind { MicOn, Muted, Call, Volume }

/// <summary>State shared by the card and every resting face (pill and peek). UI thread only.</summary>
internal sealed class AudioViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised when the user moves a slider (not when the system value is reflected).</summary>
    public Action<double>? VolumeRequested;
    public Action<double>? BrightnessRequested;

    // ---- Microphone ----
    private bool _muted;
    public bool Muted
    {
        get => _muted;
        set
        {
            if (!Set(ref _muted, value)) return;
            Raise(nameof(MicLabel));
            Raise(nameof(MutedFaceText));
        }
    }
    public string MicLabel => _muted ? "Muto" : "Microfono attivo";

    private string _hotkeyHint = "Ctrl+Alt+M";
    public string HotkeyHint { get => _hotkeyHint; set => Set(ref _hotkeyHint, value); }

    // ---- Call ----
    private bool _inCall;
    public bool InCall
    {
        get => _inCall;
        set { if (Set(ref _inCall, value)) Raise(nameof(MutedFaceText)); }
    }

    private string _callTime = "00:00";
    public string CallTime
    {
        get => _callTime;
        set { if (Set(ref _callTime, value)) Raise(nameof(MutedFaceText)); }
    }

    private string _callApp = "";
    public string CallApp { get => _callApp; set => Set(ref _callApp, value); }

    public string MutedFaceText => _inCall ? $"Muto · {_callTime}" : "Muto";

    // ---- Face ----
    private FaceKind _face = FaceKind.MicOn;
    public FaceKind Face
    {
        get => _face;
        set
        {
            if (!Set(ref _face, value)) return;
            Raise(nameof(IsMutedFace));
            Raise(nameof(IsCallFace));
            Raise(nameof(IsVolumeFace));
            Raise(nameof(IsMicOnFace));
        }
    }
    public bool IsMutedFace => _face == FaceKind.Muted;
    public bool IsCallFace => _face == FaceKind.Call;
    public bool IsVolumeFace => _face == FaceKind.Volume;
    public bool IsMicOnFace => _face == FaceKind.MicOn;

    // ---- Output volume ----
    private double _volume;
    /// <summary>0..100. Two-way bound to the slider.</summary>
    public double Volume
    {
        get => _volume;
        set
        {
            value = Math.Clamp(Math.Round(value), 0, 100);
            if (!Set(ref _volume, value)) return;
            RaiseVolumeDerived();
            VolumeRequested?.Invoke(value);
        }
    }

    private bool _outputMuted;
    public bool OutputMuted
    {
        get => _outputMuted;
        set { if (Set(ref _outputMuted, value)) RaiseVolumeDerived(); }
    }

    private bool _hasOutput = true;
    public bool HasOutput { get => _hasOutput; set => Set(ref _hasOutput, value); }

    public string VolumeText => _outputMuted ? "0" : ((int)_volume).ToString();
    public double VolumeFraction => _outputMuted ? 0 : _volume / 100.0;
    public string VolumeGlyph => _outputMuted || _volume == 0 ? ""
        : _volume < 34 ? "" : _volume < 67 ? "" : "";

    /// <summary>Reflects a value coming from the system without echoing it back.</summary>
    public void SetVolumeFromSystem(double value, bool muted)
    {
        value = Math.Clamp(Math.Round(value), 0, 100);
        bool changed = _volume != value || _outputMuted != muted;
        _volume = value;
        _outputMuted = muted;
        if (!changed) return;
        Raise(nameof(Volume));
        Raise(nameof(OutputMuted));
        RaiseVolumeDerived();
    }

    private void RaiseVolumeDerived()
    {
        Raise(nameof(VolumeText));
        Raise(nameof(VolumeFraction));
        Raise(nameof(VolumeGlyph));
    }

    // ---- Brightness ----
    private bool _brightnessAvailable;
    public bool BrightnessAvailable { get => _brightnessAvailable; set => Set(ref _brightnessAvailable, value); }

    private double _brightness;
    public double Brightness
    {
        get => _brightness;
        set
        {
            value = Math.Clamp(Math.Round(value), 0, 100);
            if (!Set(ref _brightness, value)) return;
            Raise(nameof(BrightnessText));
            BrightnessRequested?.Invoke(value);
        }
    }
    public string BrightnessText => ((int)_brightness).ToString();

    public void SetBrightnessFromSystem(double value)
    {
        value = Math.Clamp(Math.Round(value), 0, 100);
        if (_brightness == value) return;
        _brightness = value;
        Raise(nameof(Brightness));
        Raise(nameof(BrightnessText));
    }

    // ---- Radios ----
    private bool _hasWifi;
    public bool HasWifi { get => _hasWifi; set { if (Set(ref _hasWifi, value)) Raise(nameof(HasRadios)); } }
    private bool _wifiOn;
    public bool WifiOn { get => _wifiOn; set { if (Set(ref _wifiOn, value)) Raise(nameof(WifiState)); } }
    public string WifiState => _wifiOn ? "Attivo" : "Spento";

    private bool _hasBluetooth;
    public bool HasBluetooth { get => _hasBluetooth; set { if (Set(ref _hasBluetooth, value)) Raise(nameof(HasRadios)); } }
    private bool _bluetoothOn;
    public bool BluetoothOn { get => _bluetoothOn; set { if (Set(ref _bluetoothOn, value)) Raise(nameof(BluetoothState)); } }
    public string BluetoothState => _bluetoothOn ? "Attivo" : "Spento";

    public bool HasRadios => _hasWifi || _hasBluetooth;

    // ---- Plumbing ----
    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name!);
        return true;
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
