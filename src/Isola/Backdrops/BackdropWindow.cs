using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Isola.Core;
using Isola.Island;
using static Isola.Backdrops.GlassNative;

namespace Isola.Backdrops;

internal enum BackdropMaterial
{
    /// <summary>Nothing from DWM: the content comes from a DirectComposition swap chain.</summary>
    None,

    /// <summary>Windows.UI.Composition HostBackdropBrush clipped to the outline (default).</summary>
    HostBackdrop,

    /// <summary>Windows 11 22H2+: DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_TRANSIENTWINDOW.</summary>
    SystemAcrylic,

    /// <summary>Windows 10 / 11 21H2: SetWindowCompositionAttribute ACCENT_ENABLE_ACRYLICBLURBEHIND.</summary>
    AccentAcrylic,
}

/// <summary>A plain Win32 popup (not layered, no WPF) that sits exactly over the island window,
/// directly beneath it in Z order, and is clipped every frame to the island's visible outline
/// with SetWindowRgn. The window never changes size while the island animates: only the region
/// does, which DWM applies in the same composition pass, so the edges don't lag.
/// Never activated, click-through (WM_NCHITTEST → HTTRANSPARENT, and the island covers it),
/// hidden from Alt+Tab (WS_EX_TOOLWINDOW).</summary>
internal sealed class BackdropWindow : IDisposable
{
    private const string ClassName = "Isola.GlassBackdrop";
    private static WndProc? s_proc;      // kept alive for the lifetime of the process
    private static bool s_registered;

    private readonly IntPtr _island;
    private readonly Dispatcher _dispatcher;
    private readonly WinEventDelegate _winEvent;
    private IntPtr _hook;
    private bool _shown;
    private RECT _rect;
    private (int, int, int, int, int, int, int, int) _regionKey = (-1, 0, 0, 0, 0, 0, 0, 0);
    private bool _disposed;

    public IntPtr Hwnd { get; private set; }

    public BackdropMaterial Material { get; private set; } = BackdropMaterial.None;

    /// <summary>Pixels the region is grown by (the DirectComposition content anti-aliases its own
    /// edge inside it, so it needs a little room).</summary>
    public double RegionGrow { get; set; }

    /// <summary>The window rectangle in screen pixels (equal to the island window's).</summary>
    public RECT Rect => _rect;

    /// <summary>Raised after the window moved or changed size (screen pixels).</summary>
    public event Action<RECT>? Moved;

    public BackdropWindow(IntPtr islandHwnd, Dispatcher dispatcher, bool noRedirectionBitmap)
    {
        _island = islandHwnd;
        _dispatcher = dispatcher;
        EnsureClass();

        GetWindowRect(_island, out _rect);
        uint ex = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TRANSPARENT;
        if (noRedirectionBitmap) ex |= WS_EX_NOREDIRECTIONBITMAP;
        Hwnd = CreateWindowEx(ex, ClassName, "Isola · vetro", WS_POPUP | WS_CLIPSIBLINGS,
            _rect.Left, _rect.Top, Math.Max(1, _rect.Width), Math.Max(1, _rect.Height),
            IntPtr.Zero, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        if (Hwnd == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateWindowEx (vetro)");

        SetDwm(Hwnd, DWMWA_TRANSITIONS_FORCEDISABLED, 1);
        SetDwm(Hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, 1);
        SetDwm(Hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DONOTROUND);
        SetDwm(Hwnd, DWMWA_BORDER_COLOR, DWMWA_COLOR_NONE);

        // Start with an empty region so nothing shows before the first shape arrives.
        SetWindowRgn(Hwnd, CreateRectRgn(0, 0, 0, 0), false);

        // Keep the Z order right when another window comes to the front (the island re-asserts
        // TOPMOST then; we follow it just after). Event driven: nothing runs at rest.
        _winEvent = OnWinEvent;
        _hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _winEvent, 0, 0, WINEVENT_OUTOFCONTEXT);
    }

    /// <summary>Fallback when Windows.UI.Composition is not available: DWM acrylic on the whole
    /// window (both kinds ignore the window region on current builds, and the system backdrop is
    /// a flat grey on never-activated windows, so they are only a last resort).</summary>
    public BackdropMaterial ApplyAcrylic(uint win10TintAbgr)
    {
        string? force = Environment.GetEnvironmentVariable("ISOLA_GLASS_MATERIAL")?.Trim().ToLowerInvariant();
        bool useSystem = HasSystemBackdrop && force == "system";
        if (useSystem)
        {
            var m = new MARGINS(-1);
            DwmExtendFrameIntoClientArea(Hwnd, ref m);
            if (SetDwm(Hwnd, DWMWA_SYSTEMBACKDROP_TYPE, DWMSBT_TRANSIENTWINDOW) == 0)
            {
                Material = BackdropMaterial.SystemAcrylic;
                return Material;
            }
            Log.Warn("DWMWA_SYSTEMBACKDROP_TYPE rifiutato: uso l'acrylic di Windows 10");
            var none = new MARGINS(0);
            DwmExtendFrameIntoClientArea(Hwnd, ref none);
        }
        Material = SetAccent(Hwnd, AccentState.EnableAcrylicBlurBehind, win10TintAbgr)
            ? BackdropMaterial.AccentAcrylic
            : BackdropMaterial.None;
        if (Material == BackdropMaterial.None) Log.Warn("Acrylic non disponibile su questo sistema");
        return Material;
    }

    /// <summary>Follows the island: position, Z order, visibility and outline.</summary>
    public void Update(in IslandShapeInfo shape)
    {
        if (_disposed || Hwnd == IntPtr.Zero) return;

        bool visible = shape.IsVisible && IsWindowVisible(_island) && shape.BodyBounds.Width >= 1 && shape.BodyBounds.Height >= 1;
        if (!visible)
        {
            Hide();
            return;
        }

        bool moved = false;
        if (GetWindowRect(_island, out var r) &&
            (r.Left != _rect.Left || r.Top != _rect.Top || r.Width != _rect.Width || r.Height != _rect.Height))
        {
            _rect = r;
            moved = true;
            SetWindowPos(Hwnd, _island, r.Left, r.Top, r.Width, r.Height, SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        }

        var o = ShapeOutline.From(shape, _rect.Left, _rect.Top);
        SetRegion(o);

        if (!_shown)
        {
            _shown = true;
            SetWindowPos(Hwnd, _island, _rect.Left, _rect.Top, _rect.Width, _rect.Height,
                SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
        }
        else EnsureBelowIsland();

        if (moved) Moved?.Invoke(_rect);
    }

    public void Hide()
    {
        if (!_shown) return;
        _shown = false;
        ShowWindow(Hwnd, SW_HIDE);
    }

    private void SetRegion(in ShapeOutline o)
    {
        double g = RegionGrow;
        var key = ((int)Math.Round(o.X0 * 4), (int)Math.Round(o.Y0 * 4), (int)Math.Round(o.X1 * 4), (int)Math.Round(o.Y1 * 4),
            (int)Math.Round(o.TopRadius * 4), (int)Math.Round(o.Flare * 4), (int)Math.Round(o.BottomRadius * 4), (int)Math.Round(g * 4));
        if (key == _regionKey) return;
        _regionKey = key;

        IntPtr rgn;
        if (o.IsEmpty) rgn = CreateRectRgn(0, 0, 0, 0);
        else
        {
            var pts = o.ToPolygon(g);
            rgn = CreatePolygonRgn(pts, pts.Length, WINDING);
        }
        if (rgn == IntPtr.Zero) return;
        // The system owns the region from here on (do not delete it). No redraw: the window
        // never changes size, its (black = transparent) surface is already painted.
        if (SetWindowRgn(Hwnd, rgn, false) == 0)
        {
            DeleteObject(rgn);
            Log.Warn("Vetro: SetWindowRgn non riuscito");
        }
    }

    /// <summary>Keeps the backdrop directly under the island (cheap check, fixes only if needed).</summary>
    public void EnsureBelowIsland()
    {
        if (!_shown || Hwnd == IntPtr.Zero) return;
        if (GetWindow(_island, GW_HWNDNEXT) == Hwnd) return;
        SetWindowPos(Hwnd, _island, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }

    private void OnWinEvent(IntPtr hook, uint type, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (_disposed) return;
        _dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            try { EnsureBelowIsland(); }
            catch (Exception ex) { Log.Error("Vetro: ordine delle finestre", ex); }
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_hook != IntPtr.Zero) UnhookWinEvent(_hook);
        _hook = IntPtr.Zero;
        if (Hwnd != IntPtr.Zero) DestroyWindow(Hwnd);
        Hwnd = IntPtr.Zero;
    }

    // ---- Window class --------------------------------------------------------------------

    private static void EnsureClass()
    {
        if (s_registered) return;
        s_proc = StaticWndProc;
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            style = 0,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(s_proc),
            hInstance = GetModuleHandle(null),
            hbrBackground = GetStockObject(BLACK_BRUSH),
            lpszClassName = ClassName,
        };
        if (RegisterClassEx(ref wc) == 0)
        {
            int err = Marshal.GetLastWin32Error();
            if (err != 1410) throw new Win32Exception(err, "RegisterClassEx (vetro)"); // 1410 = already registered
        }
        s_registered = true;
    }

    private static IntPtr StaticWndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_NCHITTEST:
                return new IntPtr(HTTRANSPARENT);
            case WM_MOUSEACTIVATE:
                return new IntPtr(MA_NOACTIVATE);
            case WM_NCACTIVATE:
                // Always draw as "active": the system backdrop would otherwise fall back to a
                // flat colour, and this window is never activated.
                return DefWindowProc(hwnd, msg, new IntPtr(1), lParam);
            case WM_ERASEBKGND:
                if (GetClientRect(hwnd, out var rc)) FillRect(wParam, ref rc, GetStockObject(BLACK_BRUSH));
                return new IntPtr(1);
            case WM_PAINT:
            {
                var hdc = BeginPaint(hwnd, out var ps);
                if (hdc != IntPtr.Zero && GetClientRect(hwnd, out var r)) FillRect(hdc, ref r, GetStockObject(BLACK_BRUSH));
                EndPaint(hwnd, ref ps);
                return IntPtr.Zero;
            }
            case WM_DPICHANGED:
                return IntPtr.Zero; // positioned in physical pixels by Update()
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }
}
