using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using Isola.Core;
using Microsoft.Win32;

namespace Isola.Modules.Reminders;

/// <summary>"Promemoria": reminders with repeats. One timer aimed at the next interesting moment
/// (a reminder becoming due, or entering the 15-minute "soon" window); nothing runs in between.
/// Due reminders peek the island (also above fullscreen apps) and stay on the pill until the user
/// presses "Fatto" or "Posticipa 10 min" in the card.</summary>
public sealed class RemindersModule : IIslandModule, IRestingFaceProvider
{
    private static readonly TimeSpan SoonWindow = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan PeekDuration = TimeSpan.FromSeconds(30);

    private readonly ReminderFaceViewModel _face = new();
    private readonly List<Guid> _firing = new(); // in firing order
    private IIslandHost? _host;
    private ReminderStore? _store;
    private DispatcherTimer? _timer;
    private RemindersCard? _card;
    private int _priority;

    public string Id => "reminders";
    public string Title => "Promemoria";
    public string Glyph => "";
    public int Order => 50;
    public bool EnabledByDefault => true;

    public int RestingPriority => _priority;

    public void Start(IIslandHost host)
    {
        _host = host;
        _store = new ReminderStore(host.DataDirectory(Id));
        _firing.Clear();
        _timer = new DispatcherTimer(DispatcherPriority.Normal, host.Dispatcher);
        _timer.Tick += (_, _) => Evaluate();
        SystemEvents.TimeChanged += OnTimeChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        // Missed while the PC was off: everything already due fires now, once.
        Evaluate();
    }

    public void Stop()
    {
        SystemEvents.TimeChanged -= OnTimeChanged;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _timer?.Stop();
        _timer = null;
        _card = null;
        _store = null;
        _firing.Clear();
        _priority = 0;
        _host = null;
    }

    public FrameworkElement? CreateCard()
    {
        _card = new RemindersCard(this);
        RefreshCard();
        return _card;
    }

    public FrameworkElement? CreateSettingsPage() => null;

    // =====================================================================================
    // Scheduling
    // =====================================================================================

    private void OnTimeChanged(object? sender, EventArgs e) => _host?.Dispatcher.BeginInvoke(Evaluate);

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume) _host?.Dispatcher.BeginInvoke(Evaluate);
    }

    /// <summary>Fires what is due, updates the pill and aims the timer at the next moment that
    /// changes something.</summary>
    private void Evaluate()
    {
        if (_timer == null || _store == null || _host == null) return;
        _timer.Stop();
        var now = DateTime.Now;

        var newlyDue = _store.Items
            .Where(r => r.Due <= now.AddSeconds(0.5) && !_firing.Contains(r.Id))
            .OrderBy(r => r.Due)
            .ToList();
        foreach (var r in newlyDue)
        {
            _firing.Add(r.Id);
            _host.Log(Id, $"scatta il promemoria delle {r.Due:HH:mm}");
        }
        _firing.RemoveAll(id => _store.Items.All(r => r.Id != id));

        var pending = _store.Items.Where(r => !_firing.Contains(r.Id)).OrderBy(r => r.Due).ToList();
        var next = pending.FirstOrDefault();

        // Face: firing wins; otherwise the next reminder if it is within 15 minutes.
        var firstFiring = FirstFiring();
        int priority;
        if (firstFiring != null)
        {
            priority = 90;
            _face.Set(firstFiring.Text, _firing.Count > 1 ? $"+{_firing.Count - 1}" : TimeText.Time(firstFiring.Due), true);
        }
        else if (next != null && next.Due - now <= SoonWindow)
        {
            priority = 15;
            _face.Set(next.Text, TimeText.Time(next.Due), false);
        }
        else
        {
            priority = 0;
        }
        bool changed = priority != _priority;
        _priority = priority;
        if (changed || newlyDue.Count > 0) _host.RefreshRestingFace();
        if (newlyDue.Count > 0) _host.Attention(Id, PeekDuration);

        // Next wake-up: the start of the "soon" window or the due time, whichever comes first.
        if (next != null)
        {
            var wake = next.Due - SoonWindow > now ? next.Due - SoonWindow : next.Due;
            var wait = wake - now;
            if (wait < TimeSpan.FromMilliseconds(200)) wait = TimeSpan.FromMilliseconds(200);
            if (wait > TimeSpan.FromHours(6)) wait = TimeSpan.FromHours(6); // re-aim now and then (clock drift)
            _timer.Interval = wait;
            _timer.Start();
        }

        RefreshCard();
    }

    private Reminder? FirstFiring()
    {
        if (_store == null) return null;
        foreach (var id in _firing)
        {
            var r = _store.Items.FirstOrDefault(x => x.Id == id);
            if (r != null) return r;
        }
        return null;
    }

    private void RefreshCard()
    {
        if (_card == null || _store == null) return;
        var firing = _firing.Select(id => _store.Items.FirstOrDefault(r => r.Id == id)).OfType<Reminder>().ToList();
        var upcoming = _store.Items.Where(r => !_firing.Contains(r.Id)).OrderBy(r => r.Due).ToList();
        _card.Refresh(upcoming, firing);
    }

    // =====================================================================================
    // Actions from the card
    // =====================================================================================

    internal void RequestKeyboardFocus() => _host?.RequestKeyboardFocus();

    /// <summary>Relative day labels ("oggi", "domani") may be stale after midnight.</summary>
    internal void CardShown() => RefreshCard();

    internal bool Add(string text, DateTime due, ReminderRepeat repeat)
    {
        if (_store == null) return false;
        var now = DateTime.Now;
        if (repeat != ReminderRepeat.None)
        {
            due = Recurrence.FirstOnOrAfter(repeat, due);
            if (due <= now) due = Recurrence.NextAfter(new Reminder { Anchor = due, Repeat = repeat }, now);
        }
        else if (due <= now) return false;

        _store.Items.Add(new Reminder { Text = text, Due = due, Anchor = due, Repeat = repeat });
        _store.Save();
        Evaluate();
        return true;
    }

    internal void Delete(Guid id)
    {
        if (_store == null) return;
        _store.Items.RemoveAll(r => r.Id == id);
        _firing.Remove(id);
        _store.Save();
        Evaluate();
    }

    internal void Snooze(Guid id)
    {
        var r = _store?.Items.FirstOrDefault(x => x.Id == id);
        if (r == null) return;
        var now = DateTime.Now;
        r.Due = now.AddMinutes(10).AddSeconds(-now.Second);
        _firing.Remove(id);
        _store!.Save();
        Evaluate();
    }

    internal void Done(Guid id)
    {
        var r = _store?.Items.FirstOrDefault(x => x.Id == id);
        if (r == null) return;
        if (r.Repeat == ReminderRepeat.None) _store!.Items.Remove(r);
        else r.Due = Recurrence.NextAfter(r, DateTime.Now);
        _firing.Remove(id);
        _store!.Save();
        Evaluate();
    }

    // =====================================================================================
    // Resting face (pill and peek): bell + text on the left, time on the right.
    // =====================================================================================

    public FrameworkElement CreateRestingFace()
    {
        var bell = RemindersCard.Glyph("", 13, new Thickness(0, 1, 8, 0));
        bell.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Accent");

        var text = new TextBlock { FontSize = 12.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        text.SetBinding(TextBlock.TextProperty, new Binding(nameof(ReminderFaceViewModel.Text)) { Mode = BindingMode.OneWay });

        var time = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        time.SetResourceReference(TextBlock.ForegroundProperty, "Isola.Brush.Muted");
        time.SetBinding(TextBlock.TextProperty, new Binding(nameof(ReminderFaceViewModel.Time)) { Mode = BindingMode.OneWay });

        var grid = new Grid { DataContext = _face };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(bell);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        Grid.SetColumn(time, 2);
        grid.Children.Add(time);
        return grid;
    }
}

internal sealed class ReminderFaceViewModel : INotifyPropertyChanged
{
    public string Text { get; private set; } = "";
    public string Time { get; private set; } = "";
    public bool Firing { get; private set; }

    public event PropertyChangedEventHandler? PropertyChanged;

    public void Set(string text, string time, bool firing)
    {
        Text = text;
        Time = time;
        Firing = firing;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }
}
