using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Isola.Modules.Music;

/// <summary>The "Musica" tab: cover, texts, transport buttons and a draggable progress bar.</summary>
internal partial class MusicCard : UserControl
{
    private readonly MusicModule _module;
    private readonly MusicViewModel _vm;
    private bool _dragging;
    private SpotifyPanel? _panel;

    public MusicCard(MusicModule module, MusicViewModel vm)
    {
        _module = module;
        _vm = vm;
        InitializeComponent();
        DataContext = vm;

        PrevButton.Click += (_, _) => _module.Previous();
        NextButton.Click += (_, _) => _module.Next();
        PlayButton.Click += (_, _) => _module.PlayPause();
        HeartButton.Click += (_, _) => _module.SpotifyToggleLike();
        MoreButton.Click += (_, _) => _module.SpotifyOpenPanel();
        SpotifyButton.Click += (_, _) => _module.OpenSpotify();
        RecentsList.AddHandler(System.Windows.Controls.Primitives.ButtonBase.ClickEvent, new RoutedEventHandler((_, e) =>
        {
            if (e.OriginalSource is FrameworkElement { DataContext: RecentRow row }) _module.PlayRecent(row);
        }));
        vm.Spotify.PropertyChanged += OnSpotifyChanged;
        // A closed card reopens on the player, not on the panel.
        IsVisibleChanged += (_, _) => { if (!IsVisible && vm.Spotify.IsPanelOpen) _module.SpotifyClosePanel(); };

        vm.PropertyChanged += OnVmChanged;
        SeekArea.SizeChanged += (_, _) => LayoutFill();
        SeekArea.MouseEnter += (_, _) => UpdateThumb();
        SeekArea.MouseLeave += (_, _) => UpdateThumb();
        SeekArea.MouseLeftButtonDown += OnSeekDown;
        SeekArea.MouseMove += OnSeekMove;
        SeekArea.MouseLeftButtonUp += OnSeekUp;
        SeekArea.LostMouseCapture += (_, _) => { if (_dragging) { _dragging = false; _module.CancelSeek(); UpdateThumb(); } };
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MusicViewModel.Progress)) LayoutFill();
        else if (e.PropertyName == nameof(MusicViewModel.CanSeek)) UpdateThumb();
    }

    private void OnSpotifyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(SpotifyViewModel.IsPanelOpen)) return;
        bool open = _vm.Spotify.IsPanelOpen;
        if (open && _panel == null)
        {
            _panel = new SpotifyPanel(_module, _vm.Spotify);
            PanelHost.Child = _panel;
        }
        if (open) _panel!.SyncSegment();
        PanelHost.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        PlayerHost.Visibility = open ? Visibility.Collapsed : Visibility.Visible;
    }

    private void LayoutFill()
    {
        double w = SeekArea.ActualWidth;
        double x = Math.Clamp(_vm.Progress, 0, 1) * w;
        Fill.Width = Math.Max(x, 4);
        Thumb.Margin = new Thickness(Math.Clamp(x - Thumb.Width / 2, -Thumb.Width / 2, w - Thumb.Width / 2), 0, 0, 0);
    }

    private void UpdateThumb()
    {
        Thumb.Opacity = _vm.CanSeek && (_dragging || SeekArea.IsMouseOver) ? 1 : 0;
        SeekArea.Cursor = _vm.CanSeek ? Cursors.Hand : Cursors.Arrow;
    }

    private double FractionAt(MouseEventArgs e)
    {
        double w = SeekArea.ActualWidth;
        return w <= 0 ? 0 : Math.Clamp(e.GetPosition(SeekArea).X / w, 0, 1);
    }

    private void OnSeekDown(object sender, MouseButtonEventArgs e)
    {
        if (!_vm.CanSeek) return;
        _dragging = true;
        SeekArea.CaptureMouse();
        _module.PreviewSeek(FractionAt(e));
        UpdateThumb();
        e.Handled = true;
    }

    private void OnSeekMove(object sender, MouseEventArgs e)
    {
        if (_dragging) _module.PreviewSeek(FractionAt(e));
    }

    private void OnSeekUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        double f = FractionAt(e);
        _dragging = false;
        SeekArea.ReleaseMouseCapture();
        _module.CommitSeek(f);
        UpdateThumb();
        e.Handled = true;
    }
}
