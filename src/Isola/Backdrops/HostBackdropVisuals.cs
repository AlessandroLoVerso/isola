using System.Numerics;
using System.Runtime.InteropServices;
using Windows.UI.Composition;
using Windows.UI.Composition.Desktop;
using WinRT;

namespace Isola.Backdrops;

/// <summary>The glass of "Vetro", drawn with Windows.UI.Composition in the backdrop window:
/// a HostBackdropBrush (the blurred desktop behind the window, from DWM), a dark tint and a
/// 1 px light rim, all cut to the island outline with anti-aliased geometric clips.
///
/// Why not DWMWA_SYSTEMBACKDROP_TYPE / ACCENT_ENABLE_ACRYLICBLURBEHIND: on current Windows 11
/// both ignore SetWindowRgn (the blur fills the whole window rectangle), and the system
/// backdrop turns into a flat grey on windows that are never activated.
/// Why the tint and rim live here and not in the island: the island is a layered WPF window
/// whose frames reach the screen with a jittery 1-2 frame latency; drawing blur, tint and rim
/// in one composition tree keeps the glass edge consistent on every frame.
///
/// The outline is built from pieces that share the same brushes (so there are no seams):
///   top    = rounded rect with the top radius, shown above the split line;
///   bottom = rounded rect with the bottom radius, shown below it;
///   flares = the notch's concave corners, as a stack of 1 px rows (CompositionMaskBrush does
///            not accept a backdrop brush as its source, and a path clip needs Direct2D).
/// Units are physical pixels of the window.</summary>
internal sealed class HostBackdropVisuals : IDisposable
{
    [ComImport, Guid("29E691FA-4567-4DCA-B319-D0F207EB6807"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICompositorDesktopInterop
    {
        void CreateDesktopWindowTarget(IntPtr hwndTarget, [MarshalAs(UnmanagedType.Bool)] bool isTopmost, out IntPtr result);
        void EnsureOnThread(uint threadId);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DispatcherQueueOptions
    {
        public int dwSize;
        public int threadType;     // DQTYPE_THREAD_CURRENT = 2
        public int apartmentType;  // DQTAT_COM_STA = 2
    }

    [DllImport("CoreMessaging.dll")]
    private static extern int CreateDispatcherQueueController(DispatcherQueueOptions options, out IntPtr controller);

    private static IntPtr s_queueController; // one per UI thread, kept for the process lifetime
    private static Compositor? s_compositor;

    private const int MaxFlareRows = 64;

    private readonly Compositor _c;
    private readonly DesktopWindowTarget _target;
    private readonly ContainerVisual _root;
    private readonly ContainerVisual _topClip, _bottomClip, _topShape, _bottomShape, _rimTopClip, _rimBottomClip;
    private readonly ShapeVisual _rimTop, _rimBottom;
    private readonly CompositionRoundedRectangleGeometry _topGeo, _bottomGeo, _rimTopGeo, _rimBottomGeo;
    private readonly InsetClip _topInset, _bottomInset, _rimTopInset, _rimBottomInset;
    private readonly SpriteVisual[] _rowsL = new SpriteVisual[MaxFlareRows], _rowsR = new SpriteVisual[MaxFlareRows];
    private readonly SpriteVisual[] _tintL = new SpriteVisual[MaxFlareRows], _tintR = new SpriteVisual[MaxFlareRows];
    private readonly CompositionBrush _backdrop;
    private readonly CompositionLinearGradientBrush _tint, _rim;
    private readonly CompositionColorBrush _tintTop;
    private readonly List<IDisposable> _owned = new();
    private Vector2 _size;

    public HostBackdropVisuals(IntPtr hwnd, int width, int height, GlassLook look)
    {
        _c = EnsureCompositor();
        var interop = _c.As<ICompositorDesktopInterop>();
        interop.CreateDesktopWindowTarget(hwnd, true, out IntPtr raw);
        try { _target = DesktopWindowTarget.FromAbi(raw); }
        finally { Marshal.Release(raw); }

        _backdrop = Own(_c.CreateHostBackdropBrush());
        _tint = Own(Gradient(look.TintStops));
        _tintTop = Own(_c.CreateColorBrush(look.TintStops[0].Color));
        _rim = Own(Gradient(look.RimStops));

        _root = Own(_c.CreateContainerVisual());
        _target.Root = _root;

        // Body: [InsetClip half] → [geometric clip shape] → blur + tint.
        (_bottomClip, _bottomInset, _bottomShape, _bottomGeo) = Piece();
        (_topClip, _topInset, _topShape, _topGeo) = Piece();
        _root.Children.InsertAtTop(_bottomClip);
        _root.Children.InsertAtTop(_topClip);

        for (int i = 0; i < MaxFlareRows; i++)
        {
            _rowsL[i] = Row(_backdrop);
            _tintL[i] = Row(_tintTop);
            _rowsR[i] = Row(_backdrop);
            _tintR[i] = Row(_tintTop);
        }

        // Rim: a 1 px stroke just inside the outline, split like the body.
        (_rimBottomClip, _rimBottomInset, _rimBottom, _rimBottomGeo) = Rim();
        (_rimTopClip, _rimTopInset, _rimTop, _rimTopGeo) = Rim();
        Resize(width, height);
    }

    private T Own<T>(T d) where T : IDisposable
    {
        _owned.Add(d);
        return d;
    }

    private CompositionLinearGradientBrush Gradient((float Offset, Windows.UI.Color Color)[] stops)
    {
        var g = _c.CreateLinearGradientBrush();
        g.MappingMode = CompositionMappingMode.Absolute;
        foreach (var (o, col) in stops) g.ColorStops.Add(Own(_c.CreateColorGradientStop(o, col)));
        return g;
    }

    private (ContainerVisual, InsetClip, ContainerVisual, CompositionRoundedRectangleGeometry) Piece()
    {
        var half = Own(_c.CreateContainerVisual());
        var inset = Own(_c.CreateInsetClip());
        half.Clip = inset;
        var shape = Own(_c.CreateContainerVisual());
        var geo = Own(_c.CreateRoundedRectangleGeometry());
        shape.Clip = Own(_c.CreateGeometricClip(geo));
        foreach (var brush in new[] { _backdrop, _tint })
        {
            var s = Own(_c.CreateSpriteVisual());
            s.Brush = brush;
            s.RelativeSizeAdjustment = Vector2.One;
            shape.Children.InsertAtTop(s);
        }
        half.Children.InsertAtTop(shape);
        return (half, inset, shape, geo);
    }

    private SpriteVisual Row(CompositionBrush brush)
    {
        var v = Own(_c.CreateSpriteVisual());
        v.Brush = brush;
        v.IsVisible = false;
        _root.Children.InsertAtTop(v);
        return v;
    }

    private (ContainerVisual, InsetClip, ShapeVisual, CompositionRoundedRectangleGeometry) Rim()
    {
        var half = Own(_c.CreateContainerVisual());
        var inset = Own(_c.CreateInsetClip());
        half.Clip = inset;
        var geo = Own(_c.CreateRoundedRectangleGeometry());
        var sprite = Own(_c.CreateSpriteShape(geo));
        sprite.StrokeBrush = _rim;
        sprite.StrokeThickness = 1;
        var sv = Own(_c.CreateShapeVisual());
        sv.Shapes.Add(sprite);
        half.Children.InsertAtTop(sv);
        _root.Children.InsertAtTop(half);
        return (half, inset, sv, geo);
    }

    public void Resize(int width, int height)
    {
        _size = new Vector2(Math.Max(1, width), Math.Max(1, height));
        foreach (var v in new Visual[] { _root, _topClip, _bottomClip, _topShape, _bottomShape, _rimTopClip, _rimBottomClip, _rimTop, _rimBottom })
            v.Size = _size;
    }

    /// <summary>Applies the outline (pixels relative to the window).</summary>
    public void Update(in ShapeOutline o)
    {
        if (o.IsEmpty)
        {
            _root.IsVisible = false;
            return;
        }
        _root.IsVisible = true;

        float x0 = (float)o.X0, y0 = (float)o.Y0, w = (float)o.Width, h = (float)o.Height;
        float rt = (float)o.TopRadius, f = (float)o.Flare, rb = (float)o.BottomRadius;
        bool attached = f > 0.01f;
        if (attached)
        {
            // Whole-pixel sides, so the 1 px flare rows meet the body without a hairline seam.
            float x1 = MathF.Round(x0 + w);
            x0 = MathF.Round(x0);
            w = x1 - x0;
        }

        // Split between the top-radius part and the bottom-radius part, on a whole pixel so the
        // two halves meet without a seam.
        float split = Math.Clamp(MathF.Round(y0 + Math.Max(rt, f)), 0, _size.Y);
        SetHalves(_topInset, _bottomInset, split);
        SetHalves(_rimTopInset, _rimBottomInset, split);
        bool hasTop = split > y0 + 0.01f;
        _topClip.IsVisible = hasTop;
        _rimTopClip.IsVisible = hasTop && !attached; // no rim along the screen edge

        _topGeo.Offset = new Vector2(x0, y0);
        _topGeo.Size = new Vector2(w, h + rt + 2);
        _topGeo.CornerRadius = new Vector2(rt, rt);
        _bottomGeo.Offset = new Vector2(x0, y0 - rb - 2);
        _bottomGeo.Size = new Vector2(w, h + rb + 2);
        _bottomGeo.CornerRadius = new Vector2(rb, rb);

        // Stroke centred half a pixel inside the outline = a crisp inner 1 px line.
        _rimTopGeo.Offset = new Vector2(x0 + 0.5f, y0 + 0.5f);
        _rimTopGeo.Size = new Vector2(Math.Max(0, w - 1), h + rt + 2);
        _rimTopGeo.CornerRadius = new Vector2(Math.Max(0, rt - 0.5f), Math.Max(0, rt - 0.5f));
        float bTop = attached ? -4 : y0 - rb - 2; // attached: the bottom piece reaches the screen edge
        _rimBottomGeo.Offset = new Vector2(x0 + 0.5f, bTop);
        _rimBottomGeo.Size = new Vector2(Math.Max(0, w - 1), Math.Max(0, y0 + h - 0.5f - bTop));
        _rimBottomGeo.CornerRadius = new Vector2(Math.Max(0, rb - 0.5f), Math.Max(0, rb - 0.5f));

        _tint.StartPoint = new Vector2(0, y0);
        _tint.EndPoint = new Vector2(0, y0 + h);
        _rim.StartPoint = new Vector2(0, y0);
        _rim.EndPoint = new Vector2(0, y0 + h);

        // Concave flares: row i covers [y0+i, y0+i+1); outside the circle of radius f centred
        // f below the top edge and f outside the body.
        int rows = f > 0.6f ? Math.Min(MaxFlareRows, (int)MathF.Ceiling(f)) : 0;
        for (int i = 0; i < MaxFlareRows; i++)
        {
            bool on = i < rows;
            if (on)
            {
                float top = y0 + i, hRow = Math.Min(1, f - i);
                float dy = f - (i + hRow / 2);
                float dx = MathF.Sqrt(Math.Max(0, f * f - dy * dy));
                float width = f - dx;
                if (width < 0.05f) on = false;
                else
                {
                    var size = new Vector2(width, hRow);
                    _rowsL[i].Offset = _tintL[i].Offset = new Vector3(x0 - width, top, 0);
                    _rowsR[i].Offset = _tintR[i].Offset = new Vector3(x0 + w, top, 0);
                    _rowsL[i].Size = _tintL[i].Size = _rowsR[i].Size = _tintR[i].Size = size;
                }
            }
            if (_rowsL[i].IsVisible != on)
                _rowsL[i].IsVisible = _tintL[i].IsVisible = _rowsR[i].IsVisible = _tintR[i].IsVisible = on;
        }
    }

    private void SetHalves(InsetClip top, InsetClip bottom, float split)
    {
        top.TopInset = 0;
        top.BottomInset = Math.Max(0, _size.Y - split);
        bottom.TopInset = split;
        bottom.BottomInset = 0;
    }

    public void Dispose()
    {
        try { _target.Root = null; } catch { /* window may be gone */ }
        for (int i = _owned.Count - 1; i >= 0; i--)
        {
            try { _owned[i].Dispose(); } catch { /* best effort */ }
        }
        _owned.Clear();
        try { _target.Dispose(); } catch { /* best effort */ }
    }

    private static Compositor EnsureCompositor()
    {
        if (s_compositor != null) return s_compositor;
        if (Windows.System.DispatcherQueue.GetForCurrentThread() == null)
        {
            var opt = new DispatcherQueueOptions { dwSize = Marshal.SizeOf<DispatcherQueueOptions>(), threadType = 2, apartmentType = 2 };
            int hr = CreateDispatcherQueueController(opt, out s_queueController);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        }
        return s_compositor = new Compositor();
    }
}

/// <summary>Colours of the composition glass (vertical gradients over the island height).</summary>
internal sealed record GlassLook((float Offset, Windows.UI.Color Color)[] TintStops, (float Offset, Windows.UI.Color Color)[] RimStops);
