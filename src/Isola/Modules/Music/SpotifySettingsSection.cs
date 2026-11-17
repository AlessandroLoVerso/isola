using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Isola.Modules.Music;

/// <summary>Settings → Musica → "Spotify": Client ID, redirect URI, connect / disconnect.</summary>
internal sealed class SpotifySettingsSection : StackPanel
{
    private readonly SpotifyController? _spotify;
    private readonly TextBox _clientId;
    private readonly TextBlock _status;
    private readonly Button _connect;
    private readonly Action<string> _saveClientId;

    public SpotifySettingsSection(SpotifyController? spotify, string clientId, Action<string> saveClientId)
    {
        _spotify = spotify;
        _saveClientId = saveClientId;

        _clientId = new TextBox { Text = clientId, Width = 260, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 };
        _clientId.SetResourceReference(StyleProperty, "Isola.Style.TextBox");
        _clientId.ToolTip = "32 caratteri, dalla pagina della tua app su developer.spotify.com";
        _clientId.LostKeyboardFocus += (_, _) => SaveClientId();
        _clientId.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; SaveClientId(); } };

        var uri = new TextBlock
        {
            Text = SpotifyPkce.RedirectUri,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            Margin = new Thickness(0, 3, 0, 0),
        };
        var uriText = new StackPanel();
        uriText.Children.Add(uri);
        uriText.Children.Add(Description("Aggiungilo così com'è tra i Redirect URI dell'app Spotify (non \"localhost\")."));
        var copy = SettingsButton("Copia");
        var copyReset = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        copyReset.Tick += (_, _) => { copyReset.Stop(); copy.Content = "Copia"; };
        copy.Click += (_, _) =>
        {
            try { System.Windows.Clipboard.SetText(SpotifyPkce.RedirectUri); copy.Content = "Copiato"; }
            catch { copy.Content = "Riprova"; }
            copyReset.Stop();
            copyReset.Start();
        };

        _status = Description("");
        _connect = SettingsButton("Collega Spotify");
        _connect.Click += (_, _) => OnConnectClick();

        Children.Add(new TextBlock { Text = "Spotify", FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 10, 0, 8) });
        Children.Add(Card(
            Row("Client ID", Description("Crea un'app nella Dashboard di developer.spotify.com e incolla qui il suo Client ID."), _clientId),
            Row("Redirect URI", null, copy, uriText),
            Row("Account", _status, _connect)));

        var note = Description(
            "Con Spotify collegato, mentre suona Spotify la scheda mostra il cuore e il pulsante \"…\" (playlist, coda, cerca). " +
            "Isola chiama Spotify solo quando cambia brano o quando apri il pannello. Il token resta cifrato su questo PC; " +
            "\"Riproduci\" e \"Metti in coda\" richiedono Spotify Premium.");
        note.Margin = new Thickness(2, 0, 0, 12);
        Children.Add(note);

        Loaded += (_, _) =>
        {
            if (_spotify != null) { _spotify.LinkChanged -= Update; _spotify.LinkChanged += Update; _spotify.EnsureDisplayName(); }
            Update();
        };
        Unloaded += (_, _) => { if (_spotify != null) _spotify.LinkChanged -= Update; };
        Update();
    }

    private void SaveClientId()
    {
        string id = _clientId.Text.Trim();
        if (_clientId.Text != id) _clientId.Text = id;
        _saveClientId(id);
    }

    private void OnConnectClick()
    {
        if (_spotify == null) return;
        switch (_spotify.LinkState)
        {
            case SpotifyLinkState.Disconnected:
                SaveClientId();
                _spotify.Connect(_clientId.Text);
                break;
            case SpotifyLinkState.Connecting:
                _spotify.CancelConnect();
                break;
            case SpotifyLinkState.Connected:
                _spotify.Disconnect();
                break;
        }
    }

    private void Update()
    {
        if (_spotify == null)
        {
            _status.Text = "Attiva il modulo Musica per collegare Spotify.";
            _connect.IsEnabled = false;
            return;
        }
        _connect.IsEnabled = true;
        switch (_spotify.LinkState)
        {
            case SpotifyLinkState.Connecting:
                _status.Text = "Completa l'accesso nel browser (hai 5 minuti).";
                _connect.Content = "Annulla";
                _clientId.IsEnabled = false;
                break;
            case SpotifyLinkState.Connected:
                _status.Text = _spotify.DisplayName is { Length: > 0 } name ? $"Collegato come {name}" : "Collegato";
                _connect.Content = "Scollega";
                _clientId.IsEnabled = true;
                break;
            default:
                _status.Text = _spotify.LinkMessage.Length > 0 ? _spotify.LinkMessage : "Non collegato";
                _connect.Content = "Collega Spotify";
                _clientId.IsEnabled = true;
                break;
        }
    }

    // ---- building blocks (same look as the other settings pages) ----

    private static Brush Muted => (Brush)Application.Current.FindResource("Settings.Brush.Muted");

    private static TextBlock Description(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Foreground = Muted,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 2, 0, 0),
    };

    private static Button SettingsButton(string text)
    {
        var b = new Button { Content = text, MinWidth = 84 };
        b.SetResourceReference(StyleProperty, "Isola.Style.Button");
        return b;
    }

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

    private static FrameworkElement Row(string title, TextBlock? description, UIElement control, UIElement? extra = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 13, 0, 13) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 24, 0) };
        text.Children.Add(new TextBlock { Text = title, FontSize = 13.5, TextWrapping = TextWrapping.Wrap });
        if (extra != null) text.Children.Add(extra);
        if (description != null) text.Children.Add(description);
        grid.Children.Add(text);
        if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }
}
