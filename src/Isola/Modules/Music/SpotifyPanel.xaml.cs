using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Isola.Modules.Music;

/// <summary>The compact Spotify panel inside the music card: Playlist · Coda · Cerca.</summary>
internal partial class SpotifyPanel : UserControl
{
    private readonly MusicModule _module;
    private readonly SpotifyViewModel _vm;
    private readonly DispatcherTimer _debounce;
    private bool _syncing;

    public SpotifyPanel(MusicModule module, SpotifyViewModel vm)
    {
        _module = module;
        _vm = vm;
        InitializeComponent();
        DataContext = vm;

        _debounce = new DispatcherTimer(DispatcherPriority.Background, Dispatcher) { Interval = TimeSpan.FromMilliseconds(450) };
        _debounce.Tick += (_, _) => { _debounce.Stop(); _module.SpotifySearch(SearchBox.Text); };

        BackButton.Click += (_, _) => _module.SpotifyClosePanel();
        SegPlaylist.Checked += (_, _) => Select(SpotifySegment.Playlist);
        SegQueue.Checked += (_, _) => Select(SpotifySegment.Queue);
        SegSearch.Checked += (_, _) => Select(SpotifySegment.Search);

        WireInput(FilterBox, FilterBorder, FilterHint, FilterClear, () => _module.SpotifyFilterPlaylists(FilterBox.Text));
        WireInput(SearchBox, SearchBorder, SearchHint, SearchClear, () => { _debounce.Stop(); _debounce.Start(); });
        SearchBox.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            _debounce.Stop();
            _module.SpotifySearch(SearchBox.Text);
        };
        IsVisibleChanged += (_, _) => { if (!IsVisible) _debounce.Stop(); };
        vm.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(SpotifyViewModel.Segment)) SyncSegment(); };
    }

    /// <summary>Brings the segment chips in line with the view model (panel just opened).</summary>
    public void SyncSegment()
    {
        _syncing = true;
        SegPlaylist.IsChecked = _vm.Segment == SpotifySegment.Playlist;
        SegQueue.IsChecked = _vm.Segment == SpotifySegment.Queue;
        SegSearch.IsChecked = _vm.Segment == SpotifySegment.Search;
        _syncing = false;
    }

    private void Select(SpotifySegment s)
    {
        if (_syncing) return;
        _module.SpotifySelectSegment(s);
    }

    private void WireInput(TextBox box, Border border, TextBlock hint, Button clear, Action changed)
    {
        box.PreviewMouseLeftButtonDown += (_, _) => _module.RequestKeyboardFocus();
        box.GotKeyboardFocus += (_, _) => { _module.RequestKeyboardFocus(); border.SetResourceReference(Border.BorderBrushProperty, "Isola.Brush.Accent"); };
        box.LostKeyboardFocus += (_, _) => border.BorderBrush = Brushes.Transparent;
        box.TextChanged += (_, _) =>
        {
            bool empty = box.Text.Length == 0;
            hint.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
            clear.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
            changed();
        };
        clear.Click += (_, _) => box.Text = "";
    }

    private void Playlist_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is PlaylistRow row) _module.SpotifyAddToPlaylist(row);
    }

    private void Result_Click(object sender, RoutedEventArgs e)
    {
        // Clicks of the inner buttons bubble up here too: they mark themselves handled.
        if ((sender as FrameworkElement)?.DataContext is SearchRow row) _module.SpotifyPlay(row);
    }

    private void Play_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.DataContext is SearchRow row) _module.SpotifyPlay(row);
    }

    private void Enqueue_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.DataContext is SearchRow row) _module.SpotifyEnqueue(row);
    }
}
