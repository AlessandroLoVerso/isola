using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Isola.Modules.Music;

internal readonly record struct LrcLine(TimeSpan Time, string Text);

/// <summary>Synced lyrics from LRCLIB (lrclib.net), cached on disk. Only used when the user turns
/// lyrics on. Every failure is silent: the card simply shows no lyrics.</summary>
internal sealed class LyricsService
{
    private static readonly HttpClient Http = CreateClient();
    private static readonly TimeSpan NegativeCacheAge = TimeSpan.FromDays(3);

    private readonly string _dir;
    private readonly Action<string> _log;

    public LyricsService(string dir, Action<string> log)
    {
        _dir = dir;
        _log = log;
    }

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Isola/0.1");
        return c;
    }

    /// <summary>Returns the synced lines, or null when there are none (or the network failed).</summary>
    public async Task<LrcLine[]?> GetAsync(string artist, string title, string album, int durationSec, CancellationToken ct)
    {
        string file = Path.Combine(_dir, Hash($"{artist}\n{title}\n{album}\n{durationSec}") + ".lrc");
        try
        {
            if (File.Exists(file))
            {
                string cached = await File.ReadAllTextAsync(file, ct);
                if (cached.Length > 0) return Parse(cached);
                if (DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < NegativeCacheAge) return null;
            }
        }
        catch (OperationCanceledException) { return null; }
        catch { /* unreadable cache: fetch again */ }

        string? lrc;
        try
        {
            lrc = await FetchGet(artist, title, album, durationSec, ct);
            var (a2, t2) = CleanUp(artist, title);
            if (lrc == null && (a2 != artist || t2 != title))
                lrc = await FetchGet(a2, t2, album, durationSec, ct) ?? await FetchGet(a2, t2, "", durationSec, ct);
            lrc ??= await FetchSearch(a2, t2, durationSec, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { return null; }
        catch (Exception ex)
        {
            _log("Testi non disponibili: " + ex.GetType().Name);
            return null; // network trouble: do not cache, try again next time
        }

        try
        {
            Directory.CreateDirectory(_dir);
            await File.WriteAllTextAsync(file, lrc ?? "", CancellationToken.None);
        }
        catch { }
        return lrc == null ? null : Parse(lrc);
    }

    private static async Task<string?> FetchGet(string artist, string title, string album, int dur, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(artist)) return null;
        string url = "https://lrclib.net/api/get?artist_name=" + Uri.EscapeDataString(artist)
            + "&track_name=" + Uri.EscapeDataString(title)
            + "&album_name=" + Uri.EscapeDataString(album)
            + "&duration=" + dur.ToString(CultureInfo.InvariantCulture);
        using var resp = await Http.GetAsync(url, ct);
        if (resp.StatusCode == HttpStatusCode.NotFound) return null;
        resp.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        return Synced(doc.RootElement);
    }

    private static async Task<string?> FetchSearch(string artist, string title, int dur, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(title)) return null;
        string url = "https://lrclib.net/api/search?track_name=" + Uri.EscapeDataString(title)
            + (string.IsNullOrWhiteSpace(artist) ? "" : "&artist_name=" + Uri.EscapeDataString(artist));
        using var resp = await Http.GetAsync(url, ct);
        if (resp.StatusCode == HttpStatusCode.NotFound) return null;
        resp.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;
        foreach (var item in doc.RootElement.EnumerateArray())
        {
            if (!item.TryGetProperty("duration", out var d) || d.ValueKind != JsonValueKind.Number) continue;
            if (Math.Abs(d.GetDouble() - dur) > 3) continue;
            var s = Synced(item);
            if (s != null) return s;
        }
        return null;
    }

    private static string? Synced(JsonElement e) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty("syncedLyrics", out var s) && s.ValueKind == JsonValueKind.String
        && !string.IsNullOrWhiteSpace(s.GetString()) ? s.GetString() : null;

    /// <summary>YouTube-style metadata: "Artista - Brano (Official Video)" by "ArtistaVEVO".</summary>
    internal static (string Artist, string Title) CleanUp(string artist, string title)
    {
        string a = Regex.Replace(artist, @"\s*-\s*Topic$|VEVO$|\s+Official$", "", RegexOptions.IgnoreCase).Trim();
        string t = Regex.Replace(title, @"\s*[\(\[][^\)\]]*[\)\]]", "").Trim();
        t = Regex.Replace(t, @"\s*\|.*$", "").Trim();
        int dash = t.IndexOf(" - ", StringComparison.Ordinal);
        if (dash < 0) dash = t.IndexOf(" – ", StringComparison.Ordinal);
        if (dash > 0)
        {
            a = t[..dash].Trim();
            t = t[(dash + 3)..].Trim();
        }
        t = Regex.Replace(t, @"\s+(ft\.?|feat\.?)\s.*$", "", RegexOptions.IgnoreCase).Trim();
        return (a.Length > 0 ? a : artist, t.Length > 0 ? t : title);
    }

    private static readonly Regex TimeTag = new(@"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]", RegexOptions.Compiled);

    internal static LrcLine[]? Parse(string lrc)
    {
        var lines = new List<LrcLine>();
        foreach (var raw in lrc.Split('\n'))
        {
            var matches = TimeTag.Matches(raw);
            if (matches.Count == 0) continue;
            string text = raw[(matches[^1].Index + matches[^1].Length)..].Trim();
            foreach (Match m in matches)
            {
                int min = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                int sec = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
                double frac = 0;
                if (m.Groups[3].Success)
                    frac = int.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture) / Math.Pow(10, m.Groups[3].Value.Length);
                lines.Add(new LrcLine(TimeSpan.FromSeconds(min * 60 + sec + frac), text));
            }
        }
        if (lines.Count == 0) return null;
        lines.Sort((x, y) => x.Time.CompareTo(y.Time));
        return lines.ToArray();
    }

    /// <summary>Index of the line being sung at <paramref name="pos"/>, -1 before the first line.</summary>
    internal static int IndexAt(LrcLine[] lines, TimeSpan pos)
    {
        int lo = 0, hi = lines.Length - 1, found = -1;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2;
            if (lines[mid].Time <= pos) { found = mid; lo = mid + 1; } else hi = mid - 1;
        }
        return found;
    }

    private static string Hash(string s) => Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(s)))[..20].ToLowerInvariant();
}
