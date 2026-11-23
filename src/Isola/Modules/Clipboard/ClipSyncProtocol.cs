using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

// Test harnesses (never shipped) may reach the internal test hooks of the sync code.
[assembly: InternalsVisibleTo("Isola.Tests")]

namespace Isola.Modules.Clipboard;

internal enum ClipSyncKind { Text, Image }

/// <summary>One clip on the wire (POST /clip), already validated.</summary>
internal sealed class ClipPayload
{
    public required string Id { get; init; }
    public required string From { get; init; }
    public required long Ts { get; init; }
    public required ClipSyncKind Kind { get; init; }
    /// <summary>Text with "\n" line endings (wire form).</summary>
    public string? Text { get; init; }
    public byte[]? Png { get; init; }
}

/// <summary>The "ponte" v1 protocol of docs/appunti-condivisi.md: constants, pairing key, signature,
/// JSON body, Tailscale address checks. Pure functions, no I/O except the interface lookup.</summary>
internal static class ClipSyncProtocol
{
    public const int Version = 1;
    public const int Port = 47323;
    public const string AppName = "isola-windows";

    /// <summary>Pairing key: 20 random bytes = 32 base32 characters = 8 groups of 4.</summary>
    public const int KeyBytes = 20;
    public const int KeyChars = 32;

    public const int MaxTextChars = 1_000_000;          // UTF-16 code units, wire form ("\n")
    public const int MaxPngBytes = 10 * 1024 * 1024;     // decoded PNG
    public const int MaxBodyBytes = 14 * 1024 * 1024;    // whole JSON body (10 MiB PNG in base64 + JSON)
    public const int MaxHeaderBytes = 16 * 1024;         // request line + headers
    public const int MaxIdChars = 64;
    public const int MaxFromChars = 64;
    public const long MaxSkewMs = 5 * 60 * 1000;
    public const int RememberedIds = 200;

    public const string TsHeader = "X-Isola-Ts";
    public const string SigHeader = "X-Isola-Sig";

    private const string Base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    // ---- Pairing key ---------------------------------------------------------------------

    public static byte[] GenerateKey() => RandomNumberGenerator.GetBytes(KeyBytes);

    /// <summary>"ABCD-EFGH-..." (8 groups of 4, RFC 4648 base32, no padding).</summary>
    public static string FormatKey(byte[] key)
    {
        var s = Base32Encode(key);
        var sb = new StringBuilder(s.Length + s.Length / 4);
        for (int i = 0; i < s.Length; i++)
        {
            if (i > 0 && i % 4 == 0) sb.Append('-');
            sb.Append(s[i]);
        }
        return sb.ToString();
    }

    /// <summary>Accepts the key as typed or pasted: case, spaces and dashes don't matter.
    /// Returns null unless it is exactly 32 base32 characters.</summary>
    public static byte[]? ParseKey(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var sb = new StringBuilder(KeyChars);
        foreach (var c in text)
        {
            if (c is '-' or ' ' or '\t' or '\r' or '\n' or ' ') continue;
            sb.Append(char.ToUpperInvariant(c));
        }
        if (sb.Length != KeyChars) return null;
        return Base32Decode(sb.ToString());
    }

    public static string Base32Encode(byte[] data)
    {
        var sb = new StringBuilder((data.Length * 8 + 4) / 5);
        int buffer = 0, bits = 0;
        foreach (var b in data)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                sb.Append(Base32Alphabet[(buffer >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }
        if (bits > 0) sb.Append(Base32Alphabet[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }

    /// <summary>Strict RFC 4648 base32 (uppercase, no padding). Null on any other character.</summary>
    public static byte[]? Base32Decode(string s)
    {
        var bytes = new List<byte>(s.Length * 5 / 8);
        int buffer = 0, bits = 0;
        foreach (var c in s)
        {
            int v = Base32Alphabet.IndexOf(c);
            if (v < 0) return null;
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8)
            {
                bytes.Add((byte)(buffer >> (bits - 8)));
                bits -= 8;
            }
            buffer &= (1 << bits) - 1;
        }
        return bytes.ToArray();
    }

    // ---- Signature -----------------------------------------------------------------------

    /// <summary>Lowercase hex HMAC-SHA256 of ASCII(ts) + "\n" + body.</summary>
    public static string Sign(byte[] key, string ts, ReadOnlySpan<byte> body)
        => Convert.ToHexStringLower(Mac(key, ts, body));

    private static byte[] Mac(byte[] key, string ts, ReadOnlySpan<byte> body)
    {
        using var h = IncrementalHash.CreateHMAC(HashAlgorithmName.SHA256, key);
        h.AppendData(Encoding.ASCII.GetBytes(ts));
        h.AppendData("\n"u8);
        h.AppendData(body);
        return h.GetHashAndReset();
    }

    /// <summary>Constant-time check of the X-Isola-Sig header (hex, either case).</summary>
    public static bool Verify(byte[] key, string ts, ReadOnlySpan<byte> body, string? sigHex)
    {
        if (sigHex == null || sigHex.Length != 64) return false;
        byte[] given;
        try { given = Convert.FromHexString(sigHex); }
        catch (FormatException) { return false; }
        return CryptographicOperations.FixedTimeEquals(Mac(key, ts, body), given);
    }

    /// <summary>The ts header must be plain decimal digits (no sign, no spaces).</summary>
    public static bool TryParseTs(string? s, out long ts)
    {
        ts = 0;
        if (string.IsNullOrEmpty(s) || s.Length > 16) return false;
        foreach (var c in s) if (c is < '0' or > '9') return false;
        return long.TryParse(s, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out ts);
    }

    public static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public static bool TsInWindow(long ts, long nowMs) => Math.Abs(nowMs - ts) <= MaxSkewMs;

    // ---- Body ----------------------------------------------------------------------------

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = false,
        // Keep non-ASCII as UTF-8 (smaller body). Still valid JSON for any parser.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string NewId() => Guid.NewGuid().ToString("D"); // lowercase, with dashes

    /// <summary>Compact JSON, keys in this order: v, id, from, ts, kind, text|png.</summary>
    public static byte[] BuildClipBody(string id, string from, long ts, ClipSyncKind kind, string? text, byte[]? png)
    {
        using var ms = new MemoryStream(kind == ClipSyncKind.Image ? (png?.Length ?? 0) * 4 / 3 + 256 : (text?.Length ?? 0) + 256);
        using (var w = new Utf8JsonWriter(ms, WriterOptions))
        {
            w.WriteStartObject();
            w.WriteNumber("v", Version);
            w.WriteString("id", id);
            w.WriteString("from", from);
            w.WriteNumber("ts", ts);
            if (kind == ClipSyncKind.Text)
            {
                w.WriteString("kind", "text");
                w.WriteString("text", text ?? "");
            }
            else
            {
                w.WriteString("kind", "image");
                w.WriteBase64String("png", png ?? Array.Empty<byte>());
            }
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    public static byte[] BuildPingResponse(string name)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, WriterOptions))
        {
            w.WriteStartObject();
            w.WriteNumber("v", Version);
            w.WriteString("name", name);
            w.WriteString("app", AppName);
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    public enum ParseError { None, BadJson, TooLarge }

    /// <summary>Parses and validates a POST /clip body. TooLarge = text or PNG over the limits.</summary>
    public static ParseError TryParseClip(byte[] body, out ClipPayload? payload)
    {
        payload = null;
        try
        {
            using var doc = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 8 });
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return ParseError.BadJson;
            if (!root.TryGetProperty("v", out var v) || v.ValueKind != JsonValueKind.Number || !v.TryGetInt32(out var ver) || ver != Version) return ParseError.BadJson;
            if (!root.TryGetProperty("id", out var idEl) || idEl.ValueKind != JsonValueKind.String) return ParseError.BadJson;
            var id = idEl.GetString() ?? "";
            if (id.Length == 0 || id.Length > MaxIdChars) return ParseError.BadJson;
            if (!root.TryGetProperty("ts", out var tsEl) || tsEl.ValueKind != JsonValueKind.Number || !tsEl.TryGetInt64(out var ts)) return ParseError.BadJson;
            string from = "";
            if (root.TryGetProperty("from", out var fromEl))
            {
                if (fromEl.ValueKind != JsonValueKind.String) return ParseError.BadJson;
                from = CleanName(fromEl.GetString());
            }
            if (!root.TryGetProperty("kind", out var kindEl) || kindEl.ValueKind != JsonValueKind.String) return ParseError.BadJson;
            switch (kindEl.GetString())
            {
                case "text":
                {
                    if (!root.TryGetProperty("text", out var t) || t.ValueKind != JsonValueKind.String) return ParseError.BadJson;
                    var text = t.GetString() ?? "";
                    if (text.Length > MaxTextChars) return ParseError.TooLarge;
                    if (text.Length == 0) return ParseError.BadJson;
                    payload = new ClipPayload { Id = id, From = from, Ts = ts, Kind = ClipSyncKind.Text, Text = text };
                    return ParseError.None;
                }
                case "image":
                {
                    if (!root.TryGetProperty("png", out var p) || p.ValueKind != JsonValueKind.String) return ParseError.BadJson;
                    // The body limit already bounds the decoded size (14 MiB of base64 ≈ 10.5 MiB).
                    if (!p.TryGetBytesFromBase64(out var png) || png == null) return ParseError.BadJson;
                    if (png.Length > MaxPngBytes) return ParseError.TooLarge;
                    if (!IsPng(png)) return ParseError.BadJson;
                    payload = new ClipPayload { Id = id, From = from, Ts = ts, Kind = ClipSyncKind.Image, Png = png };
                    return ParseError.None;
                }
                default:
                    return ParseError.BadJson;
            }
        }
        catch (JsonException) { return ParseError.BadJson; }
        catch (ArgumentException) { return ParseError.BadJson; } // invalid UTF-8 surrogates etc.
        catch (InvalidOperationException) { return ParseError.BadJson; } // lone surrogates in a string
    }

    public static bool IsPng(ReadOnlySpan<byte> b)
        => b.Length > 8 && b[..8].SequenceEqual(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

    /// <summary>Display name of a computer: no control characters, at most 64 characters.</summary>
    public static string CleanName(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return "";
        var sb = new StringBuilder(Math.Min(s.Length, MaxFromChars));
        foreach (var c in s)
        {
            if (char.IsControl(c)) continue;
            sb.Append(c);
            if (sb.Length >= MaxFromChars) break;
        }
        return sb.ToString().Trim();
    }

    /// <summary>"dal MacBook Air", "dall'iMac", "dall'altro computer".</summary>
    public static string FromLabel(string? from)
    {
        if (string.IsNullOrWhiteSpace(from)) return "dall'altro computer";
        return "aeiouAEIOU".Contains(from[0]) ? "dall'" + from : "dal " + from;
    }

    /// <summary>This PC's name as the other computer will show it ("dal &lt;nome&gt;").</summary>
    public static string LocalName()
    {
        try { var n = CleanName(Dns.GetHostName()); if (n.Length > 0) return n; } catch { }
        return CleanName(Environment.MachineName);
    }

    // ---- Line endings --------------------------------------------------------------------

    /// <summary>Windows clipboard text → wire text ("\n" only).</summary>
    public static string ToWire(string text) => text.Replace("\r\n", "\n");

    /// <summary>Wire text → Windows clipboard text ("\r\n").</summary>
    public static string FromWire(string text) => text.Replace("\r\n", "\n").Replace("\n", "\r\n");

    // ---- Tailscale addresses -------------------------------------------------------------

    /// <summary>100.64.0.0/10 (Tailscale IPv4) or fd7a:115c:a1e0::/48 (Tailscale IPv6).</summary>
    public static bool IsTailscale(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        var b = ip.GetAddressBytes();
        if (ip.AddressFamily == AddressFamily.InterNetwork) return b[0] == 100 && (b[1] & 0xC0) == 64;
        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
            return b[0] == 0xFD && b[1] == 0x7A && b[2] == 0x11 && b[3] == 0x5C && b[4] == 0xA1 && b[5] == 0xE0;
        return false;
    }

    /// <summary>The IPv4 address of the Tailscale adapter (100.64.0.0/10), or null if Tailscale is
    /// not running/connected.</summary>
    public static IPAddress? FindLocalTailscaleIPv4()
    {
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (!nic.Description.Contains("Tailscale", StringComparison.OrdinalIgnoreCase)
                    && !nic.Name.Contains("Tailscale", StringComparison.OrdinalIgnoreCase)) continue;
                foreach (var ua in nic.GetIPProperties().UnicastAddresses)
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork && IsTailscale(ua.Address)) return ua.Address;
            }
        }
        catch (NetworkInformationException) { }
        return null;
    }
}
