using System.Net;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Windows.Threading;
using Isola.Core;

namespace Isola.Modules.Clipboard;

internal enum ClipSyncTone { Neutral, Ok, Error }

/// <summary>"Appunti condivisi" for the Clipboard module: pairing key (DPAPI), listener lifecycle
/// (this PC's Tailscale address, re-checked on NetworkAddressChanged), sending new local items and
/// handing received ones to the module. Public members are called on the UI thread; StatusChanged is
/// raised there. Nothing runs while idle: one pending accept and one system event subscription.</summary>
internal sealed class ClipSync : IClipSyncSink, IDisposable
{
    private static readonly byte[] Entropy = "Isola.Clipboard.Condivisione.v1"u8.ToArray();

    /// <summary>Test harness only: never listen and never touch the network.</summary>
    internal static bool OfflineForTests;

    private readonly IIslandHost _host;
    private readonly string _moduleId;
    private readonly ClipboardSettings _settings;
    private readonly Action _saveSettings;
    private readonly Action<ClipPayload> _onReceived;
    private readonly string _keyFile;
    private readonly string _name = ClipSyncProtocol.LocalName();
    private readonly SemaphoreSlim _listenGate = new(1, 1);
    private readonly CancellationTokenSource _cts = new();
    private readonly object _sendGate = new();
    private volatile byte[]? _key;
    private ClipSyncServer? _server;      // guarded by _listenGate
    private volatile IPAddress? _localIp;
    private bool _networkHooked;
    private int _recheckQueued;
    private Func<(byte[] Body, long Ts)?>? _pending; // latest local item waiting to be sent
    private bool _sending;
    private string? _peerName;
    private int _pingVersion;
    private volatile bool _disposed;

    public ClipSync(IIslandHost host, string moduleId, ClipboardSettings settings, Action saveSettings, Action<ClipPayload> onReceived)
    {
        _host = host;
        _moduleId = moduleId;
        _settings = settings;
        _saveSettings = saveSettings;
        _onReceived = onReceived;
        _keyFile = Path.Combine(host.DataDirectory(moduleId), "condivisione.key");
        _key = LoadKey();
    }

    public bool Enabled => _settings.SyncEnabled;
    public bool Paused => _settings.SyncPaused;
    public string Peer => _settings.SyncPeer ?? "";
    public bool HasKey => _key != null;
    public string? KeyText => _key is { } k ? ClipSyncProtocol.FormatKey(k) : null;

    public string ListenStatus { get; private set; } = "";
    public string PeerStatus { get; private set; } = "";
    public ClipSyncTone PeerTone { get; private set; }

    /// <summary>Raised on the UI thread when ListenStatus or PeerStatus change.</summary>
    public event Action? StatusChanged;

    private bool CanSend => !_disposed && !OfflineForTests && _settings.SyncEnabled && !_settings.SyncPaused
                            && _key != null && !string.IsNullOrWhiteSpace(_settings.SyncPeer);

    // =====================================================================================
    // Lifecycle
    // =====================================================================================

    /// <summary>Starts or stops listening to match the settings.</summary>
    public void Apply()
    {
        if (_disposed) return;
        if (_settings.SyncEnabled)
        {
            if (!_networkHooked)
            {
                NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
                _networkHooked = true;
            }
            SetListenStatus("Cerco Tailscale…");
            _ = Task.Run(RecheckAsync);
        }
        else
        {
            Unhook();
            _ = Task.Run(StopListeningAsync);
            SetListenStatus("Condivisione spenta");
            SetPeerStatus("", ClipSyncTone.Neutral);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Unhook();
        _cts.Cancel();
        _listenGate.Wait();
        try { _server?.Dispose(); _server = null; }
        finally { _listenGate.Release(); }
        StatusChanged = null;
    }

    private void Unhook()
    {
        if (!_networkHooked) return;
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        _networkHooked = false;
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs e)
    {
        // Bursts of events while an adapter comes up: one re-check shortly after the last one starts.
        if (Interlocked.Exchange(ref _recheckQueued, 1) != 0) return;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(800, _cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            Volatile.Write(ref _recheckQueued, 0);
            await RecheckAsync().ConfigureAwait(false);
        });
    }

    private async Task StopListeningAsync()
    {
        await _listenGate.WaitAsync().ConfigureAwait(false);
        try { _server?.Dispose(); _server = null; _localIp = null; }
        finally { _listenGate.Release(); }
    }

    /// <summary>Finds this PC's Tailscale IPv4 and (re)binds the listener to it.</summary>
    private async Task RecheckAsync()
    {
        try { await _listenGate.WaitAsync(_cts.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        try
        {
            if (_disposed || !_settings.SyncEnabled) return;
            if (OfflineForTests) return;
            var ip = ClipSyncProtocol.FindLocalTailscaleIPv4();
            if (ip == null)
            {
                _server?.Dispose();
                _server = null;
                _localIp = null;
                SetListenStatus("Tailscale non attivo");
                return;
            }
            if (_server != null && ip.Equals(_localIp)) return;

            _server?.Dispose();
            _server = null;
            var server = new ClipSyncServer(ip, () => _key, _name, this, m => _host.Log(_moduleId, m));
            var error = server.Start();
            if (error != null)
            {
                server.Dispose();
                _localIp = null;
                _host.Log(_moduleId, "condivisione: errore " + error);
                SetListenStatus(error == "porta occupata" ? $"Porta {ClipSyncProtocol.Port} occupata da un'altra app" : "Non riesco ad ascoltare: " + error);
                return;
            }
            _server = server;
            _localIp = ip;
            SetListenStatus($"Questo PC è {ip} su Tailscale");
        }
        catch (Exception)
        {
            _host.Log(_moduleId, "condivisione: errore avvio non riuscito");
            SetListenStatus("Non riesco ad ascoltare");
        }
        finally { _listenGate.Release(); }
    }

    // =====================================================================================
    // Settings
    // =====================================================================================

    public void SetEnabled(bool on)
    {
        if (_settings.SyncEnabled == on) return;
        _settings.SyncEnabled = on;
        _saveSettings();
        Apply();
    }

    public void SetPaused(bool on)
    {
        if (_settings.SyncPaused == on) return;
        _settings.SyncPaused = on;
        _saveSettings();
    }

    public void SetPeer(string peer)
    {
        peer = peer.Trim();
        if ((_settings.SyncPeer ?? "") == peer) return;
        _settings.SyncPeer = peer;
        _peerName = null;
        _saveSettings();
    }

    /// <summary>New random key, saved. Returns it formatted for display.</summary>
    public string GenerateKey()
    {
        var key = ClipSyncProtocol.GenerateKey();
        SaveKey(key);
        return ClipSyncProtocol.FormatKey(key);
    }

    /// <summary>Saves a typed/pasted key. False if it isn't a valid key.</summary>
    public bool TrySetKey(string text)
    {
        var key = ClipSyncProtocol.ParseKey(text);
        if (key == null) return false;
        if (_key != null && CryptographicOperations.FixedTimeEquals(key, _key)) return true;
        SaveKey(key);
        return true;
    }

    public void ClearKey()
    {
        _key = null;
        try { File.Delete(_keyFile); } catch { }
    }

    private byte[]? LoadKey()
    {
        try
        {
            if (!File.Exists(_keyFile)) return null;
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(_keyFile), Entropy, DataProtectionScope.CurrentUser);
            if (plain.Length == ClipSyncProtocol.KeyBytes) return plain;
            CryptographicOperations.ZeroMemory(plain);
        }
        catch (Exception) { _host.Log(_moduleId, "condivisione: errore chiave illeggibile"); }
        return null;
    }

    private void SaveKey(byte[] key)
    {
        _key = key;
        try
        {
            var data = ProtectedData.Protect(key, Entropy, DataProtectionScope.CurrentUser);
            Directory.CreateDirectory(Path.GetDirectoryName(_keyFile)!);
            var tmp = _keyFile + ".tmp";
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, _keyFile, overwrite: true);
        }
        catch (Exception) { _host.Log(_moduleId, "condivisione: errore chiave non salvata"); }
    }

    // =====================================================================================
    // Status
    // =====================================================================================

    private void SetListenStatus(string text) => OnUi(() =>
    {
        if (ListenStatus == text) return;
        ListenStatus = text;
        StatusChanged?.Invoke();
    });

    private void SetPeerStatus(string text, ClipSyncTone tone) => OnUi(() =>
    {
        if (PeerStatus == text && PeerTone == tone) return;
        PeerStatus = text;
        PeerTone = tone;
        StatusChanged?.Invoke();
    });

    /// <summary>Test harness only.</summary>
    internal void SetStatusForTests(string listen, string peer, ClipSyncTone tone)
    {
        ListenStatus = listen;
        PeerStatus = peer;
        PeerTone = tone;
        StatusChanged?.Invoke();
    }

    private void OnUi(Action a)
    {
        if (_disposed) return;
        var d = _host.Dispatcher;
        if (d.CheckAccess()) a();
        else d.BeginInvoke(DispatcherPriority.Normal, a);
    }

    /// <summary>GET /ping, for the settings page (when it opens and on "Prova").</summary>
    public async Task TestAsync()
    {
        int version = ++_pingVersion;
        var peer = Peer.Trim();
        var key = _key;
        if (peer.Length == 0) { SetPeerStatus("Scrivi il nome dell'altro computer", ClipSyncTone.Neutral); return; }
        if (key == null) { SetPeerStatus("Manca la chiave di abbinamento", ClipSyncTone.Neutral); return; }
        if (OfflineForTests) return;
        SetPeerStatus("Verifico…", ClipSyncTone.Neutral);
        var self = _localIp;
        var (result, name) = await Task.Run(() => ClipSyncClient.PingAsync(peer, key, self, _cts.Token));
        if (version != _pingVersion || _disposed) return; // a newer test is running
        if (result == ClipSyncResult.Ok) _peerName = string.IsNullOrEmpty(name) ? null : name;
        ShowResult(result);
    }

    private void ShowResult(ClipSyncResult result)
    {
        switch (result)
        {
            case ClipSyncResult.Ok:
                SetPeerStatus(_peerName != null ? $"Collegato a {_peerName}" : "Collegato", ClipSyncTone.Ok);
                break;
            case ClipSyncResult.WrongKey:
                SetPeerStatus("Chiave sbagliata", ClipSyncTone.Error);
                break;
            case ClipSyncResult.Refused:
                SetPeerStatus("L'altro computer ha la condivisione in pausa", ClipSyncTone.Neutral);
                break;
            case ClipSyncResult.Self:
                SetPeerStatus("Quel nome è questo PC: scrivi quello dell'altro", ClipSyncTone.Error);
                break;
            case ClipSyncResult.Error:
                SetPeerStatus("Risposta non valida", ClipSyncTone.Error);
                break;
            default:
                SetPeerStatus("Non raggiungibile", ClipSyncTone.Error);
                break;
        }
    }

    // =====================================================================================
    // Sending
    // =====================================================================================

    /// <summary>A new local text was captured (Windows line endings).</summary>
    public void OnLocalText(string text)
    {
        if (!CanSend) return;
        Enqueue(() =>
        {
            var wire = ClipSyncProtocol.ToWire(text);
            if (wire.Length > ClipSyncProtocol.MaxTextChars || wire.Length == 0) { _host.Log(_moduleId, "condivisione: errore troppo grande"); return null; }
            long ts = ClipSyncProtocol.NowMs();
            return (ClipSyncProtocol.BuildClipBody(ClipSyncProtocol.NewId(), _name, ts, ClipSyncKind.Text, wire, null), ts);
        });
    }

    /// <summary>A new local image was captured (the PNG the module stored).</summary>
    public void OnLocalImage(byte[] png)
    {
        if (!CanSend) return;
        if (png.Length > ClipSyncProtocol.MaxPngBytes) { _host.Log(_moduleId, "condivisione: errore troppo grande"); return; }
        Enqueue(() =>
        {
            long ts = ClipSyncProtocol.NowMs();
            return (ClipSyncProtocol.BuildClipBody(ClipSyncProtocol.NewId(), _name, ts, ClipSyncKind.Image, null, png), ts);
        });
    }

    /// <summary>One send at a time; if more copies happen meanwhile only the latest is sent.</summary>
    private void Enqueue(Func<(byte[] Body, long Ts)?> build)
    {
        lock (_sendGate)
        {
            _pending = build;
            if (_sending) return;
            _sending = true;
        }
        _ = Task.Run(SendLoopAsync);
    }

    private async Task SendLoopAsync()
    {
        while (true)
        {
            Func<(byte[] Body, long Ts)?>? next;
            lock (_sendGate)
            {
                next = _pending;
                _pending = null;
                if (next == null || _disposed) { _sending = false; return; }
            }
            try
            {
                var key = _key;
                var peer = _settings.SyncPeer;
                if (key == null || string.IsNullOrWhiteSpace(peer)) continue;
                var built = next();
                if (built == null) continue;
                var result = await ClipSyncClient.SendAsync(peer, key, built.Value.Body, built.Value.Ts, _localIp, _cts.Token).ConfigureAwait(false);
                if (_disposed) continue;
                if (result == ClipSyncResult.Ok)
                {
                    _host.Log(_moduleId, "condivisione: inviato");
                    if (PeerTone == ClipSyncTone.Error) ShowResult(result);
                }
                else
                {
                    _host.Log(_moduleId, "condivisione: errore " + result switch
                    {
                        ClipSyncResult.WrongKey => "chiave sbagliata",
                        ClipSyncResult.Refused => "rifiutato (in pausa)",
                        ClipSyncResult.Self => "destinatario è questo PC",
                        ClipSyncResult.Error => "risposta non valida",
                        _ => "non raggiungibile",
                    });
                    ShowResult(result);
                }
            }
            catch (Exception) { _host.Log(_moduleId, "condivisione: errore invio non riuscito"); }
        }
    }

    // =====================================================================================
    // Receiving (IClipSyncSink, called on a server worker thread)
    // =====================================================================================

    bool IClipSyncSink.ReceivePaused => _disposed || !_settings.SyncEnabled || _settings.SyncPaused;

    void IClipSyncSink.Deliver(ClipPayload clip)
    {
        if (_disposed) return;
        _host.Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(() =>
        {
            if (!_disposed) _onReceived(clip);
        }));
    }
}
