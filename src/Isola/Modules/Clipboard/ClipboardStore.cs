using System.Text.Json;
using System.Text.Json.Serialization;

namespace Isola.Modules.Clipboard;

public enum ClipKind { Text, Link, Image, Files }

/// <summary>One remembered clipboard item, as stored in history.json.</summary>
public sealed class ClipItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public ClipKind Kind { get; set; }
    public string? Text { get; set; }
    public List<string>? Files { get; set; }
    /// <summary>File name (inside images/) of the full PNG; the thumbnail is "{Id}.thumb.png".</summary>
    public string? Image { get; set; }
    public int ImageWidth { get; set; }
    public int ImageHeight { get; set; }
    /// <summary>Content hash used to drop consecutive duplicates.</summary>
    public string Hash { get; set; } = "";
    public bool Pinned { get; set; }
    public DateTime Time { get; set; } = DateTime.Now;
    /// <summary>Name of the computer it came from ("Appunti condivisi"); null if copied here.</summary>
    public string? From { get; set; }
}

public sealed class ClipboardHistory
{
    public int Version { get; set; } = 1;
    public List<ClipItem> Items { get; set; } = new();
}

public sealed class ClipboardSettings
{
    public bool Paused { get; set; }

    // "Appunti condivisi". The pairing key is NOT here: it is in data\clipboard\condivisione.key (DPAPI).
    public bool SyncEnabled { get; set; }
    public string? SyncPeer { get; set; }
    public bool SyncPaused { get; set; }
}

/// <summary>history.json + images/ in the module's data folder. Writes happen off the UI thread,
/// always the latest snapshot, in order.</summary>
internal sealed class ClipboardStore
{
    public const int MaxUnpinned = 200;

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = false,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly string _file;
    private readonly object _writeGate = new();
    private long _version;

    public ClipboardStore(string dataDir)
    {
        DataDir = dataDir;
        ImagesDir = Path.Combine(dataDir, "images");
        _file = Path.Combine(dataDir, "history.json");
    }

    public string DataDir { get; }
    public string ImagesDir { get; }

    public List<ClipItem> Load()
    {
        try
        {
            if (!File.Exists(_file)) return new();
            var h = JsonSerializer.Deserialize<ClipboardHistory>(File.ReadAllText(_file), Json);
            return h?.Items?.Where(i => i != null).ToList() ?? new();
        }
        catch { return new(); }
    }

    public void Save(IReadOnlyList<ClipItem> items, Action<string>? log)
    {
        // Snapshot on the UI thread (copies of the items: Time/Pinned change there), serialize and
        // write on a worker, so a large history never stalls the island.
        var snapshot = items.Select(Copy).ToList();
        long v = Interlocked.Increment(ref _version);
        Task.Run(() =>
        {
            lock (_writeGate)
            {
                if (v != Interlocked.Read(ref _version)) return; // a newer snapshot is coming
                try
                {
                    var json = JsonSerializer.Serialize(new ClipboardHistory { Items = snapshot }, Json);
                    Directory.CreateDirectory(DataDir);
                    Isola.Core.JsonStore.WriteAtomic(_file, json);
                }
                catch (Exception ex) { log?.Invoke("salvataggio cronologia non riuscito: " + ex.Message); }
            }
        });
    }

    private static ClipItem Copy(ClipItem i) => new()
    {
        Id = i.Id, Kind = i.Kind, Text = i.Text, Files = i.Files, Image = i.Image,
        ImageWidth = i.ImageWidth, ImageHeight = i.ImageHeight, Hash = i.Hash, Pinned = i.Pinned, Time = i.Time, From = i.From,
    };

    public string ImagePath(string name) => Path.Combine(ImagesDir, name);
    public string ThumbPath(ClipItem item) => Path.Combine(ImagesDir, item.Id + ".thumb.png");

    public void DeleteFiles(ClipItem item)
    {
        if (item.Kind != ClipKind.Image) return;
        try { if (item.Image != null) File.Delete(ImagePath(item.Image)); } catch { }
        try { File.Delete(ThumbPath(item)); } catch { }
    }

    /// <summary>Removes PNGs that no item references (left over by a crash).</summary>
    public void SweepOrphans(IEnumerable<ClipItem> items)
    {
        try
        {
            if (!Directory.Exists(ImagesDir)) return;
            var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var i in items.Where(i => i.Kind == ClipKind.Image))
            {
                if (i.Image != null) keep.Add(i.Image);
                keep.Add(i.Id + ".thumb.png");
            }
            foreach (var f in Directory.EnumerateFiles(ImagesDir, "*.png"))
                if (!keep.Contains(Path.GetFileName(f))) { try { File.Delete(f); } catch { } }
        }
        catch { }
    }
}
