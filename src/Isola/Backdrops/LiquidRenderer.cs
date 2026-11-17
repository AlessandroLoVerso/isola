using System.Numerics;
using Isola.Core;
using SharpGen.Runtime;
using Vortice;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DirectComposition;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace Isola.Backdrops;

/// <summary>Real refracting glass for "Liquido".
/// Capture: DXGI Desktop Duplication of the island's monitor (the island and the backdrop are
/// excluded with WDA_EXCLUDEFROMCAPTURE, so it sees what's behind them). Only the rectangle of
/// the island window is copied, and only when a dirty rect of the new frame touches it.
/// Render: one full-screen triangle, pixel shader with the rounded-rect SDF (LiquidShader).
/// Present: a premultiplied-alpha composition swap chain shown by DirectComposition in the
/// backdrop window. Nothing runs at rest: the capture thread sleeps in AcquireNextFrame and
/// the UI thread renders only when the outline changes.</summary>
internal sealed class LiquidRenderer : IDisposable
{
    private const Format Bgra = Format.B8G8R8A8_UNorm;
    private const int CropMips = 6;

    private readonly object _gate = new();
    private readonly IntPtr _hwnd;
    private readonly bool _captureOnce;
    private readonly AutoResetEvent _wake = new(false);
    private readonly Thread _thread;

    private IDXGIFactory2? _factory;
    private IDXGIAdapter1? _adapter;
    private IDXGIOutput1? _output;
    private RawRect _outputRect;
    private ID3D11Device? _device;
    private ID3D11DeviceContext? _ctx;
    private IDCompositionDevice? _dcomp;
    private IDCompositionTarget? _target;
    private IDCompositionVisual? _visual;
    private IDXGISwapChain1? _swap;
    private ID3D11RenderTargetView? _rtv;
    private ID3D11Texture2D? _crop;
    private ID3D11Texture2D? _probe;     // staging copy of a small mip, to detect real changes
    private const int ProbeMip = 2;
    private int _probeW, _probeH;
    private byte[] _probeData = Array.Empty<byte>(), _probeRow = Array.Empty<byte>();
    private ID3D11ShaderResourceView? _cropSrv;
    private ID3D11VertexShader? _vs;
    private ID3D11PixelShader? _ps;
    private ID3D11Buffer? _cb;
    private ID3D11SamplerState? _sampler;
    private IDXGIOutputDuplication? _dup;

    private GlassNative.RECT _rect;       // backdrop window, screen px
    private int _w, _h;                   // swap chain / crop size
    private LiquidParams _params;
    private bool _hasShape, _hasContent;
    private volatile bool _stop, _recreate, _paused;
    private bool _failed, _disposed;

    /// <summary>Raised (on the capture thread or the UI thread) when the GPU path broke down
    /// for good; the owner falls back to the acrylic.</summary>
    public event Action<Exception>? Failed;

    /// <summary>Raised on the capture thread after the first frame was captured.</summary>
    public event Action? FirstFrame;

    public long FramesCaptured, FramesSkipped, FramesRendered;

    public LiquidRenderer(IntPtr hwnd, GlassNative.RECT rect, bool captureOnce)
    {
        _hwnd = hwnd;
        _rect = rect;
        _captureOnce = captureOnce;
        _params.Look = new Vector4(Env("ISOLA_LIQUID_STRENGTH", 0.6f), Env("ISOLA_LIQUID_BEZEL", 16f), Env("ISOLA_LIQUID_BLUR", 2.8f), Env("ISOLA_LIQUID_CA", 1.4f));
        _params.Look2 = new Vector4(Env("ISOLA_LIQUID_DARK", 0.40f), Env("ISOLA_LIQUID_LIGHT", 0.85f), Env("ISOLA_LIQUID_SAT", 1.25f), 0);

        try
        {
            CreateDevice();
            CreatePipeline();
            CreateSizeDependent(Math.Max(1, rect.Width), Math.Max(1, rect.Height));
        }
        catch
        {
            ReleaseAll();
            throw;
        }

        _thread = new Thread(CaptureLoop) { IsBackground = true, Name = "Isola.Liquido", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    // =====================================================================================
    // Setup
    // =====================================================================================

    private void CreateDevice()
    {
        _factory = DXGI.CreateDXGIFactory2<IDXGIFactory2>(false);
        int cx = _rect.Left + _rect.Width / 2, cy = _rect.Top + Math.Max(1, _rect.Height / 4);

        for (uint a = 0; _factory.EnumAdapters1(a, out var adapter).Success; a++)
        {
            for (uint o = 0; adapter.EnumOutputs(o, out var output).Success; o++)
            {
                var d = output.Description;
                if (_output == null && d.AttachedToDesktop && cx >= d.DesktopCoordinates.Left && cx < d.DesktopCoordinates.Right &&
                    cy >= d.DesktopCoordinates.Top && cy < d.DesktopCoordinates.Bottom)
                {
                    if (d.Rotation is not (ModeRotation.Identity or ModeRotation.Unspecified))
                        throw new NotSupportedException("Monitor ruotato: Liquido non supportato");
                    _output = output.QueryInterface<IDXGIOutput1>();
                    _outputRect = d.DesktopCoordinates;
                    _adapter = adapter;
                }
                output.Dispose();
            }
            if (_adapter == adapter) break;
            adapter.Dispose();
        }
        if (_adapter == null || _output == null) throw new InvalidOperationException("Nessuna uscita DXGI per il monitor dell'isola");

        var levels = new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_1, FeatureLevel.Level_10_0 };
        D3D11.D3D11CreateDevice(_adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport, levels, out _device, out _ctx).CheckError();
        using (var mt = _device!.QueryInterface<ID3D11Multithread>()) mt.SetMultithreadProtected(true);
        using (var dxgiDevice = _device.QueryInterface<IDXGIDevice1>())
        {
            dxgiDevice.MaximumFrameLatency = 1;
            _dcomp = DComp.DCompositionCreateDevice<IDCompositionDevice>(dxgiDevice);
        }
        _dcomp.CreateTargetForHwnd(_hwnd, true, out _target).CheckError();
        _visual = _dcomp.CreateVisual();
        _target!.SetRoot(_visual).CheckError();
    }

    private void CreatePipeline()
    {
        var vs = Compiler.Compile(LiquidShader.Source, "VS", "liquido.hlsl", "vs_4_0", ShaderFlags.OptimizationLevel3, EffectFlags.None);
        var ps = Compiler.Compile(LiquidShader.Source, "PS", "liquido.hlsl", "ps_4_0", ShaderFlags.OptimizationLevel3, EffectFlags.None);
        _vs = _device!.CreateVertexShader(vs.Span, null);
        _ps = _device.CreatePixelShader(ps.Span, null);
        _cb = _device.CreateBuffer((uint)System.Runtime.InteropServices.Marshal.SizeOf<LiquidParams>(), BindFlags.ConstantBuffer,
            ResourceUsage.Default, CpuAccessFlags.None, ResourceOptionFlags.None, 0);
        _sampler = _device.CreateSamplerState(new SamplerDescription(Filter.MinMagMipLinear, TextureAddressMode.Clamp,
            0, 1, ComparisonFunction.Never, 0, float.MaxValue));
    }

    private void CreateSizeDependent(int w, int h)
    {
        _rtv?.Dispose();
        _rtv = null;
        _cropSrv?.Dispose();
        _crop?.Dispose();

        if (_swap == null)
        {
            var desc = new SwapChainDescription1((uint)w, (uint)h, Bgra, false, Usage.RenderTargetOutput, 2,
                Scaling.Stretch, SwapEffect.FlipSequential, AlphaMode.Premultiplied, SwapChainFlags.None);
            _swap = _factory!.CreateSwapChainForComposition(_device!, desc, null);
            _visual!.SetContent(_swap).CheckError();
            _dcomp!.Commit().CheckError();
        }
        else
        {
            _swap.ResizeBuffers(2, (uint)w, (uint)h, Bgra, SwapChainFlags.None).CheckError();
        }
        using (var back = _swap.GetBuffer<ID3D11Texture2D>(0))
            _rtv = _device!.CreateRenderTargetView(back, null);

        var td = new Texture2DDescription(Bgra, (uint)w, (uint)h, 1, CropMips,
            BindFlags.ShaderResource | BindFlags.RenderTarget, ResourceUsage.Default, CpuAccessFlags.None, 1, 0,
            ResourceOptionFlags.GenerateMips);
        _crop = _device!.CreateTexture2D(td);
        _cropSrv = _device.CreateShaderResourceView(_crop, null);

        _probe?.Dispose();
        _probeW = Math.Max(1, w >> ProbeMip);
        _probeH = Math.Max(1, h >> ProbeMip);
        _probe = _device.CreateTexture2D(new Texture2DDescription(Bgra, (uint)_probeW, (uint)_probeH, 1, 1,
            BindFlags.None, ResourceUsage.Staging, CpuAccessFlags.Read, 1, 0, ResourceOptionFlags.None));
        _probeData = new byte[_probeW * _probeH * 4];
        _w = w;
        _h = h;
        _hasContent = false;
        _params.Texel = new Vector4(1f / w, 1f / h, w, h);
    }

    // =====================================================================================
    // UI thread
    // =====================================================================================

    /// <summary>New outline (pixels relative to the backdrop window).</summary>
    public void SetShape(in ShapeOutline o, double scale)
    {
        lock (_gate)
        {
            if (_failed || _disposed) return;
            _params.Body = new Vector4((float)o.X0, (float)o.Y0, (float)o.X1, (float)o.Y1);
            _params.Radii = new Vector4((float)o.TopRadius, (float)o.Flare, (float)o.BottomRadius, (float)scale);
            _params.Look2.W = o.Flare > 0.01 ? 1 : 0;
            _hasShape = !o.IsEmpty;
            RenderLocked();
        }
    }

    /// <summary>The backdrop window moved or changed size (monitor / DPI change).</summary>
    public void SetWindowRect(GlassNative.RECT r)
    {
        lock (_gate)
        {
            if (_failed || _disposed) return;
            _rect = r;
            try
            {
                if (r.Width != _w || r.Height != _h) CreateSizeDependent(Math.Max(1, r.Width), Math.Max(1, r.Height));
            }
            catch (Exception ex)
            {
                FailLocked(ex);
                return;
            }
            _hasContent = false;
        }
        // A new duplication gives a full first frame; also picks the right monitor.
        _recreate = true;
        _wake.Set();
    }

    /// <summary>While the island is hidden (e.g. "Nascondi" above a fullscreen app) there is
    /// nothing to refract: the duplication is released and the thread sleeps.</summary>
    public void SetPaused(bool paused)
    {
        if (_paused == paused) return;
        _paused = paused;
        if (!paused) _recreate = true; // fresh duplication = a full first frame
        try { _wake.Set(); } catch (ObjectDisposedException) { }
    }

    // =====================================================================================
    // Capture thread
    // =====================================================================================

    private void CaptureLoop()
    {
        try
        {
            CaptureLoopCore();
        }
        finally
        {
            // The capture thread owns the teardown, so nothing is released while it is still
            // inside AcquireNextFrame.
            lock (_gate) ReleaseAll();
        }
    }

    private void CaptureLoopCore()
    {
        int failures = 0;
        bool first = true;
        while (!_stop && !_failed)
        {
            try
            {
                if (_paused)
                {
                    DropDuplication();
                    _wake.WaitOne();
                    continue;
                }
                if (_recreate)
                {
                    _recreate = false;
                    DropDuplication();
                    lock (_gate) { if (!EnsureOutputLocked()) { FailLocked(new InvalidOperationException("Monitor cambiato: serve un nuovo dispositivo")); return; } }
                    first = true;
                }
                if (_dup == null)
                {
                    if (_captureOnce && !first) { _wake.WaitOne(); continue; }
                    if (!TryDuplicate())
                    {
                        if (++failures > 40) throw new InvalidOperationException("Duplicazione del desktop non disponibile");
                        _wake.WaitOne(Math.Min(250 * failures, 2000));
                        continue;
                    }
                    failures = 0;
                }

                var r = _dup!.AcquireNextFrame(1000, out var info, out var resource);
                if (r.Code == Vortice.DXGI.ResultCode.WaitTimeout.Code) continue;
                if (r.Failure)
                {
                    // AccessLost (mode change, secure desktop, fullscreen switch...): start again.
                    DropDuplication();
                    _wake.WaitOne(200);
                    continue;
                }

                try
                {
                    if (info.LastPresentTime != 0 && (first || TouchesCrop(info)))
                    {
                        using var tex = resource.QueryInterface<ID3D11Texture2D>();
                        lock (_gate)
                        {
                            if (_failed || _disposed) break;
                            FramesCaptured++;
                            // Our own presents make DWM report the area as dirty too (even though
                            // the windows are excluded from the image): render only if the pixels
                            // behind really changed, or this would loop at the refresh rate.
                            if (CopyCropLocked(tex) || first)
                            {
                                _hasContent = true;
                                RenderLocked();
                            }
                        }
                        if (first) FirstFrame?.Invoke();
                        first = false;
                    }
                }
                finally
                {
                    resource.Dispose();
                    _dup?.ReleaseFrame();
                }

                if (_captureOnce && !first) DropDuplication();
            }
            catch (Exception ex)
            {
                if (_stop) break;
                lock (_gate) FailLocked(ex);
                break;
            }
        }
    }

    private bool EnsureOutputLocked()
    {
        int cx = _rect.Left + _rect.Width / 2, cy = _rect.Top + Math.Max(1, _rect.Height / 4);
        var d = _outputRect;
        if (cx >= d.Left && cx < d.Right && cy >= d.Top && cy < d.Bottom) return true;
        // The island moved to another monitor: find it on the same adapter.
        for (uint o = 0; _adapter!.EnumOutputs(o, out var output).Success; o++)
        {
            var od = output.Description;
            if (cx >= od.DesktopCoordinates.Left && cx < od.DesktopCoordinates.Right &&
                cy >= od.DesktopCoordinates.Top && cy < od.DesktopCoordinates.Bottom)
            {
                _output?.Dispose();
                _output = output.QueryInterface<IDXGIOutput1>();
                _outputRect = od.DesktopCoordinates;
                output.Dispose();
                return true;
            }
            output.Dispose();
        }
        return false; // on another adapter: the owner recreates everything
    }

    private bool TryDuplicate()
    {
        try
        {
            IDXGIOutputDuplication dup;
            using (var o5 = _output!.QueryInterfaceOrNull<IDXGIOutput5>())
            {
                dup = o5 != null ? o5.DuplicateOutput1(_device!, new[] { Bgra }) : _output.DuplicateOutput(_device!);
            }
            _dup = dup;
            return true;
        }
        catch (SharpGenException ex)
        {
            Log.Warn($"Liquido: DuplicateOutput non riuscito (0x{ex.HResult:X8}), riprovo");
            return false;
        }
    }

    private void DropDuplication()
    {
        try { _dup?.Dispose(); } catch { /* already gone */ }
        _dup = null;
    }

    private RawRect[] _dirty = new RawRect[32];
    private OutduplMoveRect[] _moves = new OutduplMoveRect[8];

    private bool TouchesCrop(in OutduplFrameInfo info)
    {
        if (info.TotalMetadataBufferSize == 0) return false;
        var crop = new RawRect(_rect.Left - _outputRect.Left, _rect.Top - _outputRect.Top,
            _rect.Right - _outputRect.Left, _rect.Bottom - _outputRect.Top);
        static bool Hit(in RawRect a, in RawRect b) => a.Left < b.Right && b.Left < a.Right && a.Top < b.Bottom && b.Top < a.Bottom;

        uint size = (uint)(_moves.Length * System.Runtime.InteropServices.Marshal.SizeOf<OutduplMoveRect>());
        var r = _dup!.GetFrameMoveRects(size, _moves, out uint needed);
        if (r.Failure)
        {
            if (needed == 0) return true;
            _moves = new OutduplMoveRect[needed / System.Runtime.InteropServices.Marshal.SizeOf<OutduplMoveRect>() + 1];
            size = (uint)(_moves.Length * System.Runtime.InteropServices.Marshal.SizeOf<OutduplMoveRect>());
            if (_dup.GetFrameMoveRects(size, _moves, out needed).Failure) return true;
        }
        int moveCount = (int)(needed / System.Runtime.InteropServices.Marshal.SizeOf<OutduplMoveRect>());
        for (int i = 0; i < moveCount; i++)
            if (Hit(_moves[i].DestinationRect, crop)) return true;

        size = (uint)(_dirty.Length * System.Runtime.InteropServices.Marshal.SizeOf<RawRect>());
        r = _dup.GetFrameDirtyRects(size, _dirty, out needed);
        if (r.Failure)
        {
            if (needed == 0) return true;
            _dirty = new RawRect[needed / System.Runtime.InteropServices.Marshal.SizeOf<RawRect>() + 1];
            size = (uint)(_dirty.Length * System.Runtime.InteropServices.Marshal.SizeOf<RawRect>());
            if (_dup.GetFrameDirtyRects(size, _dirty, out needed).Failure) return true;
        }
        int dirtyCount = (int)(needed / System.Runtime.InteropServices.Marshal.SizeOf<RawRect>());
        for (int i = 0; i < dirtyCount; i++)
            if (Hit(_dirty[i], crop)) return true;
        return false;
    }

    /// <summary>Copies the area behind the island; returns false when it is identical to the
    /// previous copy (compared on a 1/4-size mip read back to the CPU, a few KB).</summary>
    private bool CopyCropLocked(ID3D11Texture2D desktop)
    {
        var dd = desktop.Description;
        int sx = _rect.Left - _outputRect.Left, sy = _rect.Top - _outputRect.Top;
        int x0 = Math.Clamp(sx, 0, (int)dd.Width), y0 = Math.Clamp(sy, 0, (int)dd.Height);
        int x1 = Math.Clamp(sx + _w, 0, (int)dd.Width), y1 = Math.Clamp(sy + _h, 0, (int)dd.Height);
        if (x1 <= x0 || y1 <= y0) return false;
        var ctx = _ctx!;
        ctx.CopySubresourceRegion(_crop!, 0, (uint)(x0 - sx), (uint)(y0 - sy), 0, desktop, 0, new Box(x0, y0, 0, x1, y1, 1));
        ctx.GenerateMips(_cropSrv!);

        if (_probe == null) return true;
        ctx.CopySubresourceRegion(_probe, 0, 0, 0, 0, _crop!, ProbeMip, null);
        var map = ctx.Map(_probe, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        bool changed = false;
        try
        {
            int rowBytes = _probeW * 4;
            if (_probeRow.Length != rowBytes) _probeRow = new byte[rowBytes];
            for (int y = 0; y < _probeH; y++)
            {
                System.Runtime.InteropServices.Marshal.Copy(map.DataPointer + (nint)((long)y * map.RowPitch), _probeRow, 0, rowBytes);
                var prev = _probeData.AsSpan(y * rowBytes, rowBytes);
                if (!_probeRow.AsSpan().SequenceEqual(prev))
                {
                    changed = true;
                    _probeRow.CopyTo(prev);
                }
            }
        }
        finally
        {
            ctx.Unmap(_probe, 0);
        }
        if (!changed) FramesSkipped++;
        return changed;
    }

    // =====================================================================================
    // Rendering (always under _gate)
    // =====================================================================================

    private void RenderLocked()
    {
        if (_failed || _disposed || _swap == null || _rtv == null) return;
        var ctx = _ctx!;
        if (!_hasShape || !_hasContent)
        {
            ctx.ClearRenderTargetView(_rtv, new Color4(0, 0, 0, 0));
        }
        else
        {
            ctx.UpdateSubresource(in _params, _cb!, 0, 0, 0, null);
            ctx.OMSetRenderTargets(_rtv, null);
            ctx.RSSetViewport(0, 0, _w, _h, 0, 1);
            ctx.IASetInputLayout(null);
            ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
            ctx.VSSetShader(_vs);
            ctx.PSSetShader(_ps);
            ctx.PSSetShaderResource(0, _cropSrv!);
            ctx.PSSetSampler(0, _sampler!);
            ctx.PSSetConstantBuffer(0, _cb!);
            ctx.Draw(3, 0);
            ctx.PSSetShaderResource(0, null!); // GenerateMips needs it unbound next time
        }
        var r = _swap.Present(0, PresentFlags.None);
        FramesRendered++;
        if (r.Failure) FailLocked(new SharpGenException(r));
    }

    private void FailLocked(Exception ex)
    {
        if (_failed) return;
        _failed = true;
        Log.Error("Liquido: il vetro GPU si è fermato, passo a Vetro", ex);
        try { Failed?.Invoke(ex); } catch { /* owner handles */ }
    }

    // =====================================================================================
    // Lifetime
    // =====================================================================================

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
        }
        _stop = true;
        _wake.Set(); // the capture thread wakes up (≤ 1 s if inside AcquireNextFrame) and releases everything
    }

    private void ReleaseAll()
    {
        if (_device != null) Log.Info($"Liquido: {FramesCaptured} catture ({FramesSkipped} uguali, scartate), {FramesRendered} disegni");
        DropDuplication();
        try
        {
            if (_target != null) { _target.SetRoot(null); _dcomp?.Commit(); }
        }
        catch { /* best effort */ }
        _rtv?.Dispose(); _rtv = null;
        _cropSrv?.Dispose(); _cropSrv = null;
        _crop?.Dispose(); _crop = null;
        _probe?.Dispose(); _probe = null;
        _swap?.Dispose(); _swap = null;
        _visual?.Dispose(); _visual = null;
        _target?.Dispose(); _target = null;
        _dcomp?.Dispose(); _dcomp = null;
        _vs?.Dispose(); _vs = null;
        _ps?.Dispose(); _ps = null;
        _cb?.Dispose(); _cb = null;
        _sampler?.Dispose(); _sampler = null;
        _ctx?.ClearState();
        _ctx?.Dispose(); _ctx = null;
        _device?.Dispose(); _device = null;
        _output?.Dispose(); _output = null;
        _adapter?.Dispose(); _adapter = null;
        _factory?.Dispose(); _factory = null;
    }

    private static float Env(string name, float fallback)
        => float.TryParse(Environment.GetEnvironmentVariable(name), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out float v) ? v : fallback;
}
