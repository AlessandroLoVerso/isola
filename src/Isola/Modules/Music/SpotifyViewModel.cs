using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;

namespace Isola.Modules.Music;

internal enum SpotifySegment { Playlist, Queue, Search }

/// <summary>Spotify extras shown by the card (heart, "…" panel). UI thread only.</summary>
internal sealed class SpotifyViewModel : Observable
{
    public const string PremiumTip = "Serve Spotify Premium";

    private bool _isActive, _canLike, _isLiked, _isPanelOpen, _playBlocked, _queueBlocked;
    private SpotifySegment _segment = SpotifySegment.Playlist;
    private string _trackTitle = "", _message = "", _playlistStatus = "", _queueStatus = "", _searchStatus = "";

    /// <summary>Source is Spotify and an account is connected: heart and "…" are shown.</summary>
    public bool IsActive { get => _isActive; set { if (Set(ref _isActive, value)) Raise(nameof(ShowRestingHeart)); } }
    public bool CanLike { get => _canLike; set => Set(ref _canLike, value); }
    public bool IsLiked
    {
        get => _isLiked;
        set { if (Set(ref _isLiked, value)) { Raise(nameof(HeartGlyph)); Raise(nameof(HeartTip)); Raise(nameof(ShowRestingHeart)); } }
    }
    public string HeartGlyph => _isLiked ? "" : "";
    public string HeartTip => _isLiked ? "Togli dai Brani che ti piacciono" : "Aggiungi ai Brani che ti piacciono";
    public bool ShowRestingHeart => _isActive && _isLiked;

    public bool IsPanelOpen { get => _isPanelOpen; set => Set(ref _isPanelOpen, value); }
    public SpotifySegment Segment
    {
        get => _segment;
        set { if (Set(ref _segment, value)) { Raise(nameof(IsPlaylist)); Raise(nameof(IsQueue)); Raise(nameof(IsSearch)); } }
    }
    public bool IsPlaylist => _segment == SpotifySegment.Playlist;
    public bool IsQueue => _segment == SpotifySegment.Queue;
    public bool IsSearch => _segment == SpotifySegment.Search;

    /// <summary>Title of the current Spotify track as Windows reports it (panel header).</summary>
    public string TrackTitle { get => _trackTitle; set => Set(ref _trackTitle, value); }

    /// <summary>Short inline feedback ("Aggiunta a …", errors). Empty = hidden.</summary>
    public string Message { get => _message; set { if (Set(ref _message, value)) Raise(nameof(HasMessage)); } }
    public bool HasMessage => _message.Length > 0;

    public ObservableCollection<PlaylistRow> Playlists { get; } = new();
    public string PlaylistStatus { get => _playlistStatus; set { if (Set(ref _playlistStatus, value)) Raise(nameof(HasPlaylistStatus)); } }
    public bool HasPlaylistStatus => _playlistStatus.Length > 0;

    public ObservableCollection<QueueRow> Queue { get; } = new();
    public string QueueStatus { get => _queueStatus; set { if (Set(ref _queueStatus, value)) Raise(nameof(HasQueueStatus)); } }
    public bool HasQueueStatus => _queueStatus.Length > 0;

    public ObservableCollection<SearchRow> Results { get; } = new();
    public string SearchStatus { get => _searchStatus; set { if (Set(ref _searchStatus, value)) Raise(nameof(HasSearchStatus)); } }
    public bool HasSearchStatus => _searchStatus.Length > 0;

    /// <summary>403 PREMIUM_REQUIRED seen on play / add to queue: those controls get disabled.</summary>
    public bool PlayBlocked
    {
        get => _playBlocked;
        set { if (Set(ref _playBlocked, value)) { Raise(nameof(CanPlay)); Raise(nameof(PlayTip)); Raise(nameof(ShowRecents)); } }
    }
    public bool QueueBlocked
    {
        get => _queueBlocked;
        set { if (Set(ref _queueBlocked, value)) { Raise(nameof(CanEnqueue)); Raise(nameof(EnqueueTip)); } }
    }
    /// <summary>"Recenti" chips of the empty card (connected account, Premium not ruled out).</summary>
    public ObservableCollection<RecentRow> Recents { get; } = new();
    private bool _hasRecents;
    public bool HasRecents { get => _hasRecents; set { if (Set(ref _hasRecents, value)) Raise(nameof(ShowRecents)); } }
    public bool ShowRecents => _hasRecents && !_playBlocked;

    public bool CanPlay => !_playBlocked;
    public bool CanEnqueue => !_queueBlocked;
    public string PlayTip => _playBlocked ? PremiumTip : "Riproduci";
    public string EnqueueTip => _queueBlocked ? PremiumTip : "Metti in coda";

    public void ResetTrack()
    {
        CanLike = false;
        IsLiked = false;
    }

    public void ResetAll()
    {
        IsActive = false;
        ResetTrack();
        IsPanelOpen = false;
        TrackTitle = "";
        Message = "";
        Playlists.Clear();
        Queue.Clear();
        Results.Clear();
        Recents.Clear();
        HasRecents = false;
        PlaylistStatus = QueueStatus = SearchStatus = "";
        PlayBlocked = QueueBlocked = false;
    }
}

internal sealed class PlaylistRow
{
    public PlaylistRow(SpotifyPlaylist p)
    {
        Playlist = p;
        CountText = p.Count == 1 ? "1 brano" : $"{p.Count} brani";
    }
    public SpotifyPlaylist Playlist { get; }
    public string Name => Playlist.Name.Length > 0 ? Playlist.Name : "Senza nome";
    public string CountText { get; }
}

internal sealed class RecentRow
{
    public RecentRow(SpotifyRecent item) => Item = item;
    public SpotifyRecent Item { get; }
    public string Label => Item.Label;
}

internal sealed class QueueRow
{
    public QueueRow(int index, SpotifyQueueEntry e)
    {
        Index = index.ToString(System.Globalization.CultureInfo.InvariantCulture);
        Name = e.Name;
        Artist = e.Artist;
        Line = e.Artist.Length > 0 ? $"{e.Name} – {e.Artist}" : e.Name;
    }
    public string Index { get; }
    public string Name { get; }
    public string Artist { get; }
    public string Line { get; }
}

internal sealed class SearchRow : Observable
{
    private ImageSource? _cover;
    public SearchRow(SpotifyTrack t) => Track = t;
    public SpotifyTrack Track { get; }
    public string Name => Track.Name;
    public string Artist => Track.Artist;
    public ImageSource? Cover { get => _cover; set { if (Set(ref _cover, value)) Raise(nameof(HasCover)); } }
    public bool HasCover => _cover != null;
}

internal abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name!);
        return true;
    }

    protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
