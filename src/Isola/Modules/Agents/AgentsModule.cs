using System.ComponentModel;
using System.Net;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Isola.Core;

namespace Isola.Modules.Agents;

/// <summary>Tab "Agenti": shows the state of Claude Code sessions, fed by Claude Code hooks that
/// POST their JSON to http://127.0.0.1:47321/agent. The pill lights up while a session waits.</summary>
public sealed class AgentsModule : IIslandModule, IRestingFaceProvider
{
    private const string Prefix = "http://127.0.0.1:47321/";
    private const int MaxBody = 256 * 1024;
    private const int MaxSessions = 32;
    private const int MaxField = 300;
    private static readonly TimeSpan IdleTimeout = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan DoneWindow = TimeSpan.FromSeconds(60);
    private static readonly Brush WorkingBrush = Frozen(0xFF, 0x9F, 0x0A);
    private static readonly Brush DoneBrush = Frozen(0x30, 0xD1, 0x58);

    private readonly Dictionary<string, Session> _sessions = new();
    private readonly FaceViewModel _face = new();
    private IIslandHost? _host;
    private HttpListener? _listener;
    private DispatcherTimer? _timer;
    private StackPanel? _rows;
    private FrameworkElement? _card;
    private string _serverStatus = "Spento";
    private bool _serverOk;
    private int _priority;

    public string Id => "agents";
    public string Title => "Agenti";
    public string Glyph => ""; // robot
    public int Order => 15;
    public bool EnabledByDefault => true;
    public int RestingPriority => _priority;

    // ---------- lifecycle ----------

    public void Start(IIslandHost host)
    {
        _host = host;
        _timer = new DispatcherTimer(DispatcherPriority.Background, host.Dispatcher);
        _timer.Tick += (_, _) => Tick();
        StartServer();
    }

    public void Stop()
    {
        var l = _listener;
        _listener = null;
        try { l?.Close(); } catch { }
        _timer?.Stop();
        _timer = null;
        _sessions.Clear();
        _rows = null;
        _card = null;
        _priority = 0;
        _host = null;
    }

    private void StartServer()
    {
        var l = new HttpListener();
        l.Prefixes.Add(Prefix);
        try
        {
            l.Start();
        }
        catch (Exception ex)
        {
            _serverOk = false;
            _serverStatus = ex is HttpListenerException { ErrorCode: 183 or 32 or 5 }
                ? "Porta 47321 occupata da un altro programma"
                : "Non avviato: " + ex.Message;
            _host?.Log(Id, "Server non avviato su " + Prefix + ": " + ex.Message);
            try { l.Close(); } catch { }
            return;
        }
        _listener = l;
        _serverOk = true;
        _serverStatus = "In ascolto su 127.0.0.1:47321";
        var dispatcher = _host!.Dispatcher;
        _ = Task.Run(() => Loop(l, dispatcher));
    }

    private async Task Loop(HttpListener l, Dispatcher dispatcher)
    {
        while (l.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await l.GetContextAsync().ConfigureAwait(false); }
            catch { break; } // closed
            try
            {
                var req = ctx.Request;
                byte[]? body = null;
                // Only local hook processes (curl): a web page can also reach 127.0.0.1, but a
                // browser always sends Origin (or Sec-Fetch-*) on such a request, curl never does.
                bool ok = req.HttpMethod == "POST" && req.Url?.AbsolutePath.TrimEnd('/') == "/agent"
                          && IPAddress.IsLoopback(req.RemoteEndPoint.Address)
                          && req.Headers["Origin"] == null && req.Headers["Sec-Fetch-Mode"] == null;
                if (ok && req.ContentLength64 <= MaxBody)
                    body = await ReadBody(req.InputStream).ConfigureAwait(false);
                ctx.Response.StatusCode = ok ? 200 : 404;
                ctx.Response.ContentLength64 = 0;
                ctx.Response.Close();
                if (body == null) continue;
                var ev = Parse(body);
                if (ev != null) _ = dispatcher.BeginInvoke(() => { if (_listener == l) Handle(ev); });
            }
            catch (Exception ex)
            {
                try { ctx.Response.Abort(); } catch { }
                try { _host?.Log(Id, "Richiesta ignorata: " + ex.Message); } catch { }
            }
        }
    }

    private static async Task<byte[]?> ReadBody(Stream s)
    {
        var ms = new MemoryStream();
        var buf = new byte[16 * 1024];
        int n;
        while ((n = await s.ReadAsync(buf).ConfigureAwait(false)) > 0)
        {
            ms.Write(buf, 0, n);
            if (ms.Length > MaxBody) return null;
        }
        return ms.ToArray();
    }

    private static HookEvent? Parse(byte[] body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            string Get(string name)
            {
                var s = r.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? "" : "";
                return s.Length > MaxField ? s[..MaxField] : s;
            }
            var ev = new HookEvent(Get("session_id"), Get("cwd"), Get("hook_event_name"), Get("tool_name"), Get("message"));
            return ev.SessionId.Length == 0 || ev.Name.Length == 0 ? null : ev;
        }
        catch { return null; }
    }

    // ---------- state ----------

    private void Handle(HookEvent e)
    {
        if (_host == null) return;
        var now = DateTime.Now;
        if (e.Name == "SessionEnd") { _sessions.Remove(e.SessionId); Refresh(); return; }

        if (!_sessions.TryGetValue(e.SessionId, out var s))
        {
            if (_sessions.Count >= MaxSessions) // keep memory bounded: forget the stalest session
                _sessions.Remove(_sessions.MinBy(p => p.Value.LastEvent).Key);
            _sessions[e.SessionId] = s = new Session { Id = e.SessionId };
        }
        if (e.Cwd.Length > 0) s.Folder = FolderName(e.Cwd);
        var before = s.State;
        switch (e.Name)
        {
            case "UserPromptSubmit":
            case "PostToolUse": s.State = AgentState.Working; s.Detail = "Al lavoro"; break;
            case "PreToolUse": s.State = AgentState.Working; s.Detail = e.Tool.Length > 0 ? "Usa " + e.Tool : "Al lavoro"; break;
            case "Notification": s.State = AgentState.Waiting; s.Detail = e.Message.Length > 0 ? e.Message : "Ti aspetta"; break;
            case "Stop": s.State = AgentState.Done; s.Detail = "Finito"; break;
            default: s.LastEvent = now; Refresh(); return;
        }
        s.LastEvent = now;
        if (s.State != before) s.Since = now;
        Refresh();
        if (s.State == AgentState.Waiting && before != AgentState.Waiting)
            _host.Attention(Id, TimeSpan.FromSeconds(4));
    }

    private void Tick() => Refresh();

    /// <summary>Drops stale sessions, recomputes the pill, redraws the rows and (re)arms the timer.</summary>
    private void Refresh()
    {
        if (_host == null) return;
        var now = DateTime.Now;
        foreach (var id in _sessions.Where(p => now - p.Value.LastEvent > IdleTimeout).Select(p => p.Key).ToList())
            _sessions.Remove(id);

        var waiting = _sessions.Values.Where(s => s.State == AgentState.Waiting).OrderByDescending(s => s.Since).ToList();
        var working = _sessions.Values.Where(s => s.State == AgentState.Working).OrderByDescending(s => s.LastEvent).ToList();
        var done = _sessions.Values.Where(s => s.State == AgentState.Done && now - s.Since < DoneWindow).OrderByDescending(s => s.Since).ToList();

        int priority;
        if (waiting.Count > 0) { priority = 95; _face.Set(FaceMode.Waiting, "Claude ti aspetta", waiting[0].Folder); }
        else if (working.Count > 0) { priority = 30; _face.Set(FaceMode.Working, working[0].Folder, working.Count > 1 ? working.Count.ToString() : ""); }
        else if (done.Count > 0) { priority = 25; _face.Set(FaceMode.Done, "Finito", done[0].Folder); }
        else { priority = 0; _face.Set(FaceMode.None, "", ""); }
        if (priority != _priority) { _priority = priority; _host.RefreshRestingFace(); }

        // The rows are only rebuilt while the card is on screen (IsVisibleChanged refreshes).
        bool cardVisible = _card is { IsVisible: true };
        if (cardVisible) RebuildRows(now);

        // One timer, only while there is something to keep fresh: every second for the "x s ago"
        // in the open card, otherwise just at the next deadline (end of a "Finito" or a session
        // going stale), so nothing ticks while the island rests.
        if (_timer == null) return;
        if (_sessions.Count == 0) { _timer.Stop(); return; }
        var interval = cardVisible ? TimeSpan.FromSeconds(1) : TimeSpan.FromHours(1);
        foreach (var d in done)
        {
            var left = DoneWindow - (now - d.Since);
            if (left > TimeSpan.Zero && left < interval) interval = left;
        }
        foreach (var x in _sessions.Values)
        {
            var left = IdleTimeout - (now - x.LastEvent);
            if (left < interval) interval = left;
        }
        interval += TimeSpan.FromMilliseconds(100);
        if (interval < TimeSpan.FromMilliseconds(200)) interval = TimeSpan.FromMilliseconds(200);
        if (!_timer.IsEnabled || _timer.Interval != interval) { _timer.Stop(); _timer.Interval = interval; _timer.Start(); }
    }

    private static string FolderName(string cwd)
    {
        var t = cwd.TrimEnd('\\', '/');
        int i = t.LastIndexOfAny(new[] { '\\', '/' });
        var name = i >= 0 ? t[(i + 1)..] : t;
        return name.Length > 0 ? name : cwd;
    }

    private static string Elapsed(TimeSpan t) =>
        t.TotalSeconds < 60 ? $"{Math.Max(0, (int)t.TotalSeconds)} s"
        : t.TotalMinutes < 60 ? $"{(int)t.TotalMinutes} min"
        : $"{(int)t.TotalHours} h";

    // ---------- card ----------

    public FrameworkElement? CreateCard()
    {
        _rows = new StackPanel();
        var scroll = new ScrollViewer
        {
            Content = _rows,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Margin = new Thickness(0, 2, 0, 2),
        };
        _card = scroll;
        scroll.IsVisibleChanged += (_, _) => Refresh();
        RebuildRows(DateTime.Now);
        return scroll;
    }

    private void RebuildRows(DateTime now)
    {
        if (_rows == null) return;
        _rows.Children.Clear();
        if (_sessions.Count == 0)
        {
            var title = Txt("Nessuna sessione di Claude Code", 14, FontWeights.SemiBold);
            var hint = Txt(_serverOk
                    ? "Quando un agente lavora o ti aspetta, compare qui. Per collegarlo: Impostazioni › Agenti."
                    : "Server spento: " + _serverStatus, 12, FontWeights.Normal);
            hint.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
            hint.TextWrapping = TextWrapping.Wrap;
            hint.Margin = new Thickness(0, 4, 0, 0);
            var glyph = new TextBlock { Text = Glyph, FontSize = 28, Margin = new Thickness(0, 0, 0, 10) };
            glyph.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
            glyph.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
            _rows.Children.Add(new StackPanel
            {
                Margin = new Thickness(6, 30, 40, 0),
                Children = { glyph, title, hint },
            });
            return;
        }
        var order = _sessions.Values
            .OrderBy(s => s.State switch { AgentState.Waiting => 0, AgentState.Working => 1, _ => 2 })
            .ThenByDescending(s => s.LastEvent);
        foreach (var s in order) _rows.Children.Add(Row(s, now));
    }

    private FrameworkElement Row(Session s, DateTime now)
    {
        var dot = new Ellipse { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 12, 0) };
        if (s.State == AgentState.Waiting) dot.SetResourceReference(Shape.FillProperty, "Isola.Brush.Accent");
        else dot.Fill = s.State == AgentState.Working ? WorkingBrush : DoneBrush;

        var name = Txt(s.Folder, 13, FontWeights.SemiBold);
        name.TextTrimming = TextTrimming.CharacterEllipsis;
        var state = Txt(s.Detail, 12, FontWeights.Normal);
        state.TextTrimming = TextTrimming.CharacterEllipsis;
        state.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { name, state } };

        var time = Txt(Elapsed(now - s.LastEvent), 12, FontWeights.Normal);
        time.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        time.Margin = new Thickness(10, 0, 2, 0);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(texts, 1);
        Grid.SetColumn(time, 2);
        grid.Children.Add(dot);
        grid.Children.Add(texts);
        grid.Children.Add(time);

        var row = new Border
        {
            Child = grid,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(10, 7, 10, 7),
            Margin = new Thickness(0, 0, 0, 6),
            Cursor = Cursors.Hand,
            ToolTip = "Porta in primo piano la finestra",
        };
        row.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Surface");
        row.MouseEnter += (_, _) => row.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.SurfaceHover");
        row.MouseLeave += (_, _) => row.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Surface");
        var folder = s.Folder;
        row.MouseLeftButtonUp += (_, _) =>
        {
            if (!NativeAgents.FocusFor(folder)) _host?.Log(Id, "Nessuna finestra trovata per la sessione");
        };
        return row;
    }

    // ---------- resting face ----------

    public FrameworkElement CreateRestingFace()
    {
        var grid = new Grid { DataContext = _face };

        // Waiting: pulsing accent dot + "Claude ti aspetta" ... folder
        var dot = new Ellipse { Width = 8, Height = 8, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        dot.SetResourceReference(Shape.FillProperty, "Isola.Brush.Accent");
        var pulse = new DoubleAnimation(1, 0.25, TimeSpan.FromMilliseconds(700))
        { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() };
        // Every animated frame repaints the whole layered island window: keep the rate low.
        Timeline.SetDesiredFrameRate(pulse, 20);
        pulse.Freeze();
        // Animations run only while visible: a hidden face costs no CPU.
        dot.IsVisibleChanged += (_, _) => dot.BeginAnimation(UIElement.OpacityProperty, dot.IsVisible ? pulse : null);
        var waiting = Side(dot, nameof(FaceViewModel.Left), nameof(FaceViewModel.Right), FaceMode.Waiting);

        // Working: spinner + folder ... count
        var spinner = new Ellipse
        {
            Width = 11, Height = 11, StrokeThickness = 1.8, Margin = new Thickness(0, 0, 7, 0),
            StrokeDashArray = new DoubleCollection { 3.5, 2.2 }, StrokeDashCap = PenLineCap.Round,
            VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = new Point(0.5, 0.5),
            Stroke = WorkingBrush,
        };
        var rot = new RotateTransform();
        spinner.RenderTransform = rot;
        var spin = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1.4)) { RepeatBehavior = RepeatBehavior.Forever };
        Timeline.SetDesiredFrameRate(spin, 24);
        spin.Freeze();
        spinner.IsVisibleChanged += (_, _) => rot.BeginAnimation(RotateTransform.AngleProperty, spinner.IsVisible ? spin : null);
        var working = Side(spinner, nameof(FaceViewModel.Left), nameof(FaceViewModel.Right), FaceMode.Working);

        // Done: check + "Finito" ... folder
        var check = new TextBlock { Text = "", FontSize = 12, Margin = new Thickness(0, 0, 6, 0), Foreground = DoneBrush, VerticalAlignment = VerticalAlignment.Center };
        check.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        var done = Side(check, nameof(FaceViewModel.Left), nameof(FaceViewModel.Right), FaceMode.Done);

        grid.Children.Add(waiting);
        grid.Children.Add(working);
        grid.Children.Add(done);
        return grid;
    }

    private static FrameworkElement Side(FrameworkElement icon, string leftPath, string rightPath, FaceMode mode)
    {
        // Left (icon + main text) wins the space; the folder on the right takes what is left.
        var left = Bound(leftPath, 12.5, FontWeights.SemiBold);
        left.TextTrimming = TextTrimming.CharacterEllipsis;
        var right = Bound(rightPath, 12, FontWeights.Normal);
        right.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        right.TextTrimming = TextTrimming.CharacterEllipsis;
        right.TextAlignment = TextAlignment.Right;
        right.Margin = new Thickness(8, 0, 0, 0);

        var leftPanel = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        leftPanel.Children.Add(icon);
        leftPanel.Children.Add(left);
        DockPanel.SetDock(leftPanel, Dock.Left);
        var g = new DockPanel { LastChildFill = true };
        g.Children.Add(leftPanel);
        g.Children.Add(right);
        g.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(FaceViewModel.Mode))
        { Converter = new ModeToVisibility(mode), Mode = BindingMode.OneWay });
        return g;
    }

    // ---------- settings ----------

    public FrameworkElement? CreateSettingsPage()
    {
        var page = new StackPanel();

        var statusTitle = Txt("Server", 13, FontWeights.SemiBold);
        var statusText = Txt(_serverStatus, 12, FontWeights.Normal);
        statusText.SetResourceReference(TextBlock.ForegroundProperty, _serverOk ? "Isola.Brush.Muted" : "Isola.Brush.Accent");
        statusText.Margin = new Thickness(0, 2, 0, 0);
        page.Children.Add(Card(new StackPanel { Children = { statusTitle, statusText } }));

        var path = HooksInstaller.DefaultPath;
        var hookTitle = Txt("Claude Code", 13, FontWeights.SemiBold);
        var hookState = Txt("", 12, FontWeights.Normal);
        hookState.TextWrapping = TextWrapping.Wrap;
        hookState.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        hookState.Margin = new Thickness(0, 2, 0, 10);
        void ShowState() => hookState.Text = HooksInstaller.IsInstalled(path)
            ? "Collegato: gli hook di Isola sono in " + path
            : "Non collegato. Gli agenti compariranno qui dopo il collegamento (vale per le sessioni nuove).";
        ShowState();

        var connect = Btn("Collega Claude Code");
        var disconnect = Btn("Scollega");
        disconnect.Margin = new Thickness(8, 0, 0, 0);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Children = { connect, disconnect } };

        var confirmText = Txt("", 12, FontWeights.Normal);
        confirmText.TextWrapping = TextWrapping.Wrap;
        var yes = Btn("Conferma");
        var no = Btn("Annulla");
        no.Margin = new Thickness(8, 0, 0, 0);
        var confirm = new StackPanel
        {
            Visibility = Visibility.Collapsed, Margin = new Thickness(0, 12, 0, 0),
            Children = { confirmText, new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0), Children = { yes, no } } },
        };
        bool installing = true;
        void Ask(bool install)
        {
            installing = install;
            confirmText.Text = install
                ? $"Isola aggiungerà a {path} un hook \"curl\" per UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop e SessionEnd. " +
                  "Il resto del file non cambia e prima viene salvata una copia (settings.json.isola-backup-…)."
                : $"Isola toglierà da {path} solo i suoi hook \"curl\". Prima viene salvata una copia.";
            confirm.Visibility = Visibility.Visible;
        }
        connect.Click += (_, _) => Ask(true);
        disconnect.Click += (_, _) => Ask(false);
        no.Click += (_, _) => confirm.Visibility = Visibility.Collapsed;
        yes.Click += (_, _) =>
        {
            confirm.Visibility = Visibility.Collapsed;
            try
            {
                int n = installing ? HooksInstaller.Install(path) : HooksInstaller.Uninstall(path);
                _host?.Log(Id, (installing ? "Hook aggiunti: " : "Hook tolti: ") + n);
                ShowState();
                if (n == 0) hookState.Text += installing ? " (era già tutto a posto)" : " (non c'era niente da togliere)";
            }
            catch (Exception ex)
            {
                hookState.Text = "Non riuscito: " + ex.Message;
                _host?.Log(Id, "Modifica di settings.json non riuscita: " + ex.GetType().Name);
            }
        };

        page.Children.Add(Card(new StackPanel { Children = { hookTitle, hookState, buttons, confirm } }));
        return page;
    }

    private static Border Card(UIElement content)
    {
        var b = new Border { Child = new Border { Padding = new Thickness(0, 14, 0, 14), Child = content }, Margin = new Thickness(0, 0, 0, 8) };
        b.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.SettingCard");
        return b;
    }

    private static Button Btn(string text)
    {
        var b = new Button { Content = text };
        b.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.Button");
        return b;
    }

    // ---------- helpers ----------

    private static TextBlock Txt(string text, double size, FontWeight weight) =>
        new() { Text = text, FontSize = size, FontWeight = weight, VerticalAlignment = VerticalAlignment.Center };

    private static TextBlock Bound(string path, double size, FontWeight weight)
    {
        var t = new TextBlock { FontSize = size, FontWeight = weight, VerticalAlignment = VerticalAlignment.Center };
        t.SetBinding(TextBlock.TextProperty, new Binding(path) { Mode = BindingMode.OneWay });
        return t;
    }

    private static Brush Frozen(byte r, byte g, byte b)
    {
        var br = new SolidColorBrush(Color.FromRgb(r, g, b));
        br.Freeze();
        return br;
    }

    private sealed record HookEvent(string SessionId, string Cwd, string Name, string Tool, string Message);

    private sealed class Session
    {
        public string Id = "";
        public string Folder = "Claude";
        public AgentState State = AgentState.Working;
        public string Detail = "Al lavoro";
        public DateTime LastEvent = DateTime.Now;
        public DateTime Since = DateTime.Now;
    }
}

internal enum AgentState { Working, Waiting, Done }

internal enum FaceMode { None, Waiting, Working, Done }

internal sealed class FaceViewModel : INotifyPropertyChanged
{
    public FaceMode Mode { get; private set; }
    public string Left { get; private set; } = "";
    public string Right { get; private set; } = "";
    public event PropertyChangedEventHandler? PropertyChanged;

    public void Set(FaceMode mode, string left, string right)
    {
        var changed = new List<string>();
        if (Mode != mode) { Mode = mode; changed.Add(nameof(Mode)); }
        if (Left != left) { Left = left; changed.Add(nameof(Left)); }
        if (Right != right) { Right = right; changed.Add(nameof(Right)); }
        foreach (var n in changed) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}

internal sealed class ModeToVisibility(FaceMode mode) : IValueConverter
{
    public object Convert(object value, Type t, object p, System.Globalization.CultureInfo c) =>
        value is FaceMode m && m == mode ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, System.Globalization.CultureInfo c) => throw new NotSupportedException();
}
