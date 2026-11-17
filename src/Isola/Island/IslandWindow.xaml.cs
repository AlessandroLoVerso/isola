using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Isola.Core;
using Isola.Settings;
using Microsoft.Win32;
using static Isola.Native.NativeMethods;

namespace Isola.Island;

/// <summary>The island: a borderless, transparent, topmost, never-activated window sized to the
/// open card. Only the shape is painted, so the rest of the window lets clicks through.</summary>
public partial class IslandWindow : Window, IIslandSurface, IIslandBackdropSite
{
    private enum Mode { Closed, Open, Peek, Strip, Hidden }

    // ---- Layout (DIP) --------------------------------------------------------------------
    private const double CardW = 460, CardH = 250;
    private const double FlareRoom = 12, SidePad = 12, BottomPad = 14;
    private const double NotchFlare = 10, StripFlare = 8;
    private static readonly double WinW = CardW + 2 * (FlareRoom + SidePad);
    private static readonly double WinH = GlobalSettings.MaxEdgeOffset + CardH + BottomPad;

    private static readonly TimeSpan OpenDelay = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan CloseDelay = TimeSpan.FromMilliseconds(350);
    private static readonly TimeSpan LingerDelay = TimeSpan.FromSeconds(4);
    private const double RestTolerance = 6; // DIP the pointer may drift while "resting"

    private static readonly string[] ShellClasses =
    {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd",
        "MultitaskingViewFrame", "XamlExplorerHostIslandWindow", "ForegroundStaging", "Windows.UI.Core.CoreWindow",
    };

    private readonly GlobalSettingsStore _settings;
    private readonly ModuleManager _modules;

    private readonly Spring _w, _h, _rb, _rt, _y;
    private readonly SpringAnimator _anim;

    private readonly DispatcherTimer _openTimer, _closeTimer, _peekTimer, _fullscreenDebounce, _defaultFaceTimer;
    private readonly ForegroundWatcher _foreground = new();
    private readonly Dictionary<UIElement, bool> _layerShown = new();
    private readonly Dictionary<string, (RadioButton Button, TextBlock Label)> _tabs = new();

    private IntPtr _hwnd;
    private HwndSource? _source;
    private Mode _mode = Mode.Closed;
    private IslandShape _shape;
    private bool _fullscreen;
    private bool _keyboardMode;
    private IntPtr _focusReturnHwnd;
    private bool _allowClose;
    private bool _repositioning;
    private Point _restAnchor;
    private int _originX, _originY;
    private Geometry _geometry = Geometry.Empty;
    private IslandOutline _outline;

    private ModuleEntry? _faceOwner, _stripOwner, _peekOwner;
    private int _facePriority;
    private bool _tabTips = true;
    private Point _openAnchor;
    private readonly (double W, double H)[] _clipHistory = new (double, double)[4];
    private int _clipCount;
    private string? _selectedTab;
    private TextBlock? _defaultFaceTime;
    private FrameworkElement? _defaultFace;
    private EventHandler<IslandShapeInfo>? _shapeChanged;

    public IslandWindow(GlobalSettingsStore settings, ModuleManager modules)
    {
        _settings = settings;
        _modules = modules;
        _shape = settings.Current.Shape;

        InitializeComponent();
        Width = WinW;
        Height = WinH;

        var t = TargetFor(Mode.Closed);
        _w = new Spring(t.W);
        _h = new Spring(t.H);
        _rb = new Spring(t.Rb);
        _rt = new Spring(t.Rt);
        _y = new Spring(t.Y);
        _anim = new SpringAnimator(_w, _h, _rb, _rt, _y);
        _anim.Frame += OnFrame;

        _openTimer = NewTimer(OpenDelay, OnOpenTimer);
        _closeTimer = NewTimer(CloseDelay, OnCloseTimer);
        _peekTimer = NewTimer(TimeSpan.FromSeconds(3), OnPeekTimer);
        _fullscreenDebounce = NewTimer(TimeSpan.FromMilliseconds(150), (sender, _) =>
        {
            ((DispatcherTimer)sender!).Stop();
            EvaluateFullscreen(_foreground.Current);
        });
        _defaultFaceTimer = NewTimer(TimeSpan.FromSeconds(60), (_, _) => UpdateDefaultFace());

        foreach (var layer in new UIElement[] { FaceLayer, PeekLayer, StripLayer, CardLayer })
            _layerShown[layer] = layer == FaceLayer;

        SourceInitialized += OnSourceInitialized;
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(DispatcherPriority.Normal, Reposition);
        Stage.SizeChanged += (_, _) => OnFrame();
        Deactivated += OnDeactivated;
        PreviewKeyDown += OnPreviewKeyDown;
        SettingsButton.Click += (_, _) => SettingsRequested?.Invoke(this, EventArgs.Empty);
        TabScroller.PreviewMouseWheel += (_, e) =>
        {
            TabScroller.ScrollToHorizontalOffset(TabScroller.HorizontalOffset - e.Delta / 3.0);
            e.Handled = true;
        };
        _modules.Changed += (_, _) => OnModulesChanged();
        _settings.Changed += (_, _) => ApplySettings();
    }

    /// <summary>The gear button in the card was clicked.</summary>
    public event EventHandler? SettingsRequested;

    public IntPtr Hwnd => _hwnd;

    public bool IsFullscreenAppActive => _fullscreen;

    // =====================================================================================
    // Window setup, position, DPI
    // =====================================================================================

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        _source = HwndSource.FromHwnd(_hwnd);
        _source?.AddHook(WndProc);

        SetExStyle(_hwnd, GetExStyle(_hwnd) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);

        ThemeManager.Initialize(this);
        Reposition();
        RefreshDefaultFace();
        OnFrame();

        _foreground.ForegroundChanged += OnForegroundChanged;
        _foreground.ForegroundMoved += _ =>
        {
            _fullscreenDebounce.Stop();
            _fullscreenDebounce.Start();
        };
        _foreground.Start();
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;

        Dispatcher.BeginInvoke(DispatcherPriority.Background, () => EvaluateFullscreen(GetForegroundWindow()));
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        try
        {
            if (msg == WM_MOUSEACTIVATE && !_keyboardMode)
            {
                handled = true;
                return new IntPtr(MA_NOACTIVATE);
            }
            if (msg == WM_TASKBARCREATED && WM_TASKBARCREATED != 0)
            {
                // explorer.exe restarted: the new taskbar went on top of the topmost band, and the
                // work area / monitors may have changed with it. (The tray icon re-adds itself:
                // WinForms' NotifyIcon handles TaskbarCreated.) Modules see the message too.
                Log.Info("Barra delle applicazioni ricreata (explorer riavviato)");
                Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
                {
                    Reposition();
                    ReassertTopmost();
                    EvaluateFullscreen(GetForegroundWindow());
                });
            }
            if (_modules.DispatchMessage(msg, wParam, lParam)) handled = true;
        }
        catch (Exception ex)
        {
            Log.Error("Errore nella WndProc dell'isola", ex);
        }
        return IntPtr.Zero;
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e)
        => Dispatcher.BeginInvoke(DispatcherPriority.Normal, () =>
        {
            Reposition();
            EvaluateFullscreen(GetForegroundWindow());
        });

    /// <summary>Centres the window at the top of the chosen monitor, in physical pixels,
    /// using that monitor's DPI (WPF follows with WM_DPICHANGED; DpiChanged re-runs this).</summary>
    private void Reposition()
    {
        if (_hwnd == IntPtr.Zero || _repositioning) return;
        _repositioning = true;
        try
        {
            var mon = MonitorService.Resolve(_settings.Current.Monitor);
            int w = (int)Math.Ceiling(WinW * mon.Scale);
            int h = (int)Math.Ceiling(WinH * mon.Scale);
            int x = mon.Left + (mon.Width - w) / 2;
            int y = mon.Top;
            _originX = x;
            _originY = y;
            SetWindowPos(_hwnd, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
        }
        catch (Exception ex)
        {
            Log.Error("Posizionamento dell'isola non riuscito", ex);
        }
        finally
        {
            _repositioning = false;
        }
        OnFrame();
    }

    private void ReassertTopmost()
    {
        if (_hwnd != IntPtr.Zero)
            SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
    }

    private void ApplySettings()
    {
        var s = _settings.Current;
        _shape = s.Shape;
        ThemeManager.Apply(s.Theme);
        Reposition();
        EvaluateFullscreen(GetForegroundWindow());
        RefreshStrip();
        Retarget(animate: true);
    }

    // =====================================================================================
    // Shape and animation
    // =====================================================================================

    private (double W, double H, double Rb, double Rt, double Y) TargetFor(Mode m)
    {
        bool notch = _shape == IslandShape.Notch;
        double off = Math.Clamp(_settings.Current.EdgeOffset, 0, GlobalSettings.MaxEdgeOffset);
        return m switch
        {
            Mode.Open => notch ? (CardW, CardH, 30, -NotchFlare, 0) : (CardW, CardH, 32, 32, off),
            Mode.Peek => notch ? (330, 46, 22, -NotchFlare, 0) : (330, 48, 24, 24, off),
            Mode.Strip or Mode.Hidden => (300, 24, 11, -StripFlare, 0),
            _ => notch ? (190, 32, 14, -NotchFlare, 0) : (190, 34, 17, 17, off),
        };
    }

    private void SetMode(Mode m)
    {
        var prev = _mode;
        _mode = m;
        if (m != Mode.Peek) _peekTimer.Stop();
        if (m != Mode.Open) EndKeyboardMode(restoreFocus: true);

        UpdateLayers();

        if (m == Mode.Hidden)
        {
            Retarget(animate: false);
            if (IsVisible) Hide();
            RaiseShapeChanged();
            return;
        }

        if (!IsVisible)
        {
            Show();
            ReassertTopmost();
        }
        Retarget(animate: prev != m || _anim.IsRunning);
    }

    private void Retarget(bool animate)
    {
        var t = TargetFor(_mode);
        _w.Target = t.W;
        _h.Target = t.H;
        _rb.Target = t.Rb;
        _rt.Target = t.Rt;
        _y.Target = t.Y;

        bool expanding = _mode is Mode.Open or Mode.Peek;
        foreach (var s in new[] { _w, _h, _rb, _rt, _y })
        {
            s.Response = expanding ? 0.50 : 0.40;
            s.Damping = expanding ? 0.74 : 0.90;
        }
        if (animate && _mode != Mode.Hidden) _anim.Kick();
        else _anim.SnapAll();
    }

    private void OnFrame()
    {
        double cx = Stage.ActualWidth > 0 ? Stage.ActualWidth / 2 : WinW / 2;
        _outline = new IslandOutline(cx, _y.Value, _w.Value, _h.Value, _rb.Value, _rt.Value);
        _geometry = _outline.Build();
        ShapePath.Data = _geometry;
        ContentLayer.Clip = ContentClip(cx);
        if (EdgePath.Stroke != null) EdgePath.Data = _geometry;

        // Each content layer is laid out at the size of ITS state, anchored to the top centre of
        // the moving shape; the clip reveals it. Layers that are fading out stay where they are,
        // so their content never slides around while the shape morphs.
        double y0 = _y.Value;
        PlaceLayer(FaceLayer, Mode.Closed, cx, y0);
        PlaceLayer(PeekLayer, Mode.Peek, cx, y0);
        PlaceLayer(StripLayer, Mode.Strip, cx, y0);
        if (_layerShown[CardLayer])
        {
            Canvas.SetLeft(CardLayer, cx - CardW / 2);
            Canvas.SetTop(CardLayer, y0);
        }

        RaiseShapeChanged();
    }

    /// <summary>With a glass theme the frosted backdrop is a separate window that reaches the screen
    /// a frame or two apart from the island, so while the island grows, text clipped to the
    /// current outline could stick out of the glass for a frame. Clip the content to the smallest
    /// outline of the last few frames instead (the glass is never smaller than that); at rest
    /// (and with the solid themes) it is the outline itself.</summary>
    private Geometry ContentClip(double cx)
    {
        if (_shapeChanged == null || !_anim.IsRunning)
        {
            _clipCount = 0;
            return _geometry;
        }
        _clipHistory[_clipCount++ % _clipHistory.Length] = (_outline.Width, _outline.Height);
        double w = _outline.Width, h = _outline.Height;
        for (int i = 0; i < Math.Min(_clipCount, _clipHistory.Length); i++)
        {
            w = Math.Min(w, _clipHistory[i].W);
            h = Math.Min(h, _clipHistory[i].H);
        }
        if (w >= _outline.Width - 0.01 && h >= _outline.Height - 0.01) return _geometry;
        return (_outline with { Width = w, Height = h }).Build();
    }

    private void PlaceLayer(FrameworkElement layer, Mode state, double cx, double y0)
    {
        if (!_layerShown[layer]) return;
        var t = TargetFor(state);
        Canvas.SetLeft(layer, cx - t.W / 2);
        Canvas.SetTop(layer, y0);
        if (layer.Width != t.W) layer.Width = t.W;
        if (layer.Height != t.H) layer.Height = t.H;
    }

    private void UpdateLayers()
    {
        ShowLayer(FaceLayer, _mode == Mode.Closed, delayMs: 70);
        ShowLayer(PeekLayer, _mode == Mode.Peek, delayMs: 80);
        ShowLayer(StripLayer, _mode == Mode.Strip, delayMs: 60);
        ShowLayer(CardLayer, _mode == Mode.Open, delayMs: 60);
    }

    private void ShowLayer(FrameworkElement layer, bool show, double delayMs)
    {
        if (_layerShown[layer] == show) return;
        _layerShown[layer] = show;
        layer.IsHitTestVisible = show;

        var anim = new DoubleAnimation
        {
            To = show ? 1 : 0,
            Duration = TimeSpan.FromMilliseconds(show ? 200 : 110),
            BeginTime = show ? TimeSpan.FromMilliseconds(delayMs) : TimeSpan.Zero,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        if (show)
        {
            layer.Visibility = Visibility.Visible;
            OnFrame(); // place it before it becomes visible
        }
        else
        {
            anim.Completed += (_, _) =>
            {
                if (!_layerShown[layer]) layer.Visibility = Visibility.Collapsed;
            };
        }
        layer.BeginAnimation(OpacityProperty, anim, HandoffBehavior.SnapshotAndReplace);
    }

    private static void FadeIn(UIElement el)
    {
        el.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        });
    }

    // =====================================================================================
    // Pointer: open after resting 250 ms, close 350 ms after leaving
    // =====================================================================================

    protected override void OnMouseEnter(MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        _closeTimer.Stop();
        if (_mode != Mode.Open) StartRest(e.GetPosition(Stage));
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_mode == Mode.Open)
        {
            if (_closeTimer.Interval != LingerDelay) _closeTimer.Stop();
            if (!_tabTips && (e.GetPosition(Stage) - _openAnchor).Length > 8) SetTabTips(true);
            return;
        }
        var p = e.GetPosition(Stage);
        if (!_openTimer.IsEnabled || (p - _restAnchor).Length > RestTolerance) StartRest(p);
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _openTimer.Stop();
        if (_mode == Mode.Open && !_keyboardMode)
        {
            _closeTimer.Stop();
            _closeTimer.Interval = CloseDelay;
            _closeTimer.Start();
        }
    }

    private void StartRest(Point p)
    {
        _restAnchor = p;
        _openTimer.Stop();
        _openTimer.Start();
    }

    private void OnOpenTimer(object? sender, EventArgs e)
    {
        _openTimer.Stop();
        if (_mode != Mode.Open && CursorOverShape()) Open(_peekOwner?.Card != null && _mode == Mode.Peek ? _peekOwner.Id : null);
    }

    private void OnCloseTimer(object? sender, EventArgs e)
    {
        _closeTimer.Stop();
        _closeTimer.Interval = CloseDelay;
        if (_mode != Mode.Open || _keyboardMode) return;
        if (Mouse.Captured != null || CursorOverShape())
        {
            if (Mouse.Captured != null) _closeTimer.Start(); // e.g. dragging a slider out of the card
            return;
        }
        Close(animate: true);
    }

    private bool CursorOverShape()
    {
        if (!IsVisible || PresentationSource.FromVisual(Stage) == null) return false;
        if (!GetCursorPos(out var pt)) return false;
        var p = Stage.PointFromScreen(new Point(pt.X, pt.Y));
        return _geometry.FillContains(p);
    }

    private void Open(string? tabId)
    {
        // Default tab: the module showing something meaningful in the pill (music, an agent,
        // the mute...), else the last tab used. The clock/weather faces are just ambient.
        tabId ??= _faceOwner is { IsRunning: true, Card: not null } && _facePriority >= 10 ? _faceOwner.Id : null;
        if (tabId != null) SelectTab(tabId);
        _closeTimer.Stop();
        // The card opens under a resting pointer: no tab tooltip until the pointer moves.
        _openAnchor = Mouse.GetPosition(Stage);
        SetTabTips(false);
        SetMode(Mode.Open);
    }

    private void SetTabTips(bool on)
    {
        _tabTips = on;
        foreach (var tab in _tabs.Values) ToolTipService.SetIsEnabled(tab.Button, on);
    }

    private void Close(bool animate)
    {
        _closeTimer.Stop();
        SetMode(ComputeBaseMode());
        if (!animate) _anim.SnapAll();
    }

    private void OnPeekTimer(object? sender, EventArgs e)
    {
        _peekTimer.Stop();
        if (_mode != Mode.Peek) return;
        if (CursorOverShape())
        {
            _peekTimer.Interval = TimeSpan.FromSeconds(1); // keep it while the user looks at it
            _peekTimer.Start();
            return;
        }
        SetMode(ComputeBaseMode());
    }

    // =====================================================================================
    // Keyboard focus (text input inside the card)
    // =====================================================================================

    public void RequestKeyboardFocus()
    {
        if (_hwnd == IntPtr.Zero || _mode != Mode.Open) return;
        if (!_keyboardMode)
        {
            _keyboardMode = true;
            var fg = GetForegroundWindow();
            _focusReturnHwnd = fg != _hwnd ? fg : IntPtr.Zero;
            SetExStyle(_hwnd, GetExStyle(_hwnd) & ~WS_EX_NOACTIVATE);
        }
        _closeTimer.Stop();
        Activate();
        SetForegroundWindow(_hwnd);
    }

    private void EndKeyboardMode(bool restoreFocus)
    {
        if (!_keyboardMode) return;
        _keyboardMode = false;
        SetExStyle(_hwnd, GetExStyle(_hwnd) | WS_EX_NOACTIVATE);
        Keyboard.ClearFocus();
        if (restoreFocus && GetForegroundWindow() == _hwnd && _focusReturnHwnd != IntPtr.Zero)
            SetForegroundWindow(_focusReturnHwnd);
        _focusReturnHwnd = IntPtr.Zero;
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        if (!_keyboardMode) return;
        EndKeyboardMode(restoreFocus: false);
        if (_mode == Mode.Open && !CursorOverShape()) Close(animate: true);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && _mode == Mode.Open)
        {
            Close(animate: true);
            e.Handled = true;
        }
    }

    // =====================================================================================
    // Fullscreen + topmost
    // =====================================================================================

    private void OnForegroundChanged(IntPtr fg)
    {
        ReassertTopmost();
        EvaluateFullscreen(fg);
    }

    private void EvaluateFullscreen(IntPtr fg)
    {
        bool fs;
        try { fs = IsFullscreenWindow(fg); }
        catch (Exception ex)
        {
            Log.Error("Controllo dello schermo intero non riuscito", ex);
            return;
        }
        if (fs == _fullscreen) return;
        _fullscreen = fs;
        Log.Info(fs ? "App a schermo intero in primo piano" : "Fine schermo intero");
        _modules.RaiseFullscreenChanged();
        RefreshStrip();
        ApplyBaseMode();
    }

    private bool IsFullscreenWindow(IntPtr fg)
    {
        if (fg == IntPtr.Zero || _hwnd == IntPtr.Zero) return false;
        GetWindowThreadProcessId(fg, out uint pid);
        if (pid == (uint)Environment.ProcessId) return _fullscreen; // our own windows: no change
        if (fg == GetShellWindow() || fg == GetDesktopWindow()) return false;
        if (ShellClasses.Contains(GetClassName(fg))) return false;
        if (!IsWindowVisible(fg) || IsCloaked(fg)) return false;
        if (!GetWindowRect(fg, out var r)) return false;

        var mon = MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST);
        if (mon != MonitorFromWindow(_hwnd, MONITOR_DEFAULTTONEAREST)) return false;
        if (MonitorService.MonitorRectOf(mon) is not { } m) return false;

        bool covers = r.Left <= m.Left && r.Top <= m.Top && r.Right >= m.Right && r.Bottom >= m.Bottom;
        if (!covers) return false;

        // A maximized captioned window can overhang the monitor (auto-hide taskbar): not fullscreen.
        long style = GetWindowLongPtr(fg, GWL_STYLE).ToInt64();
        if (IsZoomed(fg) && (style & WS_CAPTION) == WS_CAPTION) return false;
        return true;
    }

    private Mode ComputeBaseMode()
    {
        if (!_fullscreen) return Mode.Closed;
        if (_settings.Current.Fullscreen == FullscreenBehavior.Nascondi) return Mode.Hidden;
        return _stripOwner != null && StripLayer.Child != null ? Mode.Strip : Mode.Hidden;
    }

    private void ApplyBaseMode()
    {
        if (_mode is Mode.Open or Mode.Peek) return;
        var b = ComputeBaseMode();
        if (b != _mode) SetMode(b);
    }

    // =====================================================================================
    // Faces, strip, peek, tabs
    // =====================================================================================

    public void RefreshRestingFace()
    {
        ModuleEntry? best = null;
        int bestPriority = 0;
        foreach (var e in _modules.Running.ToList())
        {
            if (e.Module is not IRestingFaceProvider p) continue;
            int pr = _modules.Call(e, "RestingPriority", () => p.RestingPriority, 0);
            if (pr > bestPriority && e.IsRunning)
            {
                best = e;
                bestPriority = pr;
            }
        }

        _facePriority = bestPriority;
        if (best != null && (best != _faceOwner || FaceLayer.Child == null || FaceLayer.Child == _defaultFace))
        {
            var provider = (IRestingFaceProvider)best.Module;
            var face = _modules.Call(best, "CreateRestingFace", () => provider.CreateRestingFace(), null);
            if (face != null && best.IsRunning)
            {
                _faceOwner = best;
                SetFace(face);
                _defaultFaceTimer.Stop();
            }
            else best = null;
        }

        if (best == null && (FaceLayer.Child != _defaultFace || _faceOwner != null))
        {
            _faceOwner = null;
            RefreshDefaultFace();
        }

        RefreshStrip();
    }

    private void SetFace(FrameworkElement face)
    {
        FaceLayer.Child = face;
        if (_mode == Mode.Closed) FadeIn(face);
    }

    private void RefreshDefaultFace()
    {
        if (_defaultFace == null)
        {
            _defaultFaceTime = new TextBlock
            {
                FontWeight = FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            var dot = new Ellipse
            {
                Width = 7,
                Height = 7,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            };
            dot.SetResourceReference(Shape.FillProperty, "Isola.Brush.Accent");
            var grid = new Grid();
            grid.Children.Add(_defaultFaceTime);
            grid.Children.Add(dot);
            _defaultFace = grid;
        }
        if (FaceLayer.Child != _defaultFace) SetFace(_defaultFace);
        UpdateDefaultFace();
    }

    private void UpdateDefaultFace()
    {
        if (_defaultFaceTime == null) return;
        var now = DateTime.Now;
        _defaultFaceTime.Text = now.ToString("HH:mm");
        // Tick exactly at the next minute; nothing runs in between.
        _defaultFaceTimer.Stop();
        if (FaceLayer.Child != _defaultFace) return;
        _defaultFaceTimer.Interval = TimeSpan.FromSeconds(60 - now.Second) - TimeSpan.FromMilliseconds(now.Millisecond) + TimeSpan.FromMilliseconds(30);
        _defaultFaceTimer.Start();
    }

    private void RefreshStrip()
    {
        ModuleEntry? owner = null;
        foreach (var e in _modules.Running.ToList())
        {
            if (e.Module is not IStripProvider sp) continue;
            if (_modules.Call(e, "WantsStrip", () => sp.WantsStrip, false) && e.IsRunning)
            {
                owner = e;
                break;
            }
        }

        if (owner != _stripOwner || (owner != null && StripLayer.Child == null))
        {
            FrameworkElement? strip = null;
            if (owner != null)
            {
                var sp = (IStripProvider)owner.Module;
                strip = _modules.Call(owner, "CreateStrip", () => sp.CreateStrip(), null);
                if (strip == null || !owner.IsRunning) owner = null;
            }
            _stripOwner = owner;
            StripLayer.Child = owner != null ? strip : null;
        }
        ApplyBaseMode();
    }

    public void Attention(string moduleId, TimeSpan duration)
    {
        var e = _modules.Find(moduleId);
        if (e == null || !e.IsRunning || _mode == Mode.Open || _hwnd == IntPtr.Zero) return;

        FrameworkElement? content = null;
        if (e.Module is IRestingFaceProvider p)
            content = _modules.Call(e, "CreateRestingFace", () => p.CreateRestingFace(), null);
        if (!e.IsRunning) return;
        content ??= BuildTitleFace(e);

        _peekOwner = e;
        PeekLayer.Child = content;
        if (_mode == Mode.Peek) FadeIn(content);

        if (duration <= TimeSpan.Zero) duration = TimeSpan.FromSeconds(3);
        if (duration > TimeSpan.FromMinutes(5)) duration = TimeSpan.FromMinutes(5);
        _peekTimer.Stop();
        _peekTimer.Interval = duration;

        SetMode(Mode.Peek);
        _peekTimer.Start();
    }

    private FrameworkElement BuildTitleFace(ModuleEntry e)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var glyph = new TextBlock { Text = e.Glyph, FontSize = 15, VerticalAlignment = VerticalAlignment.Center };
        glyph.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        glyph.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Accent");
        panel.Children.Add(glyph);
        panel.Children.Add(new TextBlock
        {
            Text = e.Title,
            Margin = new Thickness(10, 0, 0, 0),
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        return panel;
    }

    public void OpenTab(string moduleId)
    {
        var e = _modules.Find(moduleId);
        if (e == null || !e.IsRunning || e.Card == null || _hwnd == IntPtr.Zero) return;
        Open(e.Id);
        if (!CursorOverShape())
        {
            _closeTimer.Stop();
            _closeTimer.Interval = LingerDelay;
            _closeTimer.Start();
        }
    }

    private void OnModulesChanged()
    {
        if (_faceOwner is { IsRunning: false })
        {
            _faceOwner = null;
            FaceLayer.Child = null;
        }
        if (_stripOwner is { IsRunning: false })
        {
            _stripOwner = null;
            StripLayer.Child = null;
        }
        if (_peekOwner is { IsRunning: false })
        {
            _peekOwner = null;
            if (_mode == Mode.Peek) SetMode(ComputeBaseMode());
            PeekLayer.Child = null;
        }
        RebuildTabs();
        RefreshRestingFace();
    }

    private void RebuildTabs()
    {
        var tabs = _modules.Running.Where(e => e.Card != null).ToList();
        TabStrip.Children.Clear();
        _tabs.Clear();

        foreach (var e in tabs)
        {
            var glyph = new TextBlock { Text = e.Glyph, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
            glyph.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
            var label = new TextBlock
            {
                Text = e.Title,
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(7, 0, 0, 1),
                VerticalAlignment = VerticalAlignment.Center,
            };
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(glyph);
            content.Children.Add(label);

            var button = new RadioButton
            {
                Style = (Style)FindResource("TabButton"),
                GroupName = "isola-tabs",
                Content = content,
            };
            ToolTipService.SetInitialShowDelay(button, 700);
            ToolTipService.SetIsEnabled(button, _tabTips);
            System.Windows.Automation.AutomationProperties.SetName(button, e.Title);
            var id = e.Id;
            button.Checked += (_, _) => SelectTab(id);
            TabStrip.Children.Add(button);
            _tabs[id] = (button, label);
        }

        if (_selectedTab == null || !_tabs.ContainsKey(_selectedTab))
            _selectedTab = tabs.FirstOrDefault()?.Id;
        ShowSelectedCard(force: true);
    }

    private void SelectTab(string id)
    {
        if (!_tabs.ContainsKey(id)) return;
        if (_selectedTab == id && CardHost.Content != null) return;
        _selectedTab = id;
        ShowSelectedCard(force: false);
    }

    private void ShowSelectedCard(bool force)
    {
        var entry = _selectedTab != null ? _modules.Find(_selectedTab) : null;
        var card = entry is { IsRunning: true } ? entry.Card : null;

        foreach (var (id, tab) in _tabs)
        {
            bool sel = id == _selectedTab;
            if (tab.Button.IsChecked != sel) tab.Button.IsChecked = sel;
        }

        if (!ReferenceEquals(CardHost.Content, card) || force)
        {
            CardHost.Content = card;
            if (card != null && !force) FadeIn(CardHost);
        }
        EmptyText.Visibility = card == null ? Visibility.Visible : Visibility.Collapsed;
        UpdateTabCompaction();
    }

    /// <summary>Unselected tabs show the icon only (their name is in the tooltip); the selected
    /// one shows its name too. With all nine modules on this takes ~360 of the 402 DIP available.
    /// With only a few tabs every name fits, so they are all shown.</summary>
    private void UpdateTabCompaction()
    {
        bool roomy = _tabs.Count <= 4;
        foreach (var (id, tab) in _tabs)
        {
            var v = roomy || id == _selectedTab ? Visibility.Visible : Visibility.Collapsed;
            if (tab.Label.Visibility != v) tab.Label.Visibility = v;
            // Tooltip only where the name isn't written (the card opens under a resting pointer).
            tab.Button.ToolTip = v == Visibility.Visible ? null : tab.Label.Text;
        }
        if (_selectedTab != null && _tabs.TryGetValue(_selectedTab, out var sel))
            sel.Button.BringIntoView();
    }

    // =====================================================================================
    // Backdrop site
    // =====================================================================================

    IntPtr IIslandBackdropSite.IslandHwnd => _hwnd;

    IslandShapeInfo IIslandBackdropSite.CurrentShape => ComputeShapeInfo();

    event EventHandler<IslandShapeInfo>? IIslandBackdropSite.ShapeChanged
    {
        add => _shapeChanged += value;
        remove => _shapeChanged -= value;
    }

    void IIslandBackdropSite.SetIslandFill(Brush? fill)
    {
        if (fill == null) ShapePath.SetResourceReference(Shape.FillProperty, "Isola.Brush.Background");
        else ShapePath.Fill = fill;
    }

    void IIslandBackdropSite.SetIslandEdge(Brush? brush, double thickness)
    {
        EdgePath.Stroke = brush;
        EdgePath.StrokeThickness = brush == null ? 0 : 2 * Math.Max(0, thickness); // outer half is clipped away
        EdgePath.Data = brush == null ? null : _geometry;
    }

    private IslandShapeInfo ComputeShapeInfo()
    {
        double s = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var b = _outline.Bounds;
        double w = Math.Max(0, _outline.Width);
        var body = new Rect(_outline.CenterX - w / 2, _outline.Top, w, Math.Max(0, _outline.Height));
        Rect Px(Rect r) => new(_originX + r.X * s, _originY + r.Y * s, r.Width * s, r.Height * s);
        return new IslandShapeInfo(Px(b), Px(body), Math.Max(0, _outline.BottomRadius) * s, _outline.TopCorner * s,
            IsVisible && _mode != Mode.Hidden, s);
    }

    private void RaiseShapeChanged()
    {
        var handler = _shapeChanged;
        if (handler == null) return;
        try { handler(this, ComputeShapeInfo()); }
        catch (Exception ex) { Log.Error("Errore nel backdrop (ShapeChanged)", ex); }
    }

    // =====================================================================================
    // Lifetime
    // =====================================================================================

    public void Shutdown()
    {
        _allowClose = true;
        foreach (var t in new[] { _openTimer, _closeTimer, _peekTimer, _fullscreenDebounce, _defaultFaceTimer }) t.Stop();
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _foreground.Dispose();
        _source?.RemoveHook(WndProc);
        Close();
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!_allowClose) e.Cancel = true; // e.g. Alt+F4 while typing in the card
        base.OnClosing(e);
    }

    private DispatcherTimer NewTimer(TimeSpan interval, EventHandler tick)
    {
        var t = new DispatcherTimer(DispatcherPriority.Normal, Dispatcher) { Interval = interval };
        t.Tick += tick;
        return t;
    }
}
