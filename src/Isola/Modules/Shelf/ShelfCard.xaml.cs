using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace Isola.Modules.Shelf;

/// <summary>The "Mensola" tab: a grid of tiles, check boxes for multi-select, drag out, action bar.</summary>
internal partial class ShelfCard : UserControl
{
    private readonly ShelfModule _module;
    private ShelfEntry? _pressEntry;
    private FrameworkElement? _pressTile;
    private Point _pressPoint;
    private bool _pressWasDouble;

    public ShelfCard(ShelfModule module)
    {
        _module = module;
        InitializeComponent();
        Tiles.ItemsSource = module.Items;
        foreach (var e in module.Items) e.PropertyChanged += OnEntryChanged;
        module.Items.CollectionChanged += (_, args) =>
        {
            if (args.NewItems != null) foreach (ShelfEntry e in args.NewItems) e.PropertyChanged += OnEntryChanged;
            if (args.OldItems != null) foreach (ShelfEntry e in args.OldItems) e.PropertyChanged -= OnEntryChanged;
            Refresh();
        };
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible) { Refresh(); _module.RefreshExistence(Refresh); }
            else HideDropHint();
        };
        DragEnter += OnCardDragEnter;
        DragLeave += OnCardDragLeave;
        Drop += (_, _) => HideDropHint();
        Refresh();
    }

    private void OnEntryChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ShelfEntry.IsSelected) or nameof(ShelfEntry.Exists)) Refresh();
    }

    public void Refresh()
    {
        var items = _module.Items;
        int n = items.Count;
        int sel = items.Count(i => i.IsSelected);
        int missing = items.Count(i => !i.Exists);

        Empty.Visibility = n == 0 ? Visibility.Visible : Visibility.Collapsed;
        Bar.Visibility = n == 0 ? Visibility.Hidden : Visibility.Visible;
        Scroller.Visibility = n == 0 ? Visibility.Hidden : Visibility.Visible;

        if (sel > 0)
        {
            Summary.Text = sel == n ? $"Tutti selezionati ({n})" : $"{sel} selezionati su {n}";
            SelectAllText.Text = "Deseleziona";
            SelectAllGlyph.Text = "";
            OpenFolderBtn.Visibility = Visibility.Visible;
            RemoveText.Text = "Togli";
        }
        else
        {
            Summary.Text = (n == 1 ? "1 file" : $"{n} file") + (missing > 0 ? $" · {missing} non trovati" : "");
            SelectAllText.Text = "Seleziona tutto";
            SelectAllGlyph.Text = "";
            OpenFolderBtn.Visibility = Visibility.Collapsed;
            RemoveText.Text = missing > 0 ? "Togli mancanti" : "Svuota";
        }
    }

    private List<ShelfEntry> Selected() => _module.Items.Where(i => i.IsSelected).ToList();

    // ---- Action bar -----------------------------------------------------------------------

    private void SelectAll_Click(object sender, RoutedEventArgs e)
    {
        bool any = _module.Items.Any(i => i.IsSelected);
        foreach (var i in _module.Items) i.IsSelected = !any && i.Exists;
    }

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        var first = Selected().FirstOrDefault();
        if (first != null) _module.OpenFolder(first);
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        var sel = Selected();
        if (sel.Count > 0) _module.Remove(sel);
        else if (_module.Items.Any(i => !i.Exists)) _module.Remove(_module.Items.Where(i => !i.Exists));
        else _module.Remove(_module.Items);
    }

    private void TileRemove_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.DataContext is ShelfEntry entry) _module.Remove(new[] { entry });
    }

    // ---- Tiles: click = select, double click = open, drag = drag out ----------------------

    private void Tile_MouseDown(object sender, MouseButtonEventArgs e)
    {
        _pressEntry = null;
        if (IsInsideButton(e.OriginalSource as DependencyObject, sender as DependencyObject)) return;
        if ((sender as FrameworkElement)?.DataContext is not ShelfEntry entry) return;
        if (e.ClickCount == 2)
        {
            _pressWasDouble = true;
            _module.Open(entry);
            e.Handled = true;
            return;
        }
        _pressWasDouble = false;
        _pressEntry = entry;
        _pressTile = (FrameworkElement)sender;
        _pressPoint = e.GetPosition(this);
    }

    private void Tile_MouseMove(object sender, MouseEventArgs e)
    {
        if (_pressEntry == null || e.LeftButton != MouseButtonState.Pressed) return;
        var d = e.GetPosition(this) - _pressPoint;
        if (Math.Abs(d.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(d.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        var entry = _pressEntry;
        var tile = _pressTile ?? (FrameworkElement)sender;
        _pressEntry = null;
        DragOut(entry, tile);
    }

    private void Tile_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_pressWasDouble) { _pressWasDouble = false; return; }
        if (_pressEntry == null || (sender as FrameworkElement)?.DataContext != _pressEntry) return;
        var entry = _pressEntry;
        _pressEntry = null;
        if (entry.Exists) entry.IsSelected = !entry.IsSelected;
    }

    /// <summary>Drags the pressed tile, or every selected file if the tile is selected.</summary>
    private void DragOut(ShelfEntry entry, FrameworkElement tile)
    {
        var group = entry.IsSelected ? _module.Items.Where(i => i.IsSelected) : new[] { entry };
        var paths = group.Where(i => { i.RefreshExists(); return i.Exists; }).Select(i => i.Path).ToArray();
        if (paths.Length == 0) return;

        _module.DraggingOut = true;
        try
        {
            var data = new DataObject(DataFormats.FileDrop, paths);
            var result = DragDrop.DoDragDrop(tile, data, DragDropEffects.Copy | DragDropEffects.Move);
            _module.Log($"trascinati fuori {paths.Length} file: {result}");
        }
        catch (Exception ex)
        {
            _module.Log("trascinamento non riuscito: " + ex.Message);
        }
        finally
        {
            _module.DraggingOut = false;
            Refresh();
            _module.RefreshExistence(Refresh); // a Move may have taken files away
        }
    }

    private static bool IsInsideButton(DependencyObject? from, DependencyObject? stop)
    {
        for (var d = from; d != null && d != stop; d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
            if (d is ButtonBase) return true;
        return false;
    }

    // ---- Drop hint ------------------------------------------------------------------------

    private void OnCardDragEnter(object sender, DragEventArgs e)
    {
        if (_module.DraggingOut || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        DropHint.Visibility = Visibility.Visible;
    }

    private void OnCardDragLeave(object sender, DragEventArgs e)
    {
        var p = e.GetPosition(this);
        if (p.X <= 0 || p.Y <= 0 || p.X >= ActualWidth || p.Y >= ActualHeight) HideDropHint();
    }

    public void HideDropHint() => DropHint.Visibility = Visibility.Collapsed;
}
