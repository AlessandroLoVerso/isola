using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Isola.Modules.Music;

/// <summary>Authorization Code with PKCE (no client secret): verifier, challenge, state, URLs.</summary>
internal static class SpotifyPkce
{
    public const string RedirectUri = "http://127.0.0.1:47322/callback";
    public const string ListenerPrefix = "http://127.0.0.1:47322/callback/";
    public const string Scopes =
        "user-read-playback-state user-modify-playback-state user-read-currently-playing " +
        "user-library-read user-library-modify playlist-read-private playlist-read-collaborative " +
        "playlist-modify-private playlist-modify-public";

    private static readonly Regex ClientIdShape = new("^[0-9a-fA-F]{32}$", RegexOptions.Compiled);

    public static bool IsValidClientId(string? id) => id != null && ClientIdShape.IsMatch(id);

    /// <summary>64 random bytes → 86 base64url chars (RFC 7636 allows 43–128).</summary>
    public static string CreateVerifier() => Base64Url(RandomNumberGenerator.GetBytes(64));

    /// <summary>S256: base64url(SHA256(ASCII(verifier))), no padding.</summary>
    public static string Challenge(string verifier) => Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));

    public static string CreateState() => Base64Url(RandomNumberGenerator.GetBytes(24));

    /// <summary>Constant-time comparison of the state we sent with the one that came back.</summary>
    public static bool StateMatches(string expected, string? actual)
    {
        if (string.IsNullOrEmpty(expected) || string.IsNullOrEmpty(actual)) return false;
        return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(actual));
    }

    public static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static string AuthorizeUrl(string clientId, string challenge, string state) =>
        "https://accounts.spotify.com/authorize?response_type=code"
        + "&client_id=" + Uri.EscapeDataString(clientId)
        + "&scope=" + Uri.EscapeDataString(Scopes)
        + "&redirect_uri=" + Uri.EscapeDataString(RedirectUri)
        + "&code_challenge_method=S256"
        + "&code_challenge=" + Uri.EscapeDataString(challenge)
        + "&state=" + Uri.EscapeDataString(state);

    /// <summary>Minimal query parser for the callback (?code=…&amp;state=… or ?error=…).</summary>
    public static Dictionary<string, string> ParseQuery(string? query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (string.IsNullOrEmpty(query)) return result;
        foreach (var part in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = part.IndexOf('=');
            string k = Uri.UnescapeDataString((eq < 0 ? part : part[..eq]).Replace('+', ' '));
            string v = eq < 0 ? "" : Uri.UnescapeDataString(part[(eq + 1)..].Replace('+', ' '));
            result.TryAdd(k, v);
        }
        return result;
    }
}

internal enum LoginOutcome { Code, Denied, PortBusy, Timeout, Cancelled, Failed }

internal readonly record struct LoginResult(LoginOutcome Outcome, string? Code = null, string? Verifier = null);

/// <summary>One login: opens the browser on the authorize page and waits (max 5 min) for the
/// redirect on a temporary loopback HttpListener. The listener exists only during this call.</summary>
internal static class SpotifyLogin
{
    private static readonly TimeSpan MaxWait = TimeSpan.FromMinutes(5);

    public static Task<LoginResult> RunAsync(string clientId, CancellationToken ct) =>
        RunAsync(clientId, url => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose(), ct);

    /// <summary><paramref name="openBrowser"/> receives the authorize URL (the default browser in the app).</summary>
    internal static async Task<LoginResult> RunAsync(string clientId, Action<string> openBrowser, CancellationToken ct)
    {
        string verifier = SpotifyPkce.CreateVerifier();
        string state = SpotifyPkce.CreateState();
        string url = SpotifyPkce.AuthorizeUrl(clientId, SpotifyPkce.Challenge(verifier), state);

        using var listener = new HttpListener();
        listener.Prefixes.Add(SpotifyPkce.ListenerPrefix);
        try { listener.Start(); }
        catch (HttpListenerException) { return new(LoginOutcome.PortBusy); }

        try
        {
            openBrowser(url);
        }
        catch { return new(LoginOutcome.Failed); }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(MaxWait);
        // GetContextAsync ignores tokens: stopping the listener ends the pending wait.
        using var reg = timeout.Token.Register(() => { try { listener.Stop(); } catch { } });

        while (!timeout.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await listener.GetContextAsync().ConfigureAwait(false); }
            catch
            {
                if (ct.IsCancellationRequested) return new(LoginOutcome.Cancelled);
                return new(timeout.IsCancellationRequested ? LoginOutcome.Timeout : LoginOutcome.Failed);
            }

            try
            {
                var req = ctx.Request;
                if (!IPAddress.IsLoopback(req.RemoteEndPoint.Address)
                    || !string.Equals(req.Url?.AbsolutePath.TrimEnd('/'), "/callback", StringComparison.Ordinal))
                {
                    Respond(ctx, 404, "Pagina non trovata", "");
                    continue;
                }
                var q = SpotifyPkce.ParseQuery(req.Url?.Query);
                q.TryGetValue("state", out var gotState);
                if (!SpotifyPkce.StateMatches(state, gotState))
                {
                    // Not our request (or a forged one): ignore it and keep waiting for the real one.
                    Respond(ctx, 400, "Richiesta non valida", "Torna su Isola e riprova a collegare Spotify.");
                    continue;
                }
                if (q.TryGetValue("error", out _))
                {
                    Respond(ctx, 200, "Accesso annullato", "Spotify non è stato collegato. Puoi chiudere questa scheda.");
                    return new(LoginOutcome.Denied);
                }
                if (q.TryGetValue("code", out var code) && code.Length > 0)
                {
                    Respond(ctx, 200, "Spotify collegato, puoi chiudere questa scheda", "Torna pure su Isola.");
                    return new(LoginOutcome.Code, code, verifier);
                }
                Respond(ctx, 400, "Richiesta non valida", "Torna su Isola e riprova a collegare Spotify.");
            }
            catch { /* a broken request must not end the login */ }
        }
        return new(ct.IsCancellationRequested ? LoginOutcome.Cancelled : LoginOutcome.Timeout);
    }

    private static void Respond(HttpListenerContext ctx, int status, string title, string text)
    {
        string html = "<!doctype html><html lang=\"it\"><head><meta charset=\"utf-8\"><title>Isola</title>"
            + "<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;"
            + "background:#0b0b0d;color:#f2f2f5;font-family:'Segoe UI Variable Text','Segoe UI',sans-serif}"
            + "div{text-align:center}h1{font-size:20px;font-weight:600;margin:0 0 8px}p{color:#9a9aa3;font-size:14px;margin:0}</style>"
            + "</head><body><div><h1>" + WebUtility.HtmlEncode(title) + "</h1><p>" + WebUtility.HtmlEncode(text) + "</p></div></body></html>";
        byte[] bytes = Encoding.UTF8.GetBytes(html);
        var resp = ctx.Response;
        resp.StatusCode = status;
        resp.ContentType = "text/html; charset=utf-8";
        resp.Headers["Cache-Control"] = "no-store";
        resp.ContentLength64 = bytes.Length;
        resp.OutputStream.Write(bytes, 0, bytes.Length);
        resp.Close();
    }
}

/// <summary>The client id used at login plus the refresh token, stored only encrypted with DPAPI
/// (CurrentUser) in data\music\spotify.bin. The access token never touches the disk.</summary>
internal sealed class SpotifyTokenStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Isola.Music.Spotify.v1");
    private readonly string _path;

    public SpotifyTokenStore(string dataDirectory) => _path = Path.Combine(dataDirectory, "spotify.bin");

    internal sealed record Credentials(string ClientId, string RefreshToken);

    public Credentials? Load()
    {
        try
        {
            if (!File.Exists(_path)) return null;
            return Unprotect(File.ReadAllBytes(_path));
        }
        catch { return null; }
    }

    public void Save(Credentials c)
    {
        byte[] data = Protect(c);
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        string tmp = _path + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, _path, overwrite: true);
    }

    public void Delete()
    {
        try { File.Delete(_path); } catch { }
        try { File.Delete(_path + ".tmp"); } catch { }
    }

    internal static byte[] Protect(Credentials c)
    {
        byte[] plain = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string> { ["c"] = c.ClientId, ["r"] = c.RefreshToken });
        try { return ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    internal static Credentials? Unprotect(byte[] data)
    {
        byte[] plain = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
        try
        {
            var d = JsonSerializer.Deserialize<Dictionary<string, string>>(plain);
            if (d == null || !d.TryGetValue("c", out var c) || !d.TryGetValue("r", out var r) || c.Length == 0 || r.Length == 0) return null;
            return new Credentials(c, r);
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
}
