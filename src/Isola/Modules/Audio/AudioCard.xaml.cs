using System.Windows.Controls;

namespace Isola.Modules.Audio;

/// <summary>The "Controlli" tab: microphone, volume, brightness, radios and shortcuts.</summary>
internal partial class AudioCard : UserControl
{
    public AudioCard(AudioViewModel vm, AudioModule module)
    {
        InitializeComponent();
        DataContext = vm;
        MicButton.Click += (_, _) => module.ToggleMute("scheda");
        WifiChip.Click += (_, _) => module.ToggleRadio(Windows.Devices.Radios.RadioKind.WiFi);
        BluetoothChip.Click += (_, _) => module.ToggleRadio(Windows.Devices.Radios.RadioKind.Bluetooth);
        NightLightChip.Click += (_, _) => AudioModule.OpenUri("ms-settings:nightlight");
        QuietChip.Click += (_, _) => AudioModule.OpenUri("ms-settings:quiethours");
        ClipChip.Click += (_, _) => AudioModule.OpenUri("ms-screenclip:");
    }
}
