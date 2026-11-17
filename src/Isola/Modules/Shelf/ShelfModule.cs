using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Isola.Core;

namespace Isola.Modules.Shelf;

/// <summary>"Mensola": drop files on the island, they wait there (only the paths are kept, files
/// are never copied or deleted), then drag them out to a folder or an app, one or many at once.</summary>
public sealed class ShelfModule : IIslandModule, IRestingFaceProvider
{
    private const int MaxItems = 200;
    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".jfif", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".ico",
    };
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    private IIslandHost? _host;
    private string? _file;
    private ShelfCard? _card;
    private UIElement? _root;
    private bool _rootAllowDropWas;
    private readonly ShelfFace _face = new();

    public string Id => "shelf";
    public string Title => "Mensola";
    public string Glyph => "";
    public int Order => 30;
    public bool EnabledByDefault => true;

    internal ObservableCollection<ShelfEntry> Items { get; } = new();

    /// <summary>True while a drag started from the shelf is in progress (so we don't take it back).</summary>
    internal bool DraggingOut { get; set; }

    public int RestingPriority => Items.Count > 0 ? 10 : 0;

    public void Start(IIslandHost host)
    {
        _host = host;
        _file = Path.Combine(host.DataDirectory(Id), "shelf.json");
        Items.Clear();
        foreach (var p in Load()) Items.Add(new ShelfEntry(p.Path, p.Added));
        UpdateFace();
        HookIsland();
        // Existence (and so the right icon) is checked off the UI thread: a file on a share that is
        // offline can take many seconds to answer.
        RefreshExistence(() =>
        {
            foreach (var e in Items) LoadVisual(e);
            UpdateFace();
            _card?.Refresh();
        });
    }

    public void Stop()
    {
        UnhookIsland();
        _card = null;
        _host = null;
    }

    public FrameworkElement? CreateCard()
    {
        _card = new ShelfCard(this);
        return _card;
    }

    public FrameworkElement? CreateSettingsPage() => null;

    // =====================================================================================
    // Drag over the whole island: open on the shelf, accept files anywhere on it
    // =====================================================================================

    private void HookIsland()
    {
        if (_host == null || _host.Hwnd == IntPtr.Zero) return;
        _root = HwndSource.FromHwnd(_host.Hwnd)?.RootVisual as UIElement;
        if (_root == null) { _host.Log(Id, "finestra dell'isola non trovata: trascina i file sulla scheda Mensola"); return; }
        _rootAllowDropWas = _root.AllowDrop;
        _root.AllowDrop = true;
        _root.PreviewDragEnter += OnIslandDragEnter;
        _root.DragEnter += OnIslandDragOver;
        _root.DragOver += OnIslandDragOver;
        _root.Drop += OnIslandDrop;
    }

    private void UnhookIsland()
    {
        if (_root == null) return;
        _root.PreviewDragEnter -= OnIslandDragEnter;
        _root.DragEnter -= OnIslandDragOver;
        _root.DragOver -= OnIslandDragOver;
        _root.Drop -= OnIslandDrop;
        _root.AllowDrop = _rootAllowDropWas;
        _root = null;
    }

    private static bool HasFiles(DragEventArgs e) => e.Data.GetDataPresent(DataFormats.FileDrop);

    private static DragDropEffects AcceptEffect(DragEventArgs e)
        => (e.AllowedEffects & DragDropEffects.Copy) != 0 ? DragDropEffects.Copy
         : (e.AllowedEffects & DragDropEffects.Link) != 0 ? DragDropEffects.Link
         : DragDropEffects.None;

    private void OnIslandDragEnter(object sender, DragEventArgs e)
    {
        if (DraggingOut || !HasFiles(e) || _host == null) return;
        if (_card is not { IsVisible: true }) _host.OpenTab(Id);
    }

    private void OnIslandDragOver(object sender, DragEventArgs e)
    {
        if (e.Handled) return; // another module's card took it
        // Never report Move: the source (e.g. Explorer) would delete the original file.
        e.Effects = !DraggingOut && HasFiles(e) ? AcceptEffect(e) : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnIslandDrop(object sender, DragEventArgs e)
    {
        if (e.Handled) return;
        e.Handled = true;
        _card?.HideDropHint();
        if (DraggingOut || !HasFiles(e)) { e.Effects = DragDropEffects.None; return; }
        e.Effects = AcceptEffect(e);
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) Add(paths);
    }

    // =====================================================================================
    // Items
    // =====================================================================================

    internal void Add(IEnumerable<string> paths)
    {
        var known = new HashSet<string>(Items.Select(i => i.Path), StringComparer.OrdinalIgnoreCase);
        int added = 0;
        foreach (var raw in paths)
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            string p;
            try { p = Path.GetFullPath(raw); } catch { continue; }
            if (!known.Add(p)) continue;
            var e = new ShelfEntry(p, DateTime.Now);
            e.RefreshExists();
            Items.Add(e);
            LoadVisual(e);
            added++;
        }
        while (Items.Count > MaxItems) Items.RemoveAt(0);
        if (added > 0) Changed();
    }

    internal void Remove(IEnumerable<ShelfEntry> entries)
    {
        bool any = false;
        foreach (var e in entries.ToList()) any |= Items.Remove(e);
        if (any) Changed();
    }

    private int _probeVersion;

    /// <summary>Re-checks which files still exist, on a worker thread (never blocks the island,
    /// even for paths on a network share that is offline), then applies the results on the UI
    /// thread and runs <paramref name="then"/>.</summary>
    internal void RefreshExistence(Action? then = null)
    {
        var host = _host;
        var entries = Items.ToList();
        if (host == null || entries.Count == 0) { then?.Invoke(); return; }
        int version = ++_probeVersion;
        Task.Run(() =>
        {
            var results = new (bool Dir, bool Exists)[entries.Count];
            for (int i = 0; i < entries.Count; i++) results[i] = ShelfEntry.Probe(entries[i].Path);
            host.Dispatcher.BeginInvoke(() =>
            {
                if (_host != host || version != _probeVersion) return; // stopped, or a newer check runs
                for (int i = 0; i < entries.Count; i++) entries[i].Apply(results[i]);
                then?.Invoke();
            });
        });
    }

    internal void OpenFolder(ShelfEntry e)
    {
        try
        {
            if (e.Exists)
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{e.Path}\"") { UseShellExecute = true });
            else if (Path.GetDirectoryName(e.Path) is { } dir && Directory.Exists(dir))
                Process.Start(new ProcessStartInfo(dir) { UseShellExecute = true });
        }
        catch (Exception ex) { _host?.Log(Id, "apri cartella non riuscito: " + ex.Message); }
    }

    internal void Open(ShelfEntry e)
    {
        if (!e.Exists) return;
        try { Process.Start(new ProcessStartInfo(e.Path) { UseShellExecute = true }); }
        catch (Exception ex) { _host?.Log(Id, "apertura non riuscita: " + ex.Message); }
    }

    internal void Log(string message) => _host?.Log(Id, message);

    private void Changed()
    {
        Save();
        UpdateFace();
        _card?.Refresh();
        _host?.RefreshRestingFace();
    }

    private void UpdateFace()
    {
        _face.Count = Items.Count;
        _face.Icon = Items.LastOrDefault()?.Icon;
    }

    /// <summary>Shell icon now (cached, fast); image thumbnail decoded small in the background.</summary>
    private void LoadVisual(ShelfEntry e)
    {
        e.Icon = NativeShelf.Icon(e.Path, e.IsDirectory, e.Exists);
        if (!e.Exists || e.IsDirectory || !ImageExtensions.Contains(Path.GetExtension(e.Path))) return;
        var path = e.Path;
        var dispatcher = _host?.Dispatcher;
        Task.Run(() =>
        {
            try
            {
                if (new FileInfo(path).Length > 80L * 1024 * 1024) return;
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
                bmp.DecodePixelWidth = 112;
                bmp.UriSource = new Uri(path);
                bmp.EndInit();
                bmp.Freeze();
                dispatcher?.BeginInvoke(() => e.Thumb = bmp);
            }
            catch { /* not decodable: keep the shell icon */ }
        });
    }

    // ---- Persistence ----------------------------------------------------------------------

    private sealed class ShelfData
    {
        public List<ShelfRecord> Items { get; set; } = new();
    }

    private sealed class ShelfRecord
    {
        public string Path { get; set; } = "";
        public DateTime Added { get; set; }
    }

    private List<ShelfRecord> Load()
    {
        try
        {
            if (_file == null || !File.Exists(_file)) return new();
            var data = JsonSerializer.Deserialize<ShelfData>(File.ReadAllText(_file), Json);
            return data?.Items?.Where(r => !string.IsNullOrWhiteSpace(r.Path)).ToList() ?? new();
        }
        catch (Exception ex)
        {
            _host?.Log(Id, "shelf.json illeggibile: " + ex.Message);
            return new();
        }
    }

    private void Save()
    {
        if (_file == null) return;
        try
        {
            var data = new ShelfData { Items = Items.Select(i => new ShelfRecord { Path = i.Path, Added = i.Added }).ToList() };
            var tmp = _file + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(data, Json));
            File.Move(tmp, _file, overwrite: true);
        }
        catch (Exception ex) { _host?.Log(Id, "salvataggio non riuscito: " + ex.Message); }
    }

    // =====================================================================================
    // Resting face: small icon + "Mensola" on the left, count on the right
    // =====================================================================================

    public FrameworkElement CreateRestingFace()
    {
        var icon = new Image { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 7, 0) };
        RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
        icon.SetBinding(Image.SourceProperty, new Binding(nameof(ShelfFace.Icon)));

        var glyph = new TextBlock { Text = "", FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 7, 0) };
        glyph.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        glyph.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(ShelfFace.GlyphVisibility)));
        icon.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(ShelfFace.IconVisibility)));

        var label = new TextBlock { Text = "Mensola", FontSize = 12.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        var left = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(icon);
        left.Children.Add(glyph);
        left.Children.Add(label);

        var count = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        count.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        count.SetBinding(TextBlock.TextProperty, new Binding(nameof(ShelfFace.CountText)));

        var grid = new Grid { DataContext = _face };
        grid.Children.Add(left);
        grid.Children.Add(count);
        return grid;
    }
}

internal sealed class ShelfFace : INotifyPropertyChanged
{
    private int _count;
    private ImageSource? _icon;

    public int Count
    {
        get => _count;
        set { if (_count == value) return; _count = value; Raise(nameof(CountText)); }
    }

    public ImageSource? Icon
    {
        get => _icon;
        set { if (ReferenceEquals(_icon, value)) return; _icon = value; Raise(nameof(Icon)); Raise(nameof(IconVisibility)); Raise(nameof(GlyphVisibility)); }
    }

    public string CountText => _count == 1 ? "1 file" : $"{_count} file";
    public Visibility IconVisibility => _icon != null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility GlyphVisibility => _icon == null ? Visibility.Visible : Visibility.Collapsed;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>One file or folder on the shelf.</summary>
internal sealed class ShelfEntry : INotifyPropertyChanged
{
    private bool _selected, _exists = true;
    private ImageSource? _thumb, _icon;

    public ShelfEntry(string path, DateTime added)
    {
        Path = path;
        Added = added;
        var name = System.IO.Path.GetFileName(path.TrimEnd('\\', '/'));
        Name = name.Length > 0 ? name : path;
    }

    public string Path { get; }
    public DateTime Added { get; }
    public string Name { get; }
    public bool IsDirectory { get; private set; }

    public bool Exists
    {
        get => _exists;
        private set { if (_exists == value) return; _exists = value; Raise(nameof(Exists)); Raise(nameof(Tooltip)); }
    }

    public bool IsSelected
    {
        get => _selected;
        set { if (_selected == value) return; _selected = value; Raise(nameof(IsSelected)); }
    }

    public ImageSource? Icon
    {
        get => _icon;
        set { _icon = value; Raise(nameof(Icon)); }
    }

    public ImageSource? Thumb
    {
        get => _thumb;
        set { _thumb = value; Raise(nameof(Thumb)); Raise(nameof(HasThumb)); }
    }

    public bool HasThumb => _thumb != null;

    public string Tooltip => Exists ? Path : Path + "\nNon trovato: spostato o eliminato";

    public void RefreshExists() => Apply(Probe(Path));

    /// <summary>Touches the disk: thread-safe, may be slow for network paths.</summary>
    public static (bool Dir, bool Exists) Probe(string path)
    {
        try
        {
            bool dir = Directory.Exists(path);
            return (dir, dir || File.Exists(path));
        }
        catch { return (false, false); }
    }

    /// <summary>UI thread.</summary>
    public void Apply((bool Dir, bool Exists) r)
    {
        IsDirectory = r.Dir;
        Exists = r.Exists;
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
