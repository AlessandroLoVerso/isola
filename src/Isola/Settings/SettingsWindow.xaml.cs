using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using Isola.Core;
using Isola.Island;
using Isola.Native;

namespace Isola.Settings;

/// <summary>The Settings window: "Generale", "Moduli", then one page per running module that
/// provides CreateSettingsPage(). Every change is saved and applied immediately.</summary>
public partial class SettingsWindow : Window
{
    private sealed record Page(string Key, string Glyph, string Label, Func<FrameworkElement> Build);

    private readonly GlobalSettingsStore _settings;
    private readonly ModuleManager _modules;
    private readonly EventHandler _modulesChanged;
    private string _currentKey = "general";
    private bool _rebuildingNav;

    public SettingsWindow(GlobalSettingsStore settings, ModuleManager modules)
    {
        _settings = settings;
        _modules = modules;
        InitializeComponent();

        SourceInitialized += (_, _) => NativeMethods.UseDarkTitleBar(new WindowInteropHelper(this).Handle);
        Nav.SelectionChanged += (_, _) =>
        {
            if (!_rebuildingNav && Nav.SelectedItem is ListBoxItem { Tag: Page p }) ShowPage(p);
        };

        var version = typeof(SettingsWindow).Assembly.GetName().Version;
        FooterText.Text = $"Versione {version?.ToString(3) ?? "0.1.0"}";

        // Let the toggle animation finish before the pages are rebuilt.
        var rebuild = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(220) };
        rebuild.Tick += (_, _) =>
        {
            rebuild.Stop();
            RebuildNav();
        };
        _modulesChanged = (_, _) =>
        {
            rebuild.Stop();
            rebuild.Start();
        };
        Closed += (_, _) => rebuild.Stop();
        _modules.Changed += _modulesChanged;
        Closed += (_, _) => _modules.Changed -= _modulesChanged;

        RebuildNav();
    }

    // ---- Navigation ----------------------------------------------------------------------

    private void RebuildNav()
    {
        var pages = new List<Page>
        {
            new("general", "", "Generale", BuildGeneralPage),
            new("modules", "", "Moduli", BuildModulesPage),
        };
        foreach (var e in _modules.Running.Where(e => e.Module is not null))
        {
            var entry = e;
            pages.Add(new Page("module:" + entry.Id, entry.Glyph, entry.Title, () => BuildModulePage(entry)));
        }

        _rebuildingNav = true;
        _hasPageCache.Clear();
        Nav.Items.Clear();
        ListBoxItem? select = null;
        bool headerAdded = false;
        foreach (var p in pages)
        {
            if (p.Key.StartsWith("module:", StringComparison.Ordinal))
            {
                // Module pages only appear when the module actually has one.
                if (!HasSettingsPage(p.Key["module:".Length..])) continue;
                if (!headerAdded) Nav.Items.Add(NavHeader("MODULI"));
                headerAdded = true;
            }
            var item = NavItem(p);
            Nav.Items.Add(item);
            if (p.Key == _currentKey) select = item;
        }
        _rebuildingNav = false;

        select ??= Nav.Items.OfType<ListBoxItem>().FirstOrDefault(i => i.Tag is Page { Key: "modules" });
        Nav.SelectedItem = select;
        if (select?.Tag is Page page) ShowPage(page);
    }

    private readonly Dictionary<string, bool> _hasPageCache = new();

    private bool HasSettingsPage(string id)
    {
        // CreateSettingsPage is cheap by contract, but don't call it twice per rebuild.
        var e = _modules.Find(id);
        if (e is not { IsRunning: true }) return false;
        if (_hasPageCache.TryGetValue(id, out var has)) return has;
        var page = _modules.Call<FrameworkElement?>(e, "CreateSettingsPage", () => e.Module.CreateSettingsPage(), null);
        has = page != null;
        _hasPageCache[id] = has;
        return has;
    }

    private static ListBoxItem NavItem(Page p)
    {
        var glyph = new TextBlock { Text = p.Glyph, FontSize = 14, Width = 22, VerticalAlignment = VerticalAlignment.Center };
        glyph.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(glyph);
        panel.Children.Add(new TextBlock { Text = p.Label, Margin = new Thickness(8, 0, 0, 1), VerticalAlignment = VerticalAlignment.Center });
        var item = new ListBoxItem { Content = panel, Tag = p };
        item.SetResourceReference(StyleProperty, "Isola.Style.NavItem");
        return item;
    }

    private static ListBoxItem NavHeader(string text) => new()
    {
        Content = new TextBlock
        {
            Text = text,
            FontSize = 10.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Color.FromRgb(0x7A, 0x7A, 0x84)),
            Margin = new Thickness(12, 16, 0, 6),
        },
        IsEnabled = false,
        Focusable = false,
        Template = HeaderTemplate,
    };

    private static readonly ControlTemplate HeaderTemplate = CreateHeaderTemplate();

    private static ControlTemplate CreateHeaderTemplate()
    {
        var t = new ControlTemplate(typeof(ListBoxItem)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) };
        t.Seal();
        return t;
    }

    private void ShowPage(Page p)
    {
        _currentKey = p.Key;
        FrameworkElement content;
        try { content = p.Build(); }
        catch (Exception ex)
        {
            Log.Error($"Pagina di impostazioni '{p.Key}' non riuscita", ex);
            content = new TextBlock { Text = "Questa pagina non si è caricata. Dettagli nel log.", Foreground = Muted };
        }
        PageHost.Content = content;
        PageScroller.ScrollToTop();
    }

    // ---- Pages ---------------------------------------------------------------------------

    private FrameworkElement BuildGeneralPage()
    {
        var s = _settings.Current;
        var root = new StackPanel();
        root.Children.Add(PageTitle("Generale"));

        // Aspetto
        root.Children.Add(SectionHeader("Aspetto"));
        var offsetValue = new TextBlock { Width = 44, TextAlignment = TextAlignment.Right, Foreground = Muted, VerticalAlignment = VerticalAlignment.Center };
        var slider = new Slider { Minimum = 0, Maximum = GlobalSettings.MaxEdgeOffset, Value = s.EdgeOffset, Width = 200, TickFrequency = 1, IsSnapToTickEnabled = true, VerticalAlignment = VerticalAlignment.Center };
        slider.SetResourceReference(StyleProperty, "Isola.Style.Slider");
        offsetValue.Text = $"{s.EdgeOffset:0} px";
        slider.ValueChanged += (_, e) =>
        {
            offsetValue.Text = $"{e.NewValue:0} px";
            _settings.Update(x => x.EdgeOffset = Math.Round(e.NewValue));
        };
        var sliderRow = new StackPanel { Orientation = Orientation.Horizontal };
        sliderRow.Children.Add(slider);
        sliderRow.Children.Add(offsetValue);
        slider.IsEnabled = s.Shape == IslandShape.Isola;
        var screenshots = Toggle(s.ShowInScreenshots);
        screenshots.Checked += (_, _) => _settings.Update(x => x.ShowInScreenshots = true);
        screenshots.Unchecked += (_, _) => _settings.Update(x => x.ShowInScreenshots = false);

        root.Children.Add(Card(
            Row("Forma", "Isola staccata dal bordo, oppure notch attaccato in alto con gli angoli curvi.",
                Segmented(new[] { (IslandShape.Isola, "Isola"), (IslandShape.Notch, "Notch") }, s.Shape, v =>
                {
                    _settings.Update(x => x.Shape = v);
                    slider.IsEnabled = v == IslandShape.Isola;
                })),
            Row("Tema", "Il colore dell'isola.",
                Segmented(ThemeManager.Options.Select(o => (o.Id, o.Name)), ThemeManager.CurrentId, v => _settings.Update(x => x.Theme = v))),
            Row("Distanza dal bordo", "Quanto l'isola sta sotto il bordo superiore (solo forma isola).", sliderRow),
            Row("Mostra l'isola negli screenshot",
                "Il tema Liquido nasconde l'isola da screenshot e registrazioni (deve, per vedere cosa c'è dietro). Accendi per vederla: Liquido diventa Vetro.",
                screenshots)));

        // Posizione
        root.Children.Add(SectionHeader("Posizione"));
        var monitors = MonitorService.All();
        var current = MonitorService.Resolve(s.Monitor);
        root.Children.Add(Card(
            Row("Monitor", monitors.Count > 1 ? "Su quale schermo sta l'isola." : "C'è un solo schermo collegato.",
                Segmented(monitors.Select(m => (m.DeviceName, m.Label)), current.DeviceName,
                    v => _settings.Update(x => x.Monitor = v), vertical: monitors.Count > 2))));

        // Schermo intero
        root.Children.Add(SectionHeader("Schermo intero"));
        root.Children.Add(Card(
            Row("Sopra le app a schermo intero",
                "Striscia: una barra sottile, se un modulo ha qualcosa da mostrare. Nascondi: l'isola sparisce finché l'app è a schermo intero.",
                Segmented(new[] { (FullscreenBehavior.Striscia, "Striscia"), (FullscreenBehavior.Nascondi, "Nascondi") }, s.Fullscreen,
                    v => _settings.Update(x => x.Fullscreen = v)))));

        // Sistema
        root.Children.Add(SectionHeader("Sistema"));
        var startup = Toggle(StartupRegistration.IsEnabled());
        bool reverting = false;
        void OnStartupToggle(object sender, RoutedEventArgs e)
        {
            if (reverting) return;
            bool want = startup.IsChecked == true;
            if (!StartupRegistration.SetEnabled(want))
            {
                reverting = true;
                startup.IsChecked = !want;
                reverting = false;
            }
        }
        startup.Checked += OnStartupToggle;
        startup.Unchecked += OnStartupToggle;

        var openFolder = new Button { Content = "Apri cartella" };
        openFolder.SetResourceReference(StyleProperty, "Isola.Style.Button");
        openFolder.Click += (_, _) =>
        {
            try
            {
                Directory.CreateDirectory(AppPaths.Root);
                Process.Start(new ProcessStartInfo("explorer.exe", $"\"{AppPaths.Root}\"") { UseShellExecute = true });
            }
            catch (Exception ex) { Log.Error("Impossibile aprire la cartella dei dati", ex); }
        };

        string startupDesc = StartupRegistration.PointsElsewhere()
            ? "Attivo, ma punta a un'altra copia di Isola: spegni e riaccendi per usare questa."
            : "Isola parte da sola quando accedi a Windows.";
        root.Children.Add(Card(
            Row("Avvia con Windows", startupDesc, startup),
            Row("Dati e log", AppPaths.Root, openFolder)));

        return root;
    }

    private FrameworkElement BuildModulesPage()
    {
        var root = new StackPanel();
        root.Children.Add(PageTitle("Moduli"));
        root.Children.Add(new TextBlock
        {
            Text = "Ogni funzione dell'isola è un modulo. Spegnilo e si ferma subito; se un modulo va in errore viene spento da solo.",
            Foreground = Muted,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, -8, 0, 18),
        });

        if (_modules.Entries.Count == 0)
        {
            root.Children.Add(new TextBlock { Text = "Nessun modulo trovato.", Foreground = Muted });
            return root;
        }

        var rows = new List<UIElement>();
        foreach (var e in _modules.Entries)
        {
            var entry = e;
            var toggle = Toggle(_modules.IsEnabled(entry) && entry.LastError == null);
            toggle.Checked += (_, _) => _modules.SetEnabled(entry.Id, true);
            toggle.Unchecked += (_, _) => _modules.SetEnabled(entry.Id, false);

            string state = entry.LastError != null ? $"Errore — {entry.LastError}"
                : entry.IsRunning ? "Attivo" : "Spento";
            var desc = new TextBlock
            {
                Text = state,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = entry.LastError != null ? new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x6B)) : Muted,
                Margin = new Thickness(0, 2, 0, 0),
            };
            rows.Add(Row(entry.Title, desc, toggle, entry.Glyph));
        }
        root.Children.Add(Card(rows.ToArray()));
        return root;
    }

    private FrameworkElement BuildModulePage(ModuleEntry e)
    {
        var root = new StackPanel();
        root.Children.Add(PageTitle(e.Title));
        var page = _modules.Call<FrameworkElement?>(e, "CreateSettingsPage", () => e.Module.CreateSettingsPage(), null);
        if (page == null)
        {
            root.Children.Add(new TextBlock { Text = "Questo modulo non ha impostazioni.", Foreground = Muted });
            return root;
        }
        root.Children.Add(page);
        return root;
    }

    // ---- Building blocks -----------------------------------------------------------------

    private static Brush Muted => (Brush)System.Windows.Application.Current.FindResource("Settings.Brush.Muted");

    private static TextBlock PageTitle(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 26, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 18) };
        t.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Display");
        return t;
    }

    private static TextBlock SectionHeader(string text) => new()
    {
        Text = text,
        FontSize = 13,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(2, 6, 0, 8),
    };

    private static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(new Border { Height = 1, Background = new SolidColorBrush(Color.FromRgb(0x2A, 0x2A, 0x30)) });
            stack.Children.Add(rows[i]);
        }
        var card = new Border { Child = stack };
        card.SetResourceReference(StyleProperty, "Isola.Style.SettingCard");
        return card;
    }

    private static FrameworkElement Row(string title, string? description, UIElement control, string? glyph = null)
        => Row(title, description == null ? null : new TextBlock
        {
            Text = description,
            FontSize = 12,
            Foreground = Muted,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 2, 0, 0),
        }, control, glyph);

    private static FrameworkElement Row(string title, TextBlock? description, UIElement control, string? glyph = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 13, 0, 13) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (glyph != null)
        {
            var icon = new Border
            {
                Width = 34,
                Height = 34,
                CornerRadius = new CornerRadius(9),
                Background = new SolidColorBrush(Color.FromRgb(0x2A, 0x2A, 0x30)),
                Margin = new Thickness(0, 0, 14, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            var gt = new TextBlock { Text = glyph, FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            gt.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
            icon.Child = gt;
            grid.Children.Add(icon);
        }

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 24, 0) };
        text.Children.Add(new TextBlock { Text = title, FontSize = 13.5, TextWrapping = TextWrapping.Wrap });
        if (description != null) text.Children.Add(description);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 2);
        grid.Children.Add(control);
        return grid;
    }

    private static CheckBox Toggle(bool isChecked)
    {
        var t = new CheckBox { IsChecked = isChecked };
        t.SetResourceReference(StyleProperty, "Isola.Style.ToggleSwitch");
        return t;
    }

    private static Border Segmented<T>(IEnumerable<(T Value, string Label)> options, T current, Action<T> onChange, bool vertical = false)
    {
        var panel = new StackPanel { Orientation = vertical ? Orientation.Vertical : Orientation.Horizontal };
        var group = "seg-" + Guid.NewGuid().ToString("N");
        foreach (var (value, label) in options)
        {
            var v = value;
            var rb = new RadioButton
            {
                Content = label,
                GroupName = group,
                IsChecked = EqualityComparer<T>.Default.Equals(v, current),
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            rb.SetResourceReference(StyleProperty, "Isola.Style.Segmented");
            rb.Checked += (_, _) => onChange(v);
            panel.Children.Add(rb);
        }
        var host = new Border { Child = panel };
        host.SetResourceReference(StyleProperty, "Isola.Style.SegmentedHost");
        return host;
    }
}
