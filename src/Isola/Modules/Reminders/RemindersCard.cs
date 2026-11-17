using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace Isola.Modules.Reminders;

/// <summary>The "Promemoria" tab: firing banner or composer on top, upcoming list below.</summary>
internal sealed class RemindersCard : Grid
{
    private static readonly Uri StylesUri = new("/Isola;component/Modules/Reminders/RemindersStyles.xaml", UriKind.Relative);

    private readonly RemindersModule _owner;
    private readonly TextBox _text;
    private readonly TextBlock _placeholder;
    private readonly Button _repeatChip;
    private readonly TextBlock _repeatLabel;
    private readonly Button _tonightChip;
    private readonly ToggleButton _customChip;
    private readonly Grid _customRow;
    private readonly TextBox _customTime;
    private readonly TextBox _customDate;
    private readonly FrameworkElement _composer;
    private readonly Border _banner;
    private readonly TextBlock _bannerText;
    private readonly TextBlock _bannerSub;
    private readonly StackPanel _list;
    private readonly TextBlock _empty;
    private ReminderRepeat _repeat = ReminderRepeat.None;
    private Guid _bannerId;

    public RemindersCard(RemindersModule owner)
    {
        _owner = owner;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = StylesUri });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // ---- Composer ------------------------------------------------------------------
        _text = new TextBox { MaxLength = 200 };
        _text.SetResourceReference(StyleProperty, "Rem.TextBox");
        _text.PreviewMouseDown += (_, _) => _owner.RequestKeyboardFocus();
        _text.GotKeyboardFocus += (_, _) => _owner.RequestKeyboardFocus();
        _text.TextChanged += (_, _) =>
        {
            _placeholder!.Visibility = _text.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            _text.Tag = null;
        };
        _text.KeyDown += OnTextKeyDown;
        _placeholder = new TextBlock
        {
            Text = "Ricordami di…",
            Margin = new Thickness(11, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
        };
        _placeholder.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var textHost = new Grid();
        textHost.Children.Add(_text);
        textHost.Children.Add(_placeholder);

        _repeatLabel = new TextBlock { Text = "Mai", VerticalAlignment = VerticalAlignment.Center };
        var repeatContent = new StackPanel { Orientation = Orientation.Horizontal };
        repeatContent.Children.Add(Glyph("", 11, new Thickness(0, 1, 6, 0)));
        repeatContent.Children.Add(_repeatLabel);
        _repeatChip = Chip(repeatContent, CycleRepeat);
        _repeatChip.Height = 30;
        _repeatChip.Margin = new Thickness(6, 0, 0, 0);
        _repeatChip.ToolTip = "Ripeti";

        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(textHost);
        Grid.SetColumn(_repeatChip, 1);
        top.Children.Add(_repeatChip);

        var chips = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 7, 0, 0) };
        chips.Children.Add(Chip("+10 min", () => AddAt(DateTime.Now.AddMinutes(10))));
        chips.Children.Add(Chip("+1 h", () => AddAt(DateTime.Now.AddHours(1))));
        _tonightChip = Chip("Stasera 20:00", () => AddAt(DateTime.Today.AddHours(20)));
        chips.Children.Add(_tonightChip);
        chips.Children.Add(Chip("Domani 9:00", () => AddAt(DateTime.Today.AddDays(1).AddHours(9))));
        _customChip = new ToggleButton { ToolTip = "Scegli ora e data" };
        _customChip.SetResourceReference(StyleProperty, "Rem.ChipToggle");
        _customChip.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children = { Glyph("", 11, new Thickness(0, 1, 6, 0)), new TextBlock { Text = "Altro" } },
        };
        _customChip.Checked += (_, _) => ShowCustom(true);
        _customChip.Unchecked += (_, _) => ShowCustom(false);
        chips.Children.Add(_customChip);

        // ---- Custom time row ------------------------------------------------------------
        _customTime = SmallBox(58, "20:00");
        _customDate = SmallBox(104, "");
        var addCustom = new Button { Content = "Aggiungi", Margin = new Thickness(6, 0, 0, 0) };
        addCustom.SetResourceReference(StyleProperty, "Rem.AccentButton");
        addCustom.Click += (_, _) => AddCustom();
        _customRow = new Grid { Margin = new Thickness(0, 7, 0, 0), Visibility = Visibility.Collapsed };
        var customPanel = new StackPanel { Orientation = Orientation.Horizontal };
        customPanel.Children.Add(Label("Alle"));
        customPanel.Children.Add(_customTime);
        customPanel.Children.Add(Label("il"));
        customPanel.Children.Add(_customDate);
        customPanel.Children.Add(addCustom);
        _customRow.Children.Add(customPanel);

        var composer = new StackPanel();
        composer.Children.Add(top);
        composer.Children.Add(chips);
        composer.Children.Add(_customRow);
        _composer = composer;

        // ---- Firing banner ---------------------------------------------------------------
        _bannerText = new TextBlock { FontSize = 14, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        _bannerSub = new TextBlock { FontSize = 11.5, Margin = new Thickness(0, 2, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };
        _bannerSub.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        var bannerTexts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
        bannerTexts.Children.Add(_bannerText);
        bannerTexts.Children.Add(_bannerSub);

        var bell = Glyph("", 18, new Thickness(2, 0, 0, 0));
        bell.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Accent");
        bell.VerticalAlignment = VerticalAlignment.Center;

        var snooze = Chip("Posticipa 10 min", () => _owner.Snooze(_bannerId));
        snooze.Height = 30;
        snooze.Padding = new Thickness(12, 0, 12, 0);
        var done = new Button { Content = "Fatto", Height = 30, Padding = new Thickness(16, 0, 16, 0), Margin = new Thickness(0) };
        done.SetResourceReference(StyleProperty, "Rem.AccentButton");
        done.Click += (_, _) => _owner.Done(_bannerId);

        var bannerGrid = new Grid();
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bannerGrid.Children.Add(bell);
        Grid.SetColumn(bannerTexts, 1);
        bannerGrid.Children.Add(bannerTexts);
        Grid.SetColumn(snooze, 2);
        bannerGrid.Children.Add(snooze);
        Grid.SetColumn(done, 3);
        bannerGrid.Children.Add(done);

        // Accent-tinted background: a rectangle filled with the accent at low opacity.
        var tint = new Border { CornerRadius = new CornerRadius(14), Opacity = 0.16 };
        tint.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Accent");
        var bannerInner = new Grid();
        bannerInner.Children.Add(tint);
        bannerInner.Children.Add(new Border { Padding = new Thickness(12, 10, 10, 10), Child = bannerGrid });
        _banner = new Border { Child = bannerInner, Visibility = Visibility.Collapsed };

        var head = new Grid();
        head.Children.Add(_composer);
        head.Children.Add(_banner);
        Children.Add(head);

        // ---- List -------------------------------------------------------------------------
        _list = new StackPanel();
        var scroll = new ScrollViewer { Content = _list, Margin = new Thickness(0, 8, 0, 0) };
        scroll.SetResourceReference(StyleProperty, "Rem.Scroll");
        _empty = new TextBlock
        {
            Text = "Nessun promemoria. Scrivi qui sopra e scegli quando.",
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12,
            Margin = new Thickness(0, 8, 0, 0),
        };
        _empty.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        SetRow(scroll, 1);
        SetRow(_empty, 1);
        Children.Add(scroll);
        Children.Add(_empty);

        IsVisibleChanged += (_, _) => { if (IsVisible) _owner.CardShown(); };
    }

    // =====================================================================================

    public void Refresh(IReadOnlyList<Reminder> upcoming, IReadOnlyList<Reminder> firing)
    {
        var now = DateTime.Now;
        if (firing.Count > 0)
        {
            var f = firing[0];
            _bannerId = f.Id;
            _bannerText.Text = f.Text;
            var sub = $"Promemoria delle {TimeText.Time(f.Due)}";
            if (f.Due.Date != now.Date) sub = $"Promemoria di {TimeText.When(f.Due, now)}";
            if (firing.Count > 1) sub += $" · altri {firing.Count - 1}";
            _bannerSub.Text = sub;
            _banner.Visibility = Visibility.Visible;
            _composer.Visibility = Visibility.Hidden; // keeps the height stable
        }
        else
        {
            _banner.Visibility = Visibility.Collapsed;
            _composer.Visibility = Visibility.Visible;
        }

        _list.Children.Clear();
        foreach (var r in upcoming) _list.Children.Add(Row(r, now));
        _empty.Visibility = upcoming.Count == 0 && firing.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateTonightChip();
    }

    private FrameworkElement Row(Reminder r, DateTime now)
    {
        var when = new TextBlock { Text = TimeText.When(r.Due, now), FontSize = 12, Width = 104, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        when.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        if ((r.Due - now).TotalMinutes <= 15) when.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Accent");

        var text = new TextBlock { Text = r.Text, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };

        var repeat = Glyph("", 11, new Thickness(6, 1, 4, 0));
        repeat.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        repeat.VerticalAlignment = VerticalAlignment.Center;
        repeat.Visibility = r.Repeat == ReminderRepeat.None ? Visibility.Collapsed : Visibility.Visible;
        repeat.ToolTip = TimeText.RepeatLabel(r.Repeat);

        var delete = new Button { Content = "", ToolTip = "Elimina", Opacity = 0 };
        delete.SetResourceReference(StyleProperty, "Rem.IconButton");
        var id = r.Id;
        delete.Click += (_, _) => _owner.Delete(id);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(when);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        Grid.SetColumn(repeat, 2);
        grid.Children.Add(repeat);
        Grid.SetColumn(delete, 3);
        grid.Children.Add(delete);

        var row = new Border { Child = grid, Padding = new Thickness(10, 0, 3, 0), Height = 28, CornerRadius = new CornerRadius(9), Background = Brushes.Transparent };
        row.MouseEnter += (_, _) => { row.SetResourceReference(Border.BackgroundProperty, "Isola.Brush.Surface"); delete.Opacity = 1; };
        row.MouseLeave += (_, _) => { row.Background = Brushes.Transparent; delete.Opacity = 0; };
        return row;
    }

    // ---- Composer actions ---------------------------------------------------------------

    private void AddAt(DateTime due)
    {
        var text = _text.Text.Trim();
        if (text.Length == 0)
        {
            _text.Tag = "error";
            _owner.RequestKeyboardFocus();
            _text.Focus();
            return;
        }
        due = due.AddSeconds(-due.Second).AddMilliseconds(-due.Millisecond);
        if (!_owner.Add(text, due, _repeat)) return;
        _text.Clear();
        _repeat = ReminderRepeat.None;
        _repeatLabel.Text = TimeText.RepeatLabel(_repeat);
        _customChip.IsChecked = false;
    }

    private void AddCustom()
    {
        var now = DateTime.Now;
        bool okTime = TimeText.TryParseTime(_customTime.Text, out var time);
        bool okDate = TimeText.TryParseDate(_customDate.Text, now, out var date);
        _customTime.Tag = okTime ? null : "error";
        _customDate.Tag = okDate ? null : "error";
        if (!okTime || !okDate) return;

        DateTime due;
        if (date is { } d) due = d + time;
        else
        {
            due = now.Date + time;
            if (due <= now) due = due.AddDays(1);
        }
        if (due <= now && _repeat == ReminderRepeat.None)
        {
            _customTime.Tag = "error";
            _customDate.Tag = "error";
            return;
        }
        AddAt(due);
    }

    private void ShowCustom(bool show)
    {
        _customRow.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) return;
        var now = DateTime.Now;
        var suggestion = now.AddHours(1);
        suggestion = suggestion.Date.AddHours(suggestion.Hour);
        _customTime.Text = suggestion.ToString("HH:mm");
        _customDate.Text = suggestion.Date == now.Date ? "oggi" : suggestion.Date == now.Date.AddDays(1) ? "domani" : suggestion.ToString("dd/MM/yyyy");
        _customTime.Tag = _customDate.Tag = null;
    }

    private void CycleRepeat()
    {
        _repeat = _repeat switch
        {
            ReminderRepeat.None => ReminderRepeat.Daily,
            ReminderRepeat.Daily => ReminderRepeat.Weekdays,
            ReminderRepeat.Weekdays => ReminderRepeat.Weekly,
            _ => ReminderRepeat.None,
        };
        _repeatLabel.Text = TimeText.RepeatLabel(_repeat);
    }

    private void OnTextKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        if (_customChip.IsChecked == true) AddCustom();
        else _customChip.IsChecked = true;
    }

    private void UpdateTonightChip()
        => _tonightChip.Visibility = DateTime.Now.Hour < 20 ? Visibility.Visible : Visibility.Collapsed;

    // ---- Building blocks ----------------------------------------------------------------

    private Button Chip(object content, Action click)
    {
        var b = new Button { Content = content };
        b.SetResourceReference(StyleProperty, "Rem.Chip");
        b.Click += (_, _) => click();
        return b;
    }

    private TextBox SmallBox(double width, string text)
    {
        var t = new TextBox { Width = width, Text = text, Height = 26, Padding = new Thickness(8, 0, 8, 0), FontSize = 12.5 };
        t.SetResourceReference(StyleProperty, "Rem.TextBox");
        t.PreviewMouseDown += (_, _) => _owner.RequestKeyboardFocus();
        t.GotKeyboardFocus += (_, _) => { _owner.RequestKeyboardFocus(); t.SelectAll(); };
        t.TextChanged += (_, _) => t.Tag = null;
        t.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; AddCustom(); } };
        return t;
    }

    private static TextBlock Label(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 12, Margin = new Thickness(2, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        return t;
    }

    internal static TextBlock Glyph(string glyph, double size, Thickness margin)
    {
        var t = new TextBlock { Text = glyph, FontSize = size, Margin = margin, VerticalAlignment = VerticalAlignment.Center };
        t.SetResourceReference(TextBlock.FontFamilyProperty, "Isola.Font.Icons");
        return t;
    }
}
