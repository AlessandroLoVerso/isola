using System.Collections.Specialized;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Isola.Core;
using static Isola.Modules.Clipboard.NativeClipboard;

namespace Isola.Modules.Clipboard;

/// <summary>"Appunti": clipboard history. Listens with AddClipboardFormatListener on the island
/// window (event-driven, nothing runs between copies), keeps the last 200 items plus the pinned
/// ones, skips what password managers mark as private, and puts items back with a click.</summary>
public sealed class ClipboardModule : IIslandModule
{
    /// <summary>Longer texts are not kept (never truncated: a restored item must be what was copied).
    /// Bounds history.json (200 items) and the work done on every change.</summary>
    private const int MaxTextChars = 200_000;
    private const long MaxImageBytes = 96L * 1024 * 1024;
    private const int ThumbHeight = 64;

    private IIslandHost? _host;
    private ClipboardStore? _store;
    private ClipboardSettings _settings = new();
    private readonly List<ClipItem> _items = new(); // newest first
    private ClipboardCard? _card;
    private bool _listening;
    private bool _captureQueued;
    private uint _lastSeq;
    private uint _ownSeq;
    private int _generation; // bumps on Stop, so late async captures are dropped

    private uint _fmtExclude, _fmtHistory, _fmtViewerIgnore, _fmtPng;

    public string Id => "clipboard";
    public string Title => "Appunti";
    public string Glyph => "";
    public int Order => 20;
    public bool EnabledByDefault => true;

    internal IReadOnlyList<ClipItem> Items => _items;
    internal ClipboardStore? Store => _store;
    internal bool Paused => _settings.Paused;

    public void Start(IIslandHost host)
    {
        _host = host;
        _generation++;
        _settings = host.LoadSettings<ClipboardSettings>(Id);
        _store = new ClipboardStore(host.DataDirectory(Id));
        _items.Clear();
        _items.AddRange(_store.Load().OrderByDescending(i => i.Time));
        _store.SweepOrphans(_items);

        _fmtExclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        _fmtHistory = RegisterClipboardFormat("CanIncludeInClipboardHistory");
        _fmtViewerIgnore = RegisterClipboardFormat("Clipboard Viewer Ignore");
        _fmtPng = RegisterClipboardFormat("PNG");

        _lastSeq = GetClipboardSequenceNumber(); // don't record what was already there at startup
        host.AddMessageHook(OnMessage);
        _listening = host.Hwnd != IntPtr.Zero && AddClipboardFormatListener(host.Hwnd);
        if (!_listening) host.Log(Id, "AddClipboardFormatListener non riuscito: " + Marshal.GetLastWin32Error());
    }

    public void Stop()
    {
        _generation++;
        if (_listening && _host != null) RemoveClipboardFormatListener(_host.Hwnd);
        _listening = false;
        _captureQueued = false;
        _card = null;
        _host = null;
    }

    public FrameworkElement? CreateCard()
    {
        _card = new ClipboardCard(this);
        return _card;
    }

    // =====================================================================================
    // Capture
    // =====================================================================================

    private bool OnMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg != WM_CLIPBOARDUPDATE || _host == null) return false;
        if (!_captureQueued)
        {
            _captureQueued = true;
            // Coalesce bursts (apps often set several formats in a row) and leave the WndProc fast.
            _host.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => _ = CaptureAsync()));
        }
        return false; // other modules may want it too
    }

    private enum ReadResult { Ok, Busy, Skip }

    private sealed class RawClip
    {
        public ClipKind Kind;
        public string? Text;
        public List<string>? Files;
        public byte[]? Png;
        public byte[]? Dib;
    }

    private async Task CaptureAsync()
    {
        _captureQueued = false;
        int gen = _generation;
        if (_host == null || _settings.Paused) { _lastSeq = GetClipboardSequenceNumber(); return; }

        uint seq = GetClipboardSequenceNumber();
        if (seq == _lastSeq) return;
        _lastSeq = seq;
        if (_ownSeq != 0 && seq <= _ownSeq) return; // we put it there ourselves

        RawClip? raw = null;
        for (int attempt = 0; attempt <= 3; attempt++)
        {
            var r = TryRead(out raw);
            if (r == ReadResult.Ok) break;
            if (r == ReadResult.Skip) return;
            raw = null;
            if (attempt == 3) { _host?.Log(Id, "appunti occupati, elemento saltato"); return; }
            await Task.Delay(50);
            if (gen != _generation || _host == null) return;
        }
        if (raw == null) return;

        try
        {
            switch (raw.Kind)
            {
                case ClipKind.Files:
                    if (raw.Files is not { Count: > 0 }) return;
                    Add(new ClipItem { Kind = ClipKind.Files, Files = raw.Files, Hash = Sha(string.Join("\n", raw.Files)) });
                    break;
                case ClipKind.Text:
                    var text = raw.Text ?? "";
                    if (string.IsNullOrWhiteSpace(text)) return;
                    var kind = IsUrl(text.Trim()) ? ClipKind.Link : ClipKind.Text;
                    if (kind == ClipKind.Link) text = text.Trim();
                    Add(new ClipItem { Kind = kind, Text = text, Hash = Sha(text) });
                    break;
                case ClipKind.Image:
                    await CaptureImageAsync(raw, gen);
                    break;
            }
        }
        catch (Exception ex)
        {
            _host?.Log(Id, "elemento non salvato: " + ex.Message);
        }
    }

    /// <summary>Reads the clipboard in one short Open/Close. Busy = another app holds it.</summary>
    private ReadResult TryRead(out RawClip? raw)
    {
        raw = null;
        if (_host == null) return ReadResult.Skip;

        // Password managers: "don't record this". Checked before reading anything.
        if (IsClipboardFormatAvailable(_fmtExclude) || IsClipboardFormatAvailable(_fmtViewerIgnore))
            return ReadResult.Skip;

        if (!OpenClipboard(_host.Hwnd)) return ReadResult.Busy;
        try
        {
            // Again, now that it is ours: the content may have changed since the check above.
            if (IsClipboardFormatAvailable(_fmtExclude) || IsClipboardFormatAvailable(_fmtViewerIgnore))
                return ReadResult.Skip;
            if (IsClipboardFormatAvailable(_fmtHistory))
            {
                var bytes = ReadGlobal(GetClipboardData(_fmtHistory), 64);
                if (bytes == null || bytes.Length < 4 || BitConverter.ToInt32(bytes, 0) == 0) return ReadResult.Skip;
            }

            if (IsClipboardFormatAvailable(CF_HDROP))
            {
                var files = ReadFileDrop(GetClipboardData(CF_HDROP));
                if (files.Count > 0) { raw = new RawClip { Kind = ClipKind.Files, Files = files }; return ReadResult.Ok; }
            }
            if (IsClipboardFormatAvailable(CF_UNICODETEXT))
            {
                var text = ReadUnicodeText(GetClipboardData(CF_UNICODETEXT), MaxTextChars + 1);
                if (text != null && text.Length > MaxTextChars)
                {
                    _host?.Log(Id, "testo troppo lungo, non salvato");
                    return ReadResult.Skip;
                }
                if (!string.IsNullOrWhiteSpace(text)) { raw = new RawClip { Kind = ClipKind.Text, Text = text }; return ReadResult.Ok; }
            }
            if (IsClipboardFormatAvailable(_fmtPng))
            {
                var png = ReadGlobal(GetClipboardData(_fmtPng), MaxImageBytes);
                if (png != null) { raw = new RawClip { Kind = ClipKind.Image, Png = png }; return ReadResult.Ok; }
            }
            if (IsClipboardFormatAvailable(CF_DIB))
            {
                var dib = ReadGlobal(GetClipboardData(CF_DIB), MaxImageBytes);
                if (dib != null) { raw = new RawClip { Kind = ClipKind.Image, Dib = dib }; return ReadResult.Ok; }
            }
            return ReadResult.Skip; // nothing we keep (e.g. only custom formats)
        }
        finally { CloseClipboard(); }
    }

    private async Task CaptureImageAsync(RawClip raw, int gen)
    {
        var store = _store!;
        var id = Guid.NewGuid().ToString("N");
        var result = await Task.Run(() =>
        {
            BitmapSource frame;
            byte[] png;
            if (raw.Png != null)
            {
                frame = BitmapDecoder.Create(new MemoryStream(raw.Png), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
                png = raw.Png;
            }
            else
            {
                frame = DecodeDib(raw.Dib!);
                png = EncodePng(frame);
            }
            var hash = Sha(raw.Png ?? raw.Dib!);
            Directory.CreateDirectory(store.ImagesDir);
            var name = id + ".png";
            File.WriteAllBytes(store.ImagePath(name), png);
            double scale = Math.Min(1.0, ThumbHeight / (double)Math.Max(1, frame.PixelHeight));
            BitmapSource thumb = scale < 1 ? new TransformedBitmap(frame, new ScaleTransform(scale, scale)) : frame;
            File.WriteAllBytes(Path.Combine(store.ImagesDir, id + ".thumb.png"), EncodePng(thumb));
            return (name, frame.PixelWidth, frame.PixelHeight, hash);
        });
        var item = new ClipItem
        {
            Id = id,
            Kind = ClipKind.Image,
            Image = result.name,
            ImageWidth = result.PixelWidth,
            ImageHeight = result.PixelHeight,
            Hash = result.hash,
        };
        if (gen != _generation || _host == null) { store.DeleteFiles(item); return; }
        Add(item);
    }

    private static BitmapSource DecodeDib(byte[] dib)
    {
        int headerSize = BitConverter.ToInt32(dib, 0);
        int bitCount = BitConverter.ToInt16(dib, 14);
        int compression = BitConverter.ToInt32(dib, 16);
        int clrUsed = BitConverter.ToInt32(dib, 32);
        int colors = clrUsed != 0 ? clrUsed : bitCount <= 8 ? 1 << bitCount : 0;
        int masks = compression == 3 && headerSize == 40 ? 12 : 0;
        int offset = 14 + headerSize + masks + colors * 4;
        var bmp = new byte[14 + dib.Length];
        bmp[0] = (byte)'B'; bmp[1] = (byte)'M';
        BitConverter.GetBytes(bmp.Length).CopyTo(bmp, 2);
        BitConverter.GetBytes(offset).CopyTo(bmp, 10);
        Buffer.BlockCopy(dib, 0, bmp, 14, dib.Length);
        var frame = new BmpBitmapDecoder(new MemoryStream(bmp), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
        // 32-bit DIBs usually carry no real alpha: show them opaque.
        if (frame.Format == PixelFormats.Bgra32) frame = BitmapFrame.Create(new FormatConvertedBitmap(frame, PixelFormats.Bgr32, null, 0));
        return frame;
    }

    private static byte[] EncodePng(BitmapSource src)
    {
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(src));
        using var ms = new MemoryStream();
        enc.Save(ms);
        return ms.ToArray();
    }

    private void Add(ClipItem item)
    {
        if (_host == null || _store == null) return;
        item.Time = DateTime.Now;
        var newest = _items.FirstOrDefault();
        if (newest != null && newest.Kind == item.Kind && newest.Hash == item.Hash)
        {
            _store.DeleteFiles(item);
            newest.Time = item.Time;
            Changed();
            return;
        }
        _items.Insert(0, item);
        var unpinned = _items.Where(i => !i.Pinned).ToList();
        foreach (var old in unpinned.Skip(ClipboardStore.MaxUnpinned))
        {
            _items.Remove(old);
            _store.DeleteFiles(old);
        }
        Changed();
    }

    private void Changed()
    {
        _store?.Save(_items, m => _host?.Log(Id, m));
        _card?.Reload();
    }

    internal static bool IsUrl(string s)
    {
        if (s.Length > 2048 || s.Any(char.IsWhiteSpace)) return false;
        if (s.StartsWith("www.", StringComparison.OrdinalIgnoreCase) && s.Contains('.', StringComparison.Ordinal)) return s.Length > 6;
        return Uri.TryCreate(s, UriKind.Absolute, out var u)
               && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps || u.Scheme == Uri.UriSchemeFtp || u.Scheme == Uri.UriSchemeMailto)
               && (u.Scheme == Uri.UriSchemeMailto || u.Host.Length > 0);
    }

    private static string Sha(string s) => Sha(Encoding.UTF8.GetBytes(s));
    private static string Sha(byte[] b) => Convert.ToHexString(SHA256.HashData(b))[..32];

    // =====================================================================================
    // Actions from the card
    // =====================================================================================

    /// <summary>Puts the item back on the clipboard. Returns false if the clipboard was busy.</summary>
    internal bool Restore(ClipItem item, out string? error)
    {
        error = null;
        if (_store == null) return false;
        var data = new DataObject();
        switch (item.Kind)
        {
            case ClipKind.Text:
            case ClipKind.Link:
                data.SetText(item.Text ?? "", TextDataFormat.UnicodeText);
                break;
            case ClipKind.Files:
                var sc = new StringCollection();
                foreach (var f in item.Files ?? new()) if (File.Exists(f) || Directory.Exists(f)) sc.Add(f);
                if (sc.Count == 0) { error = "I file non esistono più"; return false; }
                data.SetFileDropList(sc);
                break;
            case ClipKind.Image:
                var path = item.Image != null ? _store.ImagePath(item.Image) : null;
                if (path == null || !File.Exists(path)) { error = "Immagine non trovata"; return false; }
                var bytes = File.ReadAllBytes(path);
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.StreamSource = new MemoryStream(bytes);
                bmp.EndInit();
                bmp.Freeze();
                data.SetImage(bmp);
                data.SetData("PNG", new MemoryStream(bytes));
                break;
        }

        try
        {
            // WPF already retries a busy clipboard for a moment.
            System.Windows.Clipboard.SetDataObject(data, true);
        }
        catch (ExternalException)
        {
            error = "Appunti occupati, riprova";
            return false;
        }
        _ownSeq = GetClipboardSequenceNumber();
        _lastSeq = _ownSeq;

        // Reused = most recent.
        item.Time = DateTime.Now;
        _items.Remove(item);
        _items.Insert(0, item);
        Changed();
        return true;
    }

    internal void TogglePin(ClipItem item)
    {
        item.Pinned = !item.Pinned;
        if (!item.Pinned)
        {
            // Unpinning may push the history over the limit.
            foreach (var old in _items.Where(i => !i.Pinned).Skip(ClipboardStore.MaxUnpinned).ToList())
            {
                if (ReferenceEquals(old, item)) continue;
                _items.Remove(old);
                _store?.DeleteFiles(old);
            }
        }
        Changed();
    }

    internal void Delete(ClipItem item)
    {
        if (!_items.Remove(item)) return;
        _store?.DeleteFiles(item);
        Changed();
    }

    /// <summary>Clears the history but keeps the pinned items.</summary>
    internal void ClearAll()
    {
        foreach (var i in _items.Where(i => !i.Pinned).ToList())
        {
            _items.Remove(i);
            _store?.DeleteFiles(i);
        }
        Changed();
    }

    internal void RequestKeyboardFocus() => _host?.RequestKeyboardFocus();

    // =====================================================================================
    // Settings page
    // =====================================================================================

    public FrameworkElement? CreateSettingsPage()
    {
        var root = new StackPanel();

        var pause = new CheckBox { IsChecked = _settings.Paused, Content = "Pausa cronologia" };
        pause.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.ToggleSwitch");
        void PauseChanged(object s, RoutedEventArgs e)
        {
            _settings.Paused = pause.IsChecked == true;
            _host?.SaveSettings(Id, _settings);
            _lastSeq = GetClipboardSequenceNumber();
            _card?.Reload();
        }
        pause.Checked += PauseChanged;
        pause.Unchecked += PauseChanged;
        root.Children.Add(SettingCard(Row("Pausa cronologia",
            "Finché è attiva, quello che copi non viene ricordato.", pause, hideTitle: true)));

        var clear = new Button { Content = "Cancella tutto" };
        clear.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.Button");
        var info = Muted(Description());
        bool armed = false;
        clear.Click += (_, _) =>
        {
            if (!armed)
            {
                armed = true;
                clear.Content = "Conferma";
                clear.SetResourceReference(Control.BackgroundProperty, "Isola.Brush.Accent");
                return;
            }
            ClearAll();
            armed = false;
            clear.Content = "Cancella tutto";
            clear.ClearValue(Control.BackgroundProperty);
            info.Text = Description();
        };
        root.Children.Add(SettingCard(Row("Cancella tutto", info, clear)));

        root.Children.Add(SettingCard(new TextBlock
        {
            Text = "Testo, link, immagini e file restano solo su questo PC. Gli elementi che i gestori di password "
                 + "segnano come riservati non vengono mai salvati.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 12),
            Opacity = 0.75,
        }));
        return root;

        string Description()
        {
            int n = _items.Count, p = _items.Count(i => i.Pinned);
            var s = n == 0 ? "La cronologia è vuota." : n == 1 ? "1 elemento" : $"{n} elementi";
            if (p > 0) s += p == 1 ? ", 1 fissato" : $", {p} fissati";
            if (n == 0) return s;
            if (n == p) return s + ". I fissati restano anche dopo Cancella tutto.";
            return s + (p > 0 ? ". Elimina la cronologia; i fissati restano." : ". Elimina la cronologia (gli elementi fissati restano).");
        }
    }

    private static Border SettingCard(UIElement child)
    {
        var b = new Border { Child = child };
        b.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SettingCard");
        return b;
    }

    private static TextBlock Muted(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");
        return t;
    }

    private static FrameworkElement Row(string title, string description, UIElement control, bool hideTitle = false)
    {
        if (hideTitle && control is CheckBox cb)
        {
            // The toggle carries its own label; put the description under it.
            var stack = new StackPanel { Margin = new Thickness(0, 12, 0, 12) };
            stack.Children.Add(cb);
            var d = Muted(description);
            d.Margin = new Thickness(50, 2, 0, 0);
            stack.Children.Add(d);
            return stack;
        }
        return Row(title, Muted(description), control);
    }

    private static FrameworkElement Row(string title, TextBlock description, UIElement control)
    {
        var grid = new Grid { Margin = new Thickness(0, 12, 0, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        texts.Children.Add(new TextBlock { Text = title, FontSize = 13.5 });
        texts.Children.Add(description);
        grid.Children.Add(texts);
        if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }
}
