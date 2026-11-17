using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using static Isola.Modules.Widgets.NativeDesktop;

namespace Isola.Modules.Widgets;

/// <summary>A widget "pinned" on the desktop: borderless, transparent, never activated, clicks pass
/// through, always at the bottom of the z-order. While "Modifica posizione" is on it shows a frame and
/// can be dragged.
///
/// Win+D: the window is owned by the shell's desktop window (Progman). Owned windows always stay
/// above their owner, and "show desktop" keeps windows owned by the desktop on screen, so the widget
/// survives Win+D without being re-parented into WorkerW (whose layout changed in Windows 11 24H2).
/// HWND_BOTTOM keeps it under every normal window and is re-asserted on every z-order change.
/// Verified on Windows 11 (26200): survives Win+D and restart. Side effect: being above Progman, the
/// widget is drawn over the desktop icons (not between wallpaper and icons as WorkerW parenting would).</summary>
internal sealed class DesktopWidgetWindow : Window
{
    private readonly Border _frame;
    private readonly TextBlock _hint;
    private IntPtr _hwnd;
    private bool _editing;

    /// <summary>Raised after the user dragged the widget: (x, top) in DIP, where x is the left edge,
    /// or the horizontal centre when <see cref="CenterX"/> is used.</summary>
    public event Action<double, double>? Moved;

    /// <summary>When set, the window stays horizontally centred on this x (DIP) whatever its width
    /// (the Day clock: "MARTEDÌ" and "SABATO" have different widths).</summary>
    public double? CenterX { get; set; }

    public DesktopWidgetWindow(FrameworkElement content, string title)
    {
        Title = title;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.Manual;
        UseLayoutRounding = true;
        Focusable = false;

        _hint = new TextBlock
        {
            Text = "Trascina per spostare",
            FontSize = 11,
            Foreground = Brushes.White,
            Opacity = 0.85,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -24, 0, 0),
            Visibility = Visibility.Collapsed,
        };
        _hint.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Text");

        var grid = new Grid();
        grid.Children.Add(content);
        grid.Children.Add(_hint);
        _frame = new Border
        {
            Child = grid,
            Padding = new Thickness(18, 30, 18, 14), // room for the hint above the content
            BorderThickness = new Thickness(1.5),
            CornerRadius = new CornerRadius(16),
            BorderBrush = Brushes.Transparent,
            Background = Brushes.Transparent,
        };
        Content = _frame;

        SourceInitialized += OnSourceInitialized;
        MouseLeftButtonDown += OnMouseDown;
        SizeChanged += (_, _) => { if (CenterX is { } cx) Left = cx - ActualWidth / 2; };
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        var src = HwndSource.FromHwnd(_hwnd);
        src?.AddHook(WndProc);

        // Owner = the desktop (Progman): survives Win+D, never above normal windows.
        var shell = GetShellWindow();
        if (shell != IntPtr.Zero) SetWindowLongPtr(_hwnd, GWLP_HWNDPARENT, shell);

        ApplyStyles();
        SendToBottom();
    }

    public void SendToBottom()
    {
        if (_hwnd == IntPtr.Zero) return;
        SetWindowPos(_hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }

    public bool Editing
    {
        get => _editing;
        set
        {
            if (_editing == value) return;
            _editing = value;
            _frame.Background = value ? new SolidColorBrush(Color.FromArgb(0x40, 0x10, 0x10, 0x14)) : Brushes.Transparent;
            _frame.BorderBrush = value ? new SolidColorBrush(Color.FromArgb(0xCC, 0x0A, 0x84, 0xFF)) : Brushes.Transparent;
            _hint.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            Cursor = value ? Cursors.SizeAll : null;
            ApplyStyles();
        }
    }

    private void ApplyStyles()
    {
        if (_hwnd == IntPtr.Zero) return;
        long ex = ExStyle(_hwnd) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED;
        ex &= ~WS_EX_APPWINDOW;
        ex = _editing ? ex & ~WS_EX_TRANSPARENT : ex | WS_EX_TRANSPARENT;
        SetExStyle(_hwnd, ex);
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!_editing) return;
        try { DragMove(); } catch (InvalidOperationException) { return; }
        if (CenterX != null) CenterX = Left + ActualWidth / 2;
        Moved?.Invoke(CenterX ?? Left, Top);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case WM_WINDOWPOSCHANGING:
            {
                // Whatever moves us in the z-order, we go back to the bottom.
                var pos = Marshal.PtrToStructure<WINDOWPOS>(lParam);
                if ((pos.flags & SWP_NOZORDER) == 0)
                {
                    pos.hwndInsertAfter = HWND_BOTTOM;
                    Marshal.StructureToPtr(pos, lParam, false);
                }
                break;
            }
            case WM_MOUSEACTIVATE:
                handled = true;
                return new IntPtr(MA_NOACTIVATE);
            case WM_SYSCOMMAND:
                // Win+D / "minimize all" must not minimize us.
                if ((wParam.ToInt64() & 0xFFF0) == SC_MINIMIZE) { handled = true; return IntPtr.Zero; }
                break;
        }
        return IntPtr.Zero;
    }
}
