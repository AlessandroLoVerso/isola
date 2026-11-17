using System.Globalization;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Isola.Modules.Music;

internal enum SpotifyError { None, NotConnected, PremiumRequired, Forbidden, RateLimited, NotFound, Network, Failed }

internal readonly record struct ApiResult(int Status, string Body, SpotifyError Error)
{
    public bool Ok => Error == SpotifyError.None;
}

internal sealed record SpotifyTrack(string? Id, string Uri, string Name, string Artist, string? ImageUrl);
internal sealed record SpotifyQueueEntry(string Name, string Artist);
internal sealed record SpotifyPlaylist(string Id, string Name, int Count, string OwnerId, bool Collaborative);
internal sealed record SpotifyMe(string Id, string DisplayName);

/// <summary>Spotify Web API client. Thread-safe, never called on the UI thread. Keeps the access
/// token in memory, refreshes it once on 401, honours Retry-After on 429, maps 403
/// PREMIUM_REQUIRED. Logs only "Spotify: …" status lines, never tokens or account data.</summary>
internal sealed class SpotifyApi
{
    private const string ApiBase = "https://api.spotify.com/v1";
    private const string TokenUrl = "https://accounts.spotify.com/api/token";
    private static readonly TimeSpan MaxInlineRetryAfter = TimeSpan.FromSeconds(3);

    private static readonly HttpClient Http = CreateClient();

    private readonly SpotifyTokenStore _store;
    private readonly Action<string> _log;
    private readonly SemaphoreSlim _tokenGate = new(1, 1);
    private readonly object _sync = new();
    private SpotifyTokenStore.Credentials? _creds;
    private string? _access;
    private DateTime _accessExpiresUtc;
    private DateTime _blockedUntilUtc;

    /// <summary>Raised (on a worker thread) when Spotify rejects the refresh token.</summary>
    public event Action? Revoked;

    public SpotifyApi(SpotifyTokenStore store, Action<string> log)
    {
        _store = store;
        _log = log;
    }

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Isola/0.1");
        return c;
    }

    public bool IsConnected { get { lock (_sync) return _creds != null; } }

    /// <summary>Reads spotify.bin (DPAPI). Call off the UI thread.</summary>
    public bool LoadStored()
    {
        var c = _store.Load();
        lock (_sync) _creds = c;
        return c != null;
    }

    public void Disconnect()
    {
        lock (_sync)
        {
            _creds = null;
            _access = null;
            _accessExpiresUtc = default;
        }
        _store.Delete();
    }

    // ---------- tokens ----------

    /// <summary>Exchanges the authorization code (PKCE) for tokens and stores the refresh token.</summary>
    public async Task<bool> ExchangeCodeAsync(string clientId, string code, string verifier)
    {
        var form = new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code",
            ["code"] = code,
            ["redirect_uri"] = SpotifyPkce.RedirectUri,
            ["client_id"] = clientId,
            ["code_verifier"] = verifier,
        };
        var (status, body) = await PostTokenAsync(form).ConfigureAwait(false);
        if (status != 200) { _log($"Spotify: errore {(status == 0 ? "rete" : status.ToString(CultureInfo.InvariantCulture))}"); return false; }
        var t = ParseTokens(body);
        if (t == null || t.Value.Refresh == null) { _log("Spotify: errore risposta"); return false; }
        var creds = new SpotifyTokenStore.Credentials(clientId, t.Value.Refresh);
        try { _store.Save(creds); }
        catch { _log("Spotify: errore salvataggio"); return false; }
        lock (_sync)
        {
            _creds = creds;
            _access = t.Value.Access;
            _accessExpiresUtc = DateTime.UtcNow.AddSeconds(Math.Max(60, t.Value.ExpiresIn - 60));
        }
        return true;
    }

    private async Task<bool> RefreshAsync(string? staleAccess)
    {
        await _tokenGate.WaitAsync().ConfigureAwait(false);
        try
        {
            SpotifyTokenStore.Credentials? creds;
            lock (_sync)
            {
                creds = _creds;
                // Someone else refreshed while we waited.
                if (_access != null && _access != staleAccess && DateTime.UtcNow < _accessExpiresUtc) return true;
            }
            if (creds == null) return false;

            var (status, body) = await PostTokenAsync(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = creds.RefreshToken,
                ["client_id"] = creds.ClientId,
            }).ConfigureAwait(false);

            if (status == 200 && ParseTokens(body) is { } t)
            {
                var next = t.Refresh != null && t.Refresh != creds.RefreshToken ? creds with { RefreshToken = t.Refresh } : creds;
                lock (_sync)
                {
                    if (_creds == null) return false; // disconnected meanwhile
                    _creds = next;
                    _access = t.Access;
                    _accessExpiresUtc = DateTime.UtcNow.AddSeconds(Math.Max(60, t.ExpiresIn - 60));
                }
                // PKCE refresh tokens rotate: the old one may stop working, keep the new one.
                if (!ReferenceEquals(next, creds)) { try { _store.Save(next); } catch { } }
                return true;
            }

            if (status is 400 or 401
                && (body.Contains("invalid_grant", StringComparison.Ordinal) || body.Contains("invalid_client", StringComparison.Ordinal)))
            {
                Disconnect();
                _log("Spotify: scollegato");
                Revoked?.Invoke();
                return false;
            }
            _log($"Spotify: errore {(status == 0 ? "rete" : status.ToString(CultureInfo.InvariantCulture))}");
            return false;
        }
        finally { _tokenGate.Release(); }
    }

    private static async Task<(int Status, string Body)> PostTokenAsync(Dictionary<string, string> form)
    {
        try
        {
            using var content = new FormUrlEncodedContent(form);
            using var resp = await Http.PostAsync(TokenUrl, content).ConfigureAwait(false);
            return ((int)resp.StatusCode, await resp.Content.ReadAsStringAsync().ConfigureAwait(false));
        }
        catch { return (0, ""); }
    }

    // ---------- generic call ----------

    public async Task<ApiResult> SendAsync(HttpMethod method, string pathAndQuery, string? json = null)
    {
        if (!IsConnected) return new(0, "", SpotifyError.NotConnected);
        bool refreshed = false, waited = false;
        while (true)
        {
            if (DateTime.UtcNow < _blockedUntilUtc) return new(429, "", SpotifyError.RateLimited);

            string? access;
            lock (_sync) access = _access != null && DateTime.UtcNow < _accessExpiresUtc ? _access : null;
            if (access == null)
            {
                if (refreshed || !await RefreshAsync(null).ConfigureAwait(false))
                    return new(0, "", IsConnected ? SpotifyError.Failed : SpotifyError.NotConnected);
                refreshed = true;
                continue;
            }

            HttpResponseMessage resp;
            try
            {
                using var req = new HttpRequestMessage(method, ApiBase + pathAndQuery);
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
                if (json != null) req.Content = new StringContent(json, Encoding.UTF8, "application/json");
                else if (method != HttpMethod.Get) req.Content = new ByteArrayContent(Array.Empty<byte>());
                resp = await Http.SendAsync(req).ConfigureAwait(false);
            }
            catch
            {
                _log("Spotify: errore rete");
                return new(0, "", SpotifyError.Network);
            }

            using (resp)
            {
                int status = (int)resp.StatusCode;
                string body;
                try { body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); }
                catch { body = ""; }

                if (status is >= 200 and < 300) return new(status, body, SpotifyError.None);

                if (status == 401 && !refreshed)
                {
                    refreshed = true;
                    if (!await RefreshAsync(access).ConfigureAwait(false))
                        return new(401, "", IsConnected ? SpotifyError.Failed : SpotifyError.NotConnected);
                    continue;
                }
                if (status == 429)
                {
                    var wait = RetryAfter(resp);
                    _blockedUntilUtc = DateTime.UtcNow + wait;
                    if (!waited && wait <= MaxInlineRetryAfter)
                    {
                        waited = true;
                        await Task.Delay(wait).ConfigureAwait(false);
                        continue;
                    }
                    _log("Spotify: errore 429");
                    return new(429, "", SpotifyError.RateLimited);
                }
                if (status == 403)
                    return new(403, body, IsPremiumRequired(body) ? SpotifyError.PremiumRequired : SpotifyError.Forbidden);
                if (status == 404) return new(404, body, SpotifyError.NotFound);

                _log($"Spotify: errore {status.ToString(CultureInfo.InvariantCulture)}");
                return new(status, body, SpotifyError.Failed);
            }
        }
    }

    private static TimeSpan RetryAfter(HttpResponseMessage resp)
    {
        var ra = resp.Headers.RetryAfter;
        TimeSpan t = ra?.Delta ?? (ra?.Date is { } d ? d - DateTimeOffset.UtcNow : TimeSpan.FromSeconds(5));
        if (t < TimeSpan.FromSeconds(1)) t = TimeSpan.FromSeconds(1);
        if (t > TimeSpan.FromHours(1)) t = TimeSpan.FromHours(1);
        return t;
    }

    // ---------- endpoints ----------

    public async Task<(SpotifyMe? Me, SpotifyError Error)> GetMeAsync()
    {
        var r = await SendAsync(HttpMethod.Get, "/me").ConfigureAwait(false);
        return r.Ok ? (ParseMe(r.Body), SpotifyError.None) : (null, r.Error);
    }

    public async Task<(SpotifyTrack? Track, SpotifyError Error)> GetCurrentlyPlayingAsync()
    {
        var r = await SendAsync(HttpMethod.Get, "/me/player/currently-playing").ConfigureAwait(false);
        if (!r.Ok) return (null, r.Error);
        return (r.Status == 204 ? null : ParseCurrentlyPlaying(r.Body), SpotifyError.None);
    }

    /// <summary>GET /me/library/contains (Feb 2026 API); falls back to /me/tracks/contains.</summary>
    public async Task<bool?> IsSavedAsync(SpotifyTrack t)
    {
        var r = await SendAsync(HttpMethod.Get, "/me/library/contains?uris=" + Uri.EscapeDataString(t.Uri)).ConfigureAwait(false);
        if (r.Error == SpotifyError.NotFound && t.Id != null)
            r = await SendAsync(HttpMethod.Get, "/me/tracks/contains?ids=" + Uri.EscapeDataString(t.Id)).ConfigureAwait(false);
        return r.Ok ? ParseContains(r.Body) : null;
    }

    /// <summary>PUT/DELETE /me/library?uris= (Feb 2026 API); falls back to /me/tracks?ids=.</summary>
    public async Task<SpotifyError> SetSavedAsync(SpotifyTrack t, bool save)
    {
        var m = save ? HttpMethod.Put : HttpMethod.Delete;
        var r = await SendAsync(m, "/me/library?uris=" + Uri.EscapeDataString(t.Uri)).ConfigureAwait(false);
        if (r.Error == SpotifyError.NotFound && t.Id != null)
            r = await SendAsync(m, "/me/tracks?ids=" + Uri.EscapeDataString(t.Id)).ConfigureAwait(false);
        return r.Error;
    }

    /// <summary>The user's playlists they own or collaborate on, up to 200 scanned.</summary>
    public async Task<(List<SpotifyPlaylist>? List, SpotifyError Error)> GetEditablePlaylistsAsync(string meId)
    {
        var all = new List<SpotifyPlaylist>();
        for (int offset = 0; offset < 200; offset += 50)
        {
            var r = await SendAsync(HttpMethod.Get, $"/me/playlists?limit=50&offset={offset}").ConfigureAwait(false);
            if (!r.Ok) return all.Count > 0 ? (all, SpotifyError.None) : (null, r.Error);
            var page = ParsePlaylists(r.Body, out bool more);
            all.AddRange(page.Where(p => p.Collaborative || string.Equals(p.OwnerId, meId, StringComparison.Ordinal)));
            if (!more) break;
        }
        return (all, SpotifyError.None);
    }

    /// <summary>POST /playlists/{id}/items (Feb 2026 API); falls back to /tracks.</summary>
    public async Task<SpotifyError> AddToPlaylistAsync(string playlistId, string uri)
    {
        string body = JsonSerializer.Serialize(new { uris = new[] { uri } });
        string id = Uri.EscapeDataString(playlistId);
        var r = await SendAsync(HttpMethod.Post, $"/playlists/{id}/items", body).ConfigureAwait(false);
        if (r.Error == SpotifyError.NotFound)
            r = await SendAsync(HttpMethod.Post, $"/playlists/{id}/tracks", body).ConfigureAwait(false);
        return r.Error;
    }

    public async Task<(List<SpotifyQueueEntry>? List, SpotifyError Error)> GetQueueAsync()
    {
        var r = await SendAsync(HttpMethod.Get, "/me/player/queue").ConfigureAwait(false);
        return r.Ok ? (ParseQueue(r.Body, 5), SpotifyError.None) : (null, r.Error);
    }

    public async Task<(List<SpotifyTrack>? List, SpotifyError Error)> SearchAsync(string query)
    {
        var r = await SendAsync(HttpMethod.Get, "/search?type=track&limit=6&q=" + Uri.EscapeDataString(query)).ConfigureAwait(false);
        return r.Ok ? (ParseSearch(r.Body), SpotifyError.None) : (null, r.Error);
    }

    public async Task<SpotifyError> PlayAsync(string uri)
    {
        var r = await SendAsync(HttpMethod.Put, "/me/player/play", JsonSerializer.Serialize(new { uris = new[] { uri } })).ConfigureAwait(false);
        return r.Error;
    }

    public async Task<SpotifyError> EnqueueAsync(string uri)
    {
        var r = await SendAsync(HttpMethod.Post, "/me/player/queue?uri=" + Uri.EscapeDataString(uri)).ConfigureAwait(false);
        return r.Error;
    }

    /// <summary>Album art from Spotify's CDN, for the tiny covers in the search results.</summary>
    public static async Task<byte[]?> DownloadImageAsync(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || u.Scheme != Uri.UriSchemeHttps) return null;
        try { return await Http.GetByteArrayAsync(u).ConfigureAwait(false); }
        catch { return null; }
    }

    // ---------- parsing (pure, tested) ----------

    internal static (string Access, int ExpiresIn, string? Refresh)? ParseTokens(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            string? access = Str(root, "access_token");
            if (string.IsNullOrEmpty(access)) return null;
            int exp = root.TryGetProperty("expires_in", out var e) && e.ValueKind == JsonValueKind.Number ? e.GetInt32() : 3600;
            return (access, exp, Str(root, "refresh_token"));
        }
        catch { return null; }
    }

    internal static SpotifyMe? ParseMe(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            string? id = Str(doc.RootElement, "id");
            if (string.IsNullOrEmpty(id)) return null;
            string? name = Str(doc.RootElement, "display_name");
            return new SpotifyMe(id, string.IsNullOrWhiteSpace(name) ? id : name);
        }
        catch { return null; }
    }

    internal static SpotifyTrack? ParseCurrentlyPlaying(string json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (Str(root, "currently_playing_type") is { } type && type != "track") return null;
            return root.TryGetProperty("item", out var item) ? ParseTrack(item) : null;
        }
        catch { return null; }
    }

    internal static List<SpotifyQueueEntry> ParseQueue(string json, int max)
    {
        var list = new List<SpotifyQueueEntry>();
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("queue", out var q) || q.ValueKind != JsonValueKind.Array) return list;
            foreach (var it in q.EnumerateArray())
            {
                if (list.Count >= max) break;
                string? name = Str(it, "name");
                if (string.IsNullOrWhiteSpace(name)) continue;
                string artist = Artists(it);
                if (artist.Length == 0 && it.TryGetProperty("show", out var show)) artist = Str(show, "name") ?? "";
                list.Add(new SpotifyQueueEntry(name, artist));
            }
        }
        catch { }
        return list;
    }

    internal static List<SpotifyPlaylist> ParsePlaylists(string json, out bool more)
    {
        var list = new List<SpotifyPlaylist>();
        more = false;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            more = root.TryGetProperty("next", out var n) && n.ValueKind == JsonValueKind.String;
            if (!root.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array) return list;
            foreach (var p in items.EnumerateArray())
            {
                if (p.ValueKind != JsonValueKind.Object) continue;
                string? id = Str(p, "id");
                if (string.IsNullOrEmpty(id)) continue;
                string owner = p.TryGetProperty("owner", out var o) ? Str(o, "id") ?? "" : "";
                bool collab = p.TryGetProperty("collaborative", out var c) && c.ValueKind == JsonValueKind.True;
                // Feb 2026 renamed "tracks" to "items"; read whichever is there.
                int count = 0;
                if ((p.TryGetProperty("items", out var t) || p.TryGetProperty("tracks", out t))
                    && t.ValueKind == JsonValueKind.Object && t.TryGetProperty("total", out var tot) && tot.ValueKind == JsonValueKind.Number)
                    count = tot.GetInt32();
                list.Add(new SpotifyPlaylist(id, Str(p, "name") ?? "", count, owner, collab));
            }
        }
        catch { }
        return list;
    }

    internal static List<SpotifyTrack> ParseSearch(string json)
    {
        var list = new List<SpotifyTrack>();
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("tracks", out var tracks) || !tracks.TryGetProperty("items", out var items)
                || items.ValueKind != JsonValueKind.Array) return list;
            foreach (var it in items.EnumerateArray())
                if (ParseTrack(it) is { } t) list.Add(t);
        }
        catch { }
        return list;
    }

    internal static bool? ParseContains(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Array && root.GetArrayLength() > 0)
            {
                var first = root[0];
                if (first.ValueKind is JsonValueKind.True or JsonValueKind.False) return first.GetBoolean();
            }
        }
        catch { }
        return null;
    }

    internal static bool IsPremiumRequired(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.Object
                   && Str(e, "reason") == "PREMIUM_REQUIRED";
        }
        catch { return false; }
    }

    private static SpotifyTrack? ParseTrack(JsonElement it)
    {
        if (it.ValueKind != JsonValueKind.Object) return null;
        if (Str(it, "type") is { } type && type != "track") return null;
        string? uri = Str(it, "uri");
        string? name = Str(it, "name");
        if (string.IsNullOrEmpty(uri) || name == null) return null;
        bool local = it.TryGetProperty("is_local", out var l) && l.ValueKind == JsonValueKind.True;
        string? id = local ? null : Str(it, "id");
        string? image = null;
        if (it.TryGetProperty("album", out var album) && album.TryGetProperty("images", out var imgs) && imgs.ValueKind == JsonValueKind.Array)
        {
            // Smallest image that is still at least 48 px (Spotify lists them large → small).
            int best = int.MaxValue;
            foreach (var img in imgs.EnumerateArray())
            {
                string? url = Str(img, "url");
                if (url == null) continue;
                int w = img.TryGetProperty("width", out var wv) && wv.ValueKind == JsonValueKind.Number ? wv.GetInt32() : 300;
                if (w >= 48 && w < best) { best = w; image = url; }
                image ??= url;
            }
        }
        return new SpotifyTrack(id, uri, name, Artists(it), image);
    }

    private static string Artists(JsonElement it)
    {
        if (!it.TryGetProperty("artists", out var a) || a.ValueKind != JsonValueKind.Array) return "";
        var names = new List<string>();
        foreach (var x in a.EnumerateArray())
            if (Str(x, "name") is { Length: > 0 } n) names.Add(n);
        return string.Join(", ", names);
    }

    private static string? Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
