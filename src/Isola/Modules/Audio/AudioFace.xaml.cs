using System.Windows.Controls;

namespace Isola.Modules.Audio;

internal partial class AudioFace : Grid
{
    public AudioFace(AudioViewModel vm)
    {
        InitializeComponent();
        DataContext = vm;
    }
}
