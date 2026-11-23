using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text.Json;

namespace Isola.Modules.Clipboard;

internal enum ClipSyncResult
{
    Ok,
    /// <summary>Name not found, not a Tailscale address, refused, timed out.</summary>
    Unreachable,
    /// <summary>401: different pairing key (or clocks more than 5 minutes apart).</summary>
    WrongKey,
    /// <summary>503: the other computer has sharing paused (or is busy).</summary>
    Refused,
    /// <summary>Any other answer (400, 413, 404...).</summary>
    Error,
    /// <summary>The name resolves to this PC.</summary>
    Self,
}

/// <summary>The sending side: one attempt, 3 s to resolve and connect (plus 1 s per MiB of body),
/// no retries, no queue. Only Tailscale addresses are ever contacted.</summary>
internal static class ClipSyncClient
{
    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        UseProxy = false,                 // a system proxy must never see the clipboard
        AllowAutoRedirect = false,
        UseCookies = false,
        ConnectTimeout = TimeSpan.FromSeconds(3),
        PooledConnectionLifetime = TimeSpan.FromSeconds(30),
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    private static readonly TimeSpan Budget = TimeSpan.FromSeconds(3);

    /// <summary>MagicDNS name or 100.x address → a Tailscale address (IPv4 first), or null.
    /// allowLoopbackForTests lets the test harness target 127.0.0.1.</summary>
    internal static async Task<IPAddress?> ResolveAsync(string peer, CancellationToken ct, bool allowLoopbackForTests = false)
    {
        peer = peer.Trim();
        if (peer.Length == 0) return null;
        bool Ok(IPAddress ip) => ClipSyncProtocol.IsTailscale(ip) || (allowLoopbackForTests && IPAddress.IsLoopback(ip));
        if (IPAddress.TryParse(peer.Trim('[', ']'), out var literal)) return Ok(literal) ? literal : null;
        try
        {
            var all = await Dns.GetHostAddressesAsync(peer, ct).ConfigureAwait(false);
            return all.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && Ok(a))
                   ?? all.FirstOrDefault(Ok);
        }
        catch (Exception) { return null; }
    }

    private static Uri UriFor(IPAddress ip, int port, string path)
        => new($"http://{(ip.AddressFamily == AddressFamily.InterNetworkV6 ? "[" + ip + "]" : ip.ToString())}:{port}{path}");

    private static HttpRequestMessage Signed(HttpMethod method, Uri uri, byte[] key, byte[] body, long ts)
    {
        var tsText = ts.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var req = new HttpRequestMessage(method, uri) { Version = HttpVersion.Version11, VersionPolicy = HttpVersionPolicy.RequestVersionExact };
        req.Headers.ConnectionClose = true;
        req.Headers.ExpectContinue = false;
        req.Headers.TryAddWithoutValidation(ClipSyncProtocol.TsHeader, tsText);
        req.Headers.TryAddWithoutValidation(ClipSyncProtocol.SigHeader, ClipSyncProtocol.Sign(key, tsText, body));
        if (method == HttpMethod.Post)
        {
            var content = new ByteArrayContent(body);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/json") { CharSet = "utf-8" };
            content.Headers.ContentLength = body.Length;
            req.Content = content;
        }
        return req;
    }

    private static ClipSyncResult Map(HttpStatusCode code) => (int)code switch
    {
        200 or 204 => ClipSyncResult.Ok,
        401 => ClipSyncResult.WrongKey,
        503 => ClipSyncResult.Refused,
        _ => ClipSyncResult.Error,
    };

    /// <summary>POST /clip with a body built by ClipSyncProtocol.BuildClipBody (ts must match).</summary>
    internal static async Task<ClipSyncResult> SendAsync(string peer, byte[] key, byte[] body, long ts, IPAddress? self,
                                                         CancellationToken ct, int port = ClipSyncProtocol.Port, bool allowLoopbackForTests = false)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(Budget + TimeSpan.FromSeconds(body.Length / (1024.0 * 1024.0)));
        try
        {
            var ip = await ResolveAsync(peer, cts.Token, allowLoopbackForTests).ConfigureAwait(false);
            if (ip == null) return ClipSyncResult.Unreachable;
            if (self != null && ip.Equals(self)) return ClipSyncResult.Self;
            using var req = Signed(HttpMethod.Post, UriFor(ip, port, "/clip"), key, body, ts);
            using var res = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false);
            return Map(res.StatusCode);
        }
        catch (Exception) { return ClipSyncResult.Unreachable; }
    }

    /// <summary>GET /ping. On Ok, name is the other computer's name.</summary>
    internal static async Task<(ClipSyncResult Result, string? Name)> PingAsync(string peer, byte[] key, IPAddress? self,
                                                                               CancellationToken ct, int port = ClipSyncProtocol.Port, bool allowLoopbackForTests = false)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(Budget);
        try
        {
            var ip = await ResolveAsync(peer, cts.Token, allowLoopbackForTests).ConfigureAwait(false);
            if (ip == null) return (ClipSyncResult.Unreachable, null);
            if (self != null && ip.Equals(self)) return (ClipSyncResult.Self, null);
            using var req = Signed(HttpMethod.Get, UriFor(ip, port, "/ping"), key, Array.Empty<byte>(), ClipSyncProtocol.NowMs());
            using var res = await Http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token).ConfigureAwait(false);
            var result = Map(res.StatusCode);
            if (result != ClipSyncResult.Ok) return (result, null);
            var bytes = await res.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
            if (bytes.Length > 4096) return (ClipSyncResult.Error, null);
            using var doc = JsonDocument.Parse(bytes);
            var root = doc.RootElement;
            if (!root.TryGetProperty("v", out var v) || !v.TryGetInt32(out var ver) || ver != ClipSyncProtocol.Version) return (ClipSyncResult.Error, null);
            var name = root.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? ClipSyncProtocol.CleanName(n.GetString()) : "";
            return (ClipSyncResult.Ok, name);
        }
        catch (JsonException) { return (ClipSyncResult.Error, null); }
        catch (Exception) { return (ClipSyncResult.Unreachable, null); }
    }
}
