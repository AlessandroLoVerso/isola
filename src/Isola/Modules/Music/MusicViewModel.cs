using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;

namespace Isola.Modules.Music;

/// <summary>State shown by the card and by the resting faces. Only touched on the UI thread.</summary>
internal sealed class MusicViewModel : INotifyPropertyChanged
{
    public static readonly Color DefaultAccent = Color.FromRgb(0x0A, 0x84, 0xFF);

    private bool _hasSession;
    private bool _isPlaying;
    private string _title = "";
    private string _artist = "";
    private ImageSource? _cover;
    private Brush? _coverBrush;
    private Color _accent = DefaultAccent;
    private Brush _accentBrush = Freeze(new SolidColorBrush(DefaultAccent));
    private Brush _accentSoftBrush = Freeze(new SolidColorBrush(Color.FromArgb(0x40, DefaultAccent.R, DefaultAccent.G, DefaultAccent.B)));
    private bool _hasTimeline;
    private bool _isLive;
    private double _progress;
    private string _elapsed = "0:00";
    private string _total = "0:00";
    private bool _canPrev, _canNext, _canPlayPause, _canSeek;
    private bool _hasLyrics;
    private string _lyricCurrent = "";
    private string _lyricNext = "";

    /// <summary>Spotify extras (heart, panel); inactive unless Spotify plays and is connected.</summary>
    public SpotifyViewModel Spotify { get; } = new();

    public bool HasSession { get => _hasSession; set { if (Set(ref _hasSession, value)) Raise(nameof(NoSession)); } }
    public bool NoSession => !_hasSession;

    public bool IsPlaying
    {
        get => _isPlaying;
        set { if (Set(ref _isPlaying, value)) { Raise(nameof(IsPaused)); Raise(nameof(PlayGlyph)); Raise(nameof(PlayTip)); } }
    }
    public bool IsPaused => _hasSession && !_isPlaying;
    public string PlayGlyph => _isPlaying ? "\uF8AE" : "\uF5B0";
    public string PlayTip => _isPlaying ? "Pausa" : "Riproduci";

    public string Title { get => _title; set => Set(ref _title, value); }
    public string Artist { get => _artist; set => Set(ref _artist, value); }

    public ImageSource? Cover
    {
        get => _cover;
        set
        {
            if (!Set(ref _cover, value)) return;
            CoverBrush = value == null ? null : Freeze(new ImageBrush(value) { Stretch = Stretch.UniformToFill });
            Raise(nameof(HasCover));
        }
    }
    public bool HasCover => _cover != null;
    public Brush? CoverBrush { get => _coverBrush; private set => Set(ref _coverBrush, value); }

    public Color Accent
    {
        get => _accent;
        set
        {
            if (!Set(ref _accent, value)) return;
            AccentBrush = Freeze(new SolidColorBrush(value));
            AccentSoftBrush = Freeze(new SolidColorBrush(Color.FromArgb(0x40, value.R, value.G, value.B)));
        }
    }
    public Brush AccentBrush { get => _accentBrush; private set => Set(ref _accentBrush, value); }
    public Brush AccentSoftBrush { get => _accentSoftBrush; private set => Set(ref _accentSoftBrush, value); }

    public bool HasTimeline { get => _hasTimeline; set => Set(ref _hasTimeline, value); }
    public bool IsLive { get => _isLive; set => Set(ref _isLive, value); }
    public double Progress { get => _progress; set => Set(ref _progress, value); }
    public string Elapsed { get => _elapsed; set => Set(ref _elapsed, value); }
    public string Total { get => _total; set => Set(ref _total, value); }

    public bool CanPrev { get => _canPrev; set => Set(ref _canPrev, value); }
    public bool CanNext { get => _canNext; set => Set(ref _canNext, value); }
    public bool CanPlayPause { get => _canPlayPause; set => Set(ref _canPlayPause, value); }
    public bool CanSeek { get => _canSeek; set => Set(ref _canSeek, value); }

    public bool HasLyrics { get => _hasLyrics; set { if (Set(ref _hasLyrics, value)) Raise(nameof(NoLyrics)); } }
    public bool NoLyrics => !_hasLyrics;
    public string LyricCurrent { get => _lyricCurrent; set => Set(ref _lyricCurrent, value); }
    public string LyricNext { get => _lyricNext; set => Set(ref _lyricNext, value); }

    public void Reset()
    {
        HasSession = false; IsPlaying = false; Title = ""; Artist = ""; Cover = null; Accent = DefaultAccent;
        HasTimeline = false; IsLive = false; Progress = 0; Elapsed = "0:00"; Total = "0:00";
        CanPrev = CanNext = CanPlayPause = CanSeek = false;
        HasLyrics = false; LyricCurrent = ""; LyricNext = "";
        Raise(nameof(IsPaused));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name!);
        if (name == nameof(HasSession)) Raise(nameof(IsPaused));
        return true;
    }

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private static T Freeze<T>(T f) where T : Freezable { f.Freeze(); return f; }
}
