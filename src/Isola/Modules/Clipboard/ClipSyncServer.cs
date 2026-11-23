using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Isola.Modules.Clipboard;

/// <summary>Where valid incoming clips go. Called on a worker thread.</summary>
internal interface IClipSyncSink
{
    /// <summary>True while "Pausa condivisione" is on: clips are refused with 503.</summary>
    bool ReceivePaused { get; }

    /// <summary>A new (not repeated), signed, valid clip.</summary>
    void Deliver(ClipPayload clip);
}

internal enum ClipSyncTransport { Auto, TcpOnly, HttpListenerOnly }

/// <summary>The listening side of docs/appunti-condivisi.md, bound to one address (this PC's
/// Tailscale IPv4). Tries HttpListener first; a non-admin user has no URL ACL for a specific IP, so
/// that normally fails with "access denied" and a minimal HTTP/1.1 server on a TcpListener takes over
/// (one request per connection, Content-Length bodies only). Both share the same checks: source in
/// 100.64.0.0/10, signature, ±5 min, last 200 ids, size limits, 2 connections, 10 s read timeout.
/// Idle cost: one pending async accept, no timers.</summary>
internal sealed class ClipSyncServer : IDisposable
{
    private const int MaxConnections = 2;

    private readonly IPAddress _bind;
    private readonly int _port;
    private readonly Func<byte[]?> _key;
    private readonly string _name;
    private readonly IClipSyncSink _sink;
    private readonly Action<string>? _log;
    private readonly bool _allowLoopback;
    private readonly ClipSyncTransport _transport;
    private readonly SemaphoreSlim _slots = new(MaxConnections, MaxConnections);
    private readonly CancellationTokenSource _cts = new();
    private readonly object _idsGate = new();
    private readonly Queue<string> _idOrder = new();
    private readonly HashSet<string> _ids = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTime> _lastLog = new();
    private TcpListener? _tcp;
    private HttpListener? _http;
    private int _disposed;

    /// <summary>Per-read timeout (no bytes for this long ⇒ connection closed).</summary>
    internal TimeSpan ReadTimeout { get; set; } = TimeSpan.FromSeconds(10);

    /// <summary>Upper bound for a whole request, however slowly it trickles in.</summary>
    internal TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(60);

    public ClipSyncServer(IPAddress bind, Func<byte[]?> key, string name, IClipSyncSink sink, Action<string>? log)
        : this(bind, ClipSyncProtocol.Port, key, name, sink, log, allowLoopbackForTests: false, ClipSyncTransport.Auto) { }

    /// <summary>Test-only: allowLoopbackForTests also accepts 127.0.0.1 as a source (never set by
    /// the app or the settings), transport forces one implementation, port 0 picks a free port (TCP).</summary>
    internal ClipSyncServer(IPAddress bind, int port, Func<byte[]?> key, string name, IClipSyncSink sink, Action<string>? log,
                            bool allowLoopbackForTests, ClipSyncTransport transport)
    {
        _bind = bind;
        _port = port;
        _key = key;
        _name = name;
        _sink = sink;
        _log = log;
        _allowLoopback = allowLoopbackForTests;
        _transport = transport;
    }

    /// <summary>"HttpListener" or "TcpListener" once started.</summary>
    public string? TransportName { get; private set; }

    public int BoundPort { get; private set; }

    /// <summary>Starts listening. Returns null on success, otherwise a short Italian reason.</summary>
    public string? Start()
    {
        if (_transport != ClipSyncTransport.TcpOnly)
        {
            var http = new HttpListener();
            try
            {
                var host = _bind.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{_bind}]" : _bind.ToString();
                http.Prefixes.Add($"http://{host}:{_port}/");
                http.IgnoreWriteExceptions = true;
                http.Start();
                try
                {
                    var tm = http.TimeoutManager;
                    tm.HeaderWait = ReadTimeout;
                    tm.EntityBody = ReadTimeout;
                    tm.IdleConnection = ReadTimeout;
                    tm.DrainEntityBody = TimeSpan.FromSeconds(2);
                }
                catch (Exception) { /* not supported on every http.sys version: defaults stay */ }
                _http = http;
                TransportName = "HttpListener";
                BoundPort = _port;
                _ = HttpAcceptLoopAsync(http, _cts.Token);
                return null;
            }
            catch (Exception ex) when (ex is HttpListenerException or InvalidOperationException or PlatformNotSupportedException)
            {
                // Typically ERROR_ACCESS_DENIED (5): no URL ACL for http://100.x:47323/ and we are not admin.
                try { http.Close(); } catch { }
                if (_transport == ClipSyncTransport.HttpListenerOnly)
                    return ex is HttpListenerException { ErrorCode: 5 } ? "accesso negato" : "porta occupata";
            }
        }

        try
        {
            var tcp = new TcpListener(_bind, _port);
            tcp.Server.ExclusiveAddressUse = true;
            tcp.Start(8);
            _tcp = tcp;
            TransportName = "TcpListener";
            BoundPort = ((IPEndPoint)tcp.LocalEndpoint).Port;
            _ = TcpAcceptLoopAsync(tcp, _cts.Token);
            return null;
        }
        catch (SocketException ex)
        {
            return ex.SocketErrorCode switch
            {
                SocketError.AddressAlreadyInUse or SocketError.AccessDenied => "porta occupata",
                SocketError.AddressNotAvailable => "indirizzo non disponibile",
                _ => "rete non disponibile",
            };
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _cts.Cancel();
        try { _tcp?.Stop(); } catch { }
        try { _http?.Close(); } catch { }
    }

    // =====================================================================================
    // Shared request logic
    // =====================================================================================

    internal readonly record struct Reply(int Status, byte[]? Json = null);

    private bool SourceAllowed(IPAddress ip)
        => ClipSyncProtocol.IsTailscale(ip) || (_allowLoopback && IPAddress.IsLoopback(ip));

    /// <summary>Checks done before reading the body. Null = go on.</summary>
    private int? PreCheck(IPAddress remote, string method, string path, long? contentLength, bool chunked)
    {
        if (!SourceAllowed(remote)) { LogOnce("origine non ammessa"); return 403; }
        bool clip = path == "/clip", ping = path == "/ping";
        if (!clip && !ping) return 404;
        if (clip && method != "POST") return 405;
        if (ping && method != "GET") return 405;
        if (chunked) return 411;
        if (clip)
        {
            if (contentLength == null) return 411;
            if (contentLength > ClipSyncProtocol.MaxBodyBytes) { LogOnce("troppo grande"); return 413; }
        }
        else if (contentLength is > 0) return 400; // ping has an empty body
        return null;
    }

    private Reply Process(string path, string? tsHeader, string? sigHeader, byte[] body)
    {
        var key = _key();
        if (key == null) { LogOnce("chiave mancante"); return new(401); }
        if (!ClipSyncProtocol.TryParseTs(tsHeader, out var ts) || !ClipSyncProtocol.Verify(key, tsHeader!, body, sigHeader))
        {
            LogOnce("firma non valida");
            return new(401);
        }
        if (!ClipSyncProtocol.TsInWindow(ts, ClipSyncProtocol.NowMs())) { LogOnce("orario fuori tolleranza"); return new(401); }

        if (path == "/ping") return new(200, ClipSyncProtocol.BuildPingResponse(_name));

        switch (ClipSyncProtocol.TryParseClip(body, out var clip))
        {
            case ClipSyncProtocol.ParseError.BadJson: LogOnce("JSON non valido"); return new(400);
            case ClipSyncProtocol.ParseError.TooLarge: LogOnce("troppo grande"); return new(413);
        }
        if (clip!.Ts != ts) { LogOnce("firma non valida"); return new(401); }
        if (_sink.ReceivePaused) return new(503);
        if (!Remember(clip.Id)) return new(204); // already received: ignored
        try { _sink.Deliver(clip); }
        catch (Exception) { LogOnce("consegna non riuscita"); }
        return new(204);
    }

    /// <summary>False if the id was among the last 200.</summary>
    private bool Remember(string id)
    {
        lock (_idsGate)
        {
            if (!_ids.Add(id)) return false;
            _idOrder.Enqueue(id);
            while (_idOrder.Count > ClipSyncProtocol.RememberedIds) _ids.Remove(_idOrder.Dequeue());
            return true;
        }
    }

    /// <summary>"condivisione: errore &lt;motivo&gt;", at most once a minute per reason.</summary>
    private void LogOnce(string reason)
    {
        if (_log == null) return;
        lock (_lastLog)
        {
            var now = DateTime.UtcNow;
            if (_lastLog.TryGetValue(reason, out var last) && now - last < TimeSpan.FromMinutes(1)) return;
            _lastLog[reason] = now;
        }
        try { _log("condivisione: errore " + reason); } catch { }
    }

    private static string Reason(int status) => status switch
    {
        100 => "Continue",
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        411 => "Length Required",
        413 => "Payload Too Large",
        503 => "Service Unavailable",
        _ => "Error",
    };

    // =====================================================================================
    // TcpListener transport (minimal HTTP/1.1, one request per connection)
    // =====================================================================================

    private async Task TcpAcceptLoopAsync(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException)
            {
                // E.g. the Tailscale address went away: back off instead of spinning; the
                // NetworkAddressChanged re-check rebinds or stops this server.
                if (ct.IsCancellationRequested || !await BackOffAsync(ct).ConfigureAwait(false)) break;
                continue;
            }

            if (!_slots.Wait(0))
            {
                _ = RefuseBusyAsync(client);
                continue;
            }
            _ = Task.Run(async () =>
            {
                try { await ServeTcpAsync(client, ct).ConfigureAwait(false); }
                catch (Exception) { /* connection-level problems: nothing to report */ }
                finally
                {
                    try { client.Dispose(); } catch { }
                    _slots.Release();
                }
            });
        }
    }

    /// <summary>One second pause after an accept error. False if the server is stopping.</summary>
    private static async Task<bool> BackOffAsync(CancellationToken ct)
    {
        try { await Task.Delay(1000, ct).ConfigureAwait(false); return true; }
        catch (OperationCanceledException) { return false; }
    }

    private static async Task RefuseBusyAsync(TcpClient client)
    {
        try
        {
            using (client)
            {
                var stream = client.GetStream();
                stream.WriteTimeout = 2000;
                await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")).ConfigureAwait(false);
                client.Client.Shutdown(SocketShutdown.Send);
            }
        }
        catch { }
    }

    private async Task ServeTcpAsync(TcpClient client, CancellationToken serverCt)
    {
        using var whole = CancellationTokenSource.CreateLinkedTokenSource(serverCt);
        whole.CancelAfter(RequestTimeout);
        var ct = whole.Token;
        client.NoDelay = true;
        var remote = ((IPEndPoint)client.Client.RemoteEndPoint!).Address;
        var stream = client.GetStream();

        if (!SourceAllowed(remote))
        {
            LogOnce("origine non ammessa");
            await WriteReplyAsync(client, stream, new Reply(403), ct).ConfigureAwait(false);
            return;
        }

        // ---- Request line + headers
        var buf = new byte[ClipSyncProtocol.MaxHeaderBytes];
        int filled = 0, headerEnd;
        while ((headerEnd = IndexOfCrlfCrlf(buf, filled)) < 0)
        {
            if (filled == buf.Length) { await WriteReplyAsync(client, stream, new Reply(400), ct).ConfigureAwait(false); return; } // headers over 16 KiB
            int r = await ReadAsync(stream, buf.AsMemory(filled), ct).ConfigureAwait(false);
            if (r <= 0) return; // closed or timed out
            filled += r;
        }

        var head = Encoding.Latin1.GetString(buf, 0, headerEnd);
        var lines = head.Split("\r\n");
        var parts = lines[0].Split(' ');
        if (parts.Length != 3 || !parts[2].StartsWith("HTTP/1.", StringComparison.Ordinal))
        {
            await WriteReplyAsync(client, stream, new Reply(400), ct).ConfigureAwait(false);
            return;
        }
        string method = parts[0];
        string target = parts[1];
        int q = target.IndexOf('?');
        string path = q >= 0 ? target[..q] : target;

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 1; i < lines.Length; i++)
        {
            int colon = lines[i].IndexOf(':');
            if (colon <= 0) { await WriteReplyAsync(client, stream, new Reply(400), ct).ConfigureAwait(false); return; }
            var name = lines[i][..colon].Trim();
            var value = lines[i][(colon + 1)..].Trim();
            if (headers.TryGetValue(name, out var existing))
            {
                if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase) && existing != value)
                {
                    await WriteReplyAsync(client, stream, new Reply(400), ct).ConfigureAwait(false);
                    return;
                }
                continue;
            }
            headers[name] = value;
        }

        long? contentLength = null;
        if (headers.TryGetValue("Content-Length", out var clText))
        {
            if (!long.TryParse(clText, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var cl))
            {
                await WriteReplyAsync(client, stream, new Reply(400), ct).ConfigureAwait(false);
                return;
            }
            contentLength = cl;
        }
        bool chunked = headers.ContainsKey("Transfer-Encoding");

        var pre = PreCheck(remote, method, path, contentLength, chunked);
        if (pre != null) { await WriteReplyAsync(client, stream, new Reply(pre.Value), ct).ConfigureAwait(false); return; }

        if (headers.TryGetValue("Expect", out var expect) && expect.Equals("100-continue", StringComparison.OrdinalIgnoreCase) && contentLength > 0)
            await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n"), ct).ConfigureAwait(false);

        // ---- Body
        int length = (int)(contentLength ?? 0);
        var body = new byte[length];
        int have = Math.Min(length, filled - (headerEnd + 4));
        Buffer.BlockCopy(buf, headerEnd + 4, body, 0, have);
        while (have < length)
        {
            int r = await ReadAsync(stream, body.AsMemory(have), ct).ConfigureAwait(false);
            if (r <= 0) return; // closed early or timed out: nothing to answer
            have += r;
        }

        headers.TryGetValue(ClipSyncProtocol.TsHeader, out var ts);
        headers.TryGetValue(ClipSyncProtocol.SigHeader, out var sig);
        var reply = Process(path, ts, sig, body);
        await WriteReplyAsync(client, stream, reply, ct).ConfigureAwait(false);
    }

    /// <summary>One read with the per-read timeout. 0 = closed or timed out.</summary>
    private async Task<int> ReadAsync(NetworkStream stream, Memory<byte> into, CancellationToken ct)
    {
        using var t = CancellationTokenSource.CreateLinkedTokenSource(ct);
        t.CancelAfter(ReadTimeout);
        try { return await stream.ReadAsync(into, t.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return 0; }
        catch (IOException) { return 0; }
    }

    private async Task WriteReplyAsync(TcpClient client, NetworkStream stream, Reply reply, CancellationToken ct)
    {
        var sb = new StringBuilder();
        sb.Append("HTTP/1.1 ").Append(reply.Status).Append(' ').Append(Reason(reply.Status)).Append("\r\n");
        if (reply.Json != null) sb.Append("Content-Type: application/json; charset=utf-8\r\n");
        sb.Append("Content-Length: ").Append(reply.Json?.Length ?? 0).Append("\r\n");
        sb.Append("Connection: close\r\n\r\n");
        var headBytes = Encoding.ASCII.GetBytes(sb.ToString());
        try
        {
            await stream.WriteAsync(headBytes, ct).ConfigureAwait(false);
            if (reply.Json != null) await stream.WriteAsync(reply.Json, ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
            client.Client.Shutdown(SocketShutdown.Send);
            // Graceful close: let the peer read the reply before the socket goes away (closing with
            // unread input would reset the connection and could drop an early 413).
            var sink = new byte[16 * 1024];
            using var drain = CancellationTokenSource.CreateLinkedTokenSource(ct);
            drain.CancelAfter(TimeSpan.FromSeconds(2));
            long drained = 0;
            while (drained < ClipSyncProtocol.MaxBodyBytes)
            {
                int r = await stream.ReadAsync(sink, drain.Token).ConfigureAwait(false);
                if (r <= 0) break;
                drained += r;
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (SocketException) { }
        catch (ObjectDisposedException) { }
    }

    private static int IndexOfCrlfCrlf(byte[] b, int count)
    {
        for (int i = 3; i < count; i++)
            if (b[i] == '\n' && b[i - 1] == '\r' && b[i - 2] == '\n' && b[i - 3] == '\r') return i - 3;
        return -1;
    }

    // =====================================================================================
    // HttpListener transport (only when a URL ACL exists for this address)
    // =====================================================================================

    private async Task HttpAcceptLoopAsync(HttpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await listener.GetContextAsync().ConfigureAwait(false); }
            catch (Exception) when (ct.IsCancellationRequested || !listener.IsListening) { break; }
            catch (HttpListenerException)
            {
                if (!await BackOffAsync(ct).ConfigureAwait(false)) break;
                continue;
            }

            if (!_slots.Wait(0))
            {
                Respond(ctx, new Reply(503));
                continue;
            }
            _ = Task.Run(async () =>
            {
                try { await ServeHttpAsync(ctx, ct).ConfigureAwait(false); }
                catch (Exception) { try { ctx.Response.Abort(); } catch { } }
                finally { _slots.Release(); }
            });
        }
    }

    private async Task ServeHttpAsync(HttpListenerContext ctx, CancellationToken serverCt)
    {
        using var whole = CancellationTokenSource.CreateLinkedTokenSource(serverCt);
        whole.CancelAfter(RequestTimeout);
        var req = ctx.Request;
        var remote = req.RemoteEndPoint?.Address ?? IPAddress.None;
        var raw = req.RawUrl ?? "/";
        int q = raw.IndexOf('?');
        var path = q >= 0 ? raw[..q] : raw;
        long? cl = req.ContentLength64 >= 0 && req.Headers["Content-Length"] != null ? req.ContentLength64 : null;
        bool chunked = req.Headers["Transfer-Encoding"] != null;

        var pre = PreCheck(remote, req.HttpMethod, path, cl, chunked);
        if (pre != null) { Respond(ctx, new Reply(pre.Value)); return; }

        int length = (int)(cl ?? 0);
        var body = new byte[length];
        int have = 0;
        using (var input = req.InputStream)
        {
            while (have < length)
            {
                int r;
                try { r = await input.ReadAsync(body.AsMemory(have), whole.Token).ConfigureAwait(false); }
                catch (Exception) { r = 0; }
                if (r <= 0) { ctx.Response.Abort(); return; }
                have += r;
            }
        }
        Respond(ctx, Process(path, req.Headers[ClipSyncProtocol.TsHeader], req.Headers[ClipSyncProtocol.SigHeader], body));
    }

    private static void Respond(HttpListenerContext ctx, Reply reply)
    {
        try
        {
            var res = ctx.Response;
            res.StatusCode = reply.Status;
            res.KeepAlive = false;
            if (reply.Json != null)
            {
                res.ContentType = "application/json; charset=utf-8";
                res.ContentLength64 = reply.Json.Length;
                res.OutputStream.Write(reply.Json);
            }
            else res.ContentLength64 = 0;
            res.Close();
        }
        catch { try { ctx.Response.Abort(); } catch { } }
    }
}
