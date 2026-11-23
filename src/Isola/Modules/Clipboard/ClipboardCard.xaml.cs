using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace Isola.Modules.Clipboard;

/// <summary>The "Appunti" tab: filter chips, search, a virtualized list, "Copiato" feedback.</summary>
internal partial class ClipboardCard : UserControl
{
    private readonly ClipboardModule _module;
    private readonly ObservableCollection<ClipEntry> _view = new();
    private readonly Dictionary<string, ClipEntry> _entries = new(); // by item id, keeps thumbnails
    private string _filter = "all";
    private string _query = "";
    private bool _dirty = true;

    public ClipboardCard(ClipboardModule module)
    {
        _module = module;
        InitializeComponent();
        List.ItemsSource = _view;
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible) return;
            if (_dirty) Rebuild();
            else foreach (var e in _view) e.RefreshTime(); // relative times, only when shown
        };
        Rebuild();
    }

    /// <summary>History changed. Rebuild now if on screen, otherwise when shown.</summary>
    public void Reload()
    {
        _dirty = true;
        if (IsVisible) Rebuild();
    }

    private void Rebuild()
    {
        _dirty = false;
        var items = _module.Items;
        var alive = new HashSet<string>();
        var list = new List<ClipEntry>();
        foreach (var item in items.OrderByDescending(i => i.Pinned).ThenByDescending(i => i.Time))
        {
            alive.Add(item.Id);
            if (!Matches(item)) continue;
            if (!_entries.TryGetValue(item.Id, out var e) || !ReferenceEquals(e.Item, item))
                _entries[item.Id] = e = new ClipEntry(item, _module.Store);
            e.Refresh();
            list.Add(e);
        }
        foreach (var dead in _entries.Keys.Where(k => !alive.Contains(k)).ToList()) _entries.Remove(dead);

        // Sync in place (move/insert/remove) so the scroll position holds.
        for (int i = 0; i < list.Count; i++)
        {
            if (i < _view.Count && ReferenceEquals(_view[i], list[i])) continue;
            int j = _view.IndexOf(list[i]);
            if (j > i) _view.Move(j, i);
            else _view.Insert(i, list[i]);
        }
        while (_view.Count > list.Count) _view.RemoveAt(_view.Count - 1);

        bool none = list.Count == 0;
        Empty.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        if (none)
        {
            if (_module.Paused && items.Count == 0)
            {
                EmptyGlyph.Text = "";
                EmptyTitle.Text = "Cronologia in pausa";
                EmptyText.Text = "Riattivala da Impostazioni › Appunti.";
            }
            else if (items.Count == 0)
            {
                EmptyGlyph.Text = "";
                EmptyTitle.Text = "Niente negli appunti";
                EmptyText.Text = "Copia qualcosa: lo ritrovi qui.";
            }
            else
            {
                EmptyGlyph.Text = "";
                EmptyTitle.Text = "Nessun risultato";
                EmptyText.Text = _query.Length > 0 ? "Prova con un'altra parola." : "Niente di questo tipo, per ora.";
            }
        }
    }

    private bool Matches(ClipItem item)
    {
        bool kind = _filter switch
        {
            "text" => item.Kind == ClipKind.Text,
            "link" => item.Kind == ClipKind.Link,
            "image" => item.Kind == ClipKind.Image,
            "files" => item.Kind == ClipKind.Files,
            _ => true,
        };
        if (!kind) return false;
        if (_query.Length == 0) return true;
        var hay = item.Kind switch
        {
            ClipKind.Files => string.Join(" ", item.Files ?? new()),
            ClipKind.Image => "immagine",
            _ => item.Text ?? "",
        };
        return hay.Contains(_query, StringComparison.CurrentCultureIgnoreCase);
    }

    // ---- Events ---------------------------------------------------------------------------

    private void Chip_Checked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: string tag })
        {
            _filter = tag;
            if (IsInitialized && List != null) Rebuild();
        }
    }

    private void Search_TextChanged(object sender, TextChangedEventArgs e)
    {
        _query = SearchBox.Text.Trim();
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        SearchClear.Visibility = SearchBox.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Rebuild();
    }

    private void Search_MouseDown(object sender, MouseButtonEventArgs e) => _module.RequestKeyboardFocus();

    private void Search_Focus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (SearchBox.IsKeyboardFocused) SearchBorder.SetResourceReference(Border.BorderBrushProperty, "Isola.Brush.Accent");
        else SearchBorder.BorderBrush = Brushes.Transparent;
    }

    private void SearchClear_Click(object sender, RoutedEventArgs e) => SearchBox.Text = "";

    private void Row_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not ClipEntry entry) return;
        if (_module.Restore(entry.Item, out var error)) ShowToast("", "Copiato");
        else ShowToast("", error ?? "Non riuscito");
    }

    private void Pin_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.DataContext is ClipEntry entry) _module.TogglePin(entry.Item);
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.DataContext is ClipEntry entry) _module.Delete(entry.Item);
    }

    private void ShowToast(string glyph, string text)
    {
        ToastGlyph.Text = glyph;
        ToastText.Text = text;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var fade = new DoubleAnimationUsingKeyFrames();
        fade.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(160)), ease));
        fade.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(1100))));
        fade.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(1350))));
        Toast.BeginAnimation(OpacityProperty, fade);
        var rise = new DoubleAnimation(6, 0, TimeSpan.FromMilliseconds(220)) { EasingFunction = ease };
        ToastY.BeginAnimation(TranslateTransform.YProperty, rise);
    }
}

/// <summary>Row view model for one history item.</summary>
internal sealed class ClipEntry : INotifyPropertyChanged
{
    private static readonly CultureInfo Italian = CultureInfo.GetCultureInfo("it-IT");
    private readonly ClipboardStore? _store;
    private ImageSource? _thumb;
    private bool _thumbLoaded;

    public ClipEntry(ClipItem item, ClipboardStore? store)
    {
        Item = item;
        _store = store;
        Refresh();
    }

    public ClipItem Item { get; }
    public string Title { get; private set; } = "";
    public string Tooltip { get; private set; } = "";
    public string When { get; private set; } = "";

    public string Glyph => Item.Kind switch
    {
        ClipKind.Link => "",
        ClipKind.Image => "",
        ClipKind.Files => Item.Files is { Count: 1 } f && Directory.Exists(f[0]) ? "" : "",
        _ => "",
    };

    public bool IsLink => Item.Kind == ClipKind.Link;

    /// <summary>"dal MacBook…" for items received from the other computer.</summary>
    public string FromLabel => Item.From == null ? "" : ClipSyncProtocol.FromLabel(Item.From);
    public Visibility FromVisibility => Item.From == null ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>Files that no longer exist (checked on refresh).</summary>
    public bool IsMissing { get; private set; }

    public ImageSource? Thumb
    {
        get
        {
            if (!_thumbLoaded)
            {
                _thumbLoaded = true;
                _thumb = LoadThumb();
            }
            return _thumb;
        }
    }

    public Visibility ThumbVisibility => Item.Kind == ClipKind.Image && Thumb != null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility PinVisibility => Item.Pinned ? Visibility.Visible : Visibility.Collapsed;
    public string PinGlyph => Item.Pinned ? "" : "";
    public string PinTip => Item.Pinned ? "Togli dai fissati" : "Fissa";

    public event PropertyChangedEventHandler? PropertyChanged;

    public void Refresh()
    {
        Title = Item.Kind switch
        {
            ClipKind.Image => $"Immagine {Item.ImageWidth} × {Item.ImageHeight}",
            ClipKind.Files => FilesTitle(Item.Files),
            ClipKind.Link => Item.Text ?? "",
            _ => OneLine(Item.Text ?? "", 220),
        };
        Tooltip = Item.Kind switch
        {
            ClipKind.Files => string.Join("\n", (Item.Files ?? new()).Take(12)) + ((Item.Files?.Count ?? 0) > 12 ? "\n…" : ""),
            ClipKind.Image => "Clic per copiare l'immagine",
            _ => Truncate(Item.Text ?? "", 600),
        };
        When = FormatWhen(Item.Time);
        IsMissing = Item.Kind == ClipKind.Files && Item.Files != null && !Item.Files.Any(f => File.Exists(f) || Directory.Exists(f));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); // all properties
    }

    public void RefreshTime()
    {
        var w = FormatWhen(Item.Time);
        if (w == When) return;
        When = w;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(When)));
    }

    private ImageSource? LoadThumb()
    {
        if (Item.Kind != ClipKind.Image || _store == null) return null;
        try
        {
            var path = _store.ThumbPath(Item);
            if (!File.Exists(path)) return null;
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.DecodePixelHeight = 56;
            bmp.UriSource = new Uri(path);
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch { return null; }
    }

    private static string FilesTitle(List<string>? files)
    {
        if (files == null || files.Count == 0) return "File";
        var first = Path.GetFileName(files[0].TrimEnd('\\', '/'));
        if (first.Length == 0) first = files[0];
        return files.Count == 1 ? first : $"{first} e altri {files.Count - 1}";
    }

    private static string OneLine(string s, int max)
    {
        var sb = new StringBuilder(Math.Min(s.Length, max + 1));
        bool space = false;
        foreach (var c in s)
        {
            if (char.IsWhiteSpace(c)) { space = sb.Length > 0; continue; }
            if (space) { sb.Append(' '); space = false; }
            sb.Append(c);
            if (sb.Length >= max) { sb.Append('…'); break; }
        }
        return sb.ToString();
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "…";

    private static string FormatWhen(DateTime t)
    {
        var now = DateTime.Now;
        var d = now - t;
        if (d < TimeSpan.FromMinutes(1)) return "ora";
        if (d < TimeSpan.FromHours(1)) return $"{(int)d.TotalMinutes} min";
        if (t.Date == now.Date) return t.ToString("HH:mm", Italian);
        if (t.Date == now.Date.AddDays(-1)) return "ieri";
        if (t.Year == now.Year) return t.ToString("d MMM", Italian).Replace(".", "");
        return t.ToString("d MMM yy", Italian).Replace(".", "");
    }
}
