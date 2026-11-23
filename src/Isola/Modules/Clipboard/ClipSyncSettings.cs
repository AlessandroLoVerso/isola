using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Isola.Modules.Clipboard;

/// <summary>The "Appunti condivisi" section of the Clipboard settings page.</summary>
internal static class ClipSyncSettings
{
    private static readonly Brush Separator = Frozen(Color.FromRgb(0x2A, 0x2A, 0x30));
    private static readonly Brush Green = Frozen(Color.FromRgb(0x30, 0xD1, 0x58));
    private static readonly Brush Red = Frozen(Color.FromRgb(0xFF, 0x6B, 0x61));
    private static readonly Brush Grey = Frozen(Color.FromRgb(0x6E, 0x6E, 0x78));

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    public static FrameworkElement Build(ClipSync sync)
    {
        var root = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        root.Children.Add(new TextBlock
        {
            Text = "Appunti condivisi",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(2, 6, 0, 8),
        });

        // ---- Master toggle
        var master = Toggle("Condividi con un altro computer", sync.Enabled);
        var masterRow = ClipboardModule.Row("", "Quello che copi qui arriva sull'altro computer, e viceversa: testo e immagini, "
                                              + "solo attraverso Tailscale. Con «Pausa cronologia» attiva non parte niente.", master, hideTitle: true);

        // ---- Other computer
        var peer = new TextBox { Text = sync.Peer, Width = 250 };
        peer.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.TextBox");
        peer.TextChanged += (_, _) => sync.SetPeer(peer.Text);
        var peerRow = ClipboardModule.Row("Altro computer", "Il suo nome su Tailscale (per esempio macbook-air-di-alessandro) o l'indirizzo 100.x.", peer);

        // ---- Pairing key
        var generate = new Button();
        generate.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.Button");
        var keyBox = new TextBox
        {
            Text = sync.KeyText ?? "",
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 13.5,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        keyBox.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.TextBox");
        var keyHintOverlay = ClipboardModule.Muted("Incolla qui la chiave dell'altro computer");
        keyHintOverlay.IsHitTestVisible = false;
        keyHintOverlay.Margin = new Thickness(11, 0, 0, 1);
        keyHintOverlay.VerticalAlignment = VerticalAlignment.Center;
        var keyGrid = new Grid();
        keyGrid.Children.Add(keyBox);
        keyGrid.Children.Add(keyHintOverlay);

        var copy = new Button { Content = "Copia", Margin = new Thickness(8, 0, 0, 0) };
        copy.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.Button");
        var keyLine = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        keyLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        keyLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        keyLine.Children.Add(keyGrid);
        Grid.SetColumn(copy, 1);
        keyLine.Children.Add(copy);
        var keyNote = ClipboardModule.Muted("");
        keyNote.Margin = new Thickness(2, 4, 0, 14);

        var keyStack = new StackPanel();
        keyStack.Children.Add(ClipboardModule.Row("Chiave di abbinamento",
            "La stessa sui due computer: generala qui e scrivila sull'altro, oppure incolla quella che ti ha dato l'altro.", generate));
        keyStack.Children.Add(keyLine);
        keyStack.Children.Add(keyNote);

        bool updating = false, armed = false;
        void ShowKeyState(string? error = null)
        {
            bool has = sync.HasKey;
            keyHintOverlay.Visibility = keyBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            copy.IsEnabled = has && error == null;
            if (!armed) generate.Content = has ? "Nuova chiave" : "Genera chiave";
            if (error != null)
            {
                keyNote.Text = error;
                keyNote.Foreground = Red;
            }
            else
            {
                keyNote.Text = has ? "Salvata cifrata su questo PC (solo il tuo account Windows può leggerla)." : "Nessuna chiave: generane una o incollala.";
                keyNote.SetResourceReference(TextBlock.ForegroundProperty, "Settings.Brush.Muted");
            }
        }
        keyBox.TextChanged += (_, _) =>
        {
            if (updating) return;
            var text = keyBox.Text;
            if (text.Trim().Length == 0)
            {
                sync.ClearKey();
                ShowKeyState();
                return;
            }
            if (!sync.TrySetKey(text))
            {
                ShowKeyState("Non è una chiave valida: servono 32 caratteri (lettere A–Z e cifre 2–7), i trattini non contano.");
                return;
            }
            var formatted = sync.KeyText!;
            if (keyBox.Text != formatted)
            {
                updating = true;
                keyBox.Text = formatted;
                keyBox.CaretIndex = formatted.Length;
                updating = false;
            }
            ShowKeyState();
        };
        keyBox.LostKeyboardFocus += (_, _) =>
        {
            // Half-typed or wrong text: show the saved key again.
            if (ClipSyncProtocol.ParseKey(keyBox.Text) != null || keyBox.Text.Trim().Length == 0) return;
            updating = true;
            keyBox.Text = sync.KeyText ?? "";
            updating = false;
            ShowKeyState();
        };
        generate.Click += (_, _) =>
        {
            if (sync.HasKey && !armed)
            {
                // Replacing the key breaks the pairing until the other computer has the new one.
                armed = true;
                generate.Content = "Conferma";
                generate.SetResourceReference(Control.BackgroundProperty, "Isola.Brush.Accent");
                return;
            }
            armed = false;
            generate.ClearValue(Control.BackgroundProperty);
            updating = true;
            keyBox.Text = sync.GenerateKey();
            updating = false;
            ShowKeyState();
        };
        DispatcherTimer? copiedTimer = null;
        copy.Click += (_, _) =>
        {
            if (sync.KeyText is not { } key) return;
            if (!CopyPrivately(key)) { keyNote.Text = "Appunti occupati, riprova."; return; }
            copy.Content = "Copiata";
            copiedTimer?.Stop();
            copiedTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.6) };
            copiedTimer.Tick += (_, _) => { copiedTimer!.Stop(); copy.Content = "Copia"; };
            copiedTimer.Start();
        };
        ShowKeyState();

        // ---- Pause
        var pause = Toggle("Pausa condivisione", sync.Paused);
        pause.Checked += (_, _) => sync.SetPaused(true);
        pause.Unchecked += (_, _) => sync.SetPaused(false);
        var pauseRow = ClipboardModule.Row("", "Finché è attiva non invia e non riceve niente.", pause, hideTitle: true);

        // ---- Status
        var dot = new Ellipse { Width = 8, Height = 8, Margin = new Thickness(2, 6, 12, 0), VerticalAlignment = VerticalAlignment.Top };
        var statusText = new TextBlock { FontSize = 13.5, TextWrapping = TextWrapping.Wrap };
        var listenText = ClipboardModule.Muted("");
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        texts.Children.Add(statusText);
        texts.Children.Add(listenText);
        var test = new Button { Content = "Prova" };
        test.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.Button");
        test.VerticalAlignment = VerticalAlignment.Center;
        var statusRow = new Grid { Margin = new Thickness(0, 12, 0, 12) };
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        statusRow.Children.Add(dot);
        Grid.SetColumn(texts, 1);
        statusRow.Children.Add(texts);
        Grid.SetColumn(test, 2);
        statusRow.Children.Add(test);

        void ShowStatus()
        {
            string peerStatus = sync.PeerStatus;
            if (peerStatus.Length == 0)
                peerStatus = !sync.Enabled ? "Condivisione spenta" : "Premi Prova per controllare il collegamento";
            statusText.Text = peerStatus;
            dot.Fill = sync.PeerTone switch { ClipSyncTone.Ok => Green, ClipSyncTone.Error => Red, _ => Grey };
            var listen = sync.Enabled ? sync.ListenStatus : "Quando la accendi, Isola ascolta solo sull'indirizzo Tailscale di questo PC.";
            if (sync.Enabled && sync.Paused) listen = (listen.Length > 0 ? listen + " · " : "") + "in pausa";
            listenText.Text = listen;
            listenText.Visibility = listen.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        test.Click += (_, _) => _ = sync.TestAsync();
        master.Checked += (_, _) => { sync.SetEnabled(true); ShowStatus(); };
        master.Unchecked += (_, _) => { sync.SetEnabled(false); ShowStatus(); };
        pause.Checked += (_, _) => ShowStatus();
        pause.Unchecked += (_, _) => ShowStatus();
        ShowStatus();

        root.Loaded += (_, _) =>
        {
            sync.StatusChanged -= ShowStatus;
            sync.StatusChanged += ShowStatus;
            ShowStatus();
            // Checked when the page opens (only if sharing is on and set up) and on "Prova".
            if (sync.Enabled && sync.HasKey && sync.Peer.Length > 0) _ = sync.TestAsync();
        };
        root.Unloaded += (_, _) => sync.StatusChanged -= ShowStatus;

        root.Children.Add(Card(masterRow, peerRow, keyStack, pauseRow, statusRow));
        return root;
    }

    /// <summary>Puts the key on the clipboard marked "don't record/sync", so neither our history
    /// (nor Windows' own) keeps it, and it is never shared.</summary>
    private static bool CopyPrivately(string text)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[] { 0, 0, 0, 0 }));
        data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
        data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
        try { System.Windows.Clipboard.SetDataObject(data, true); return true; }
        catch (System.Runtime.InteropServices.ExternalException) { return false; }
    }

    private static CheckBox Toggle(string label, bool isChecked)
    {
        var t = new CheckBox { IsChecked = isChecked, Content = label };
        t.SetResourceReference(FrameworkElement.StyleProperty, "Isola.Style.ToggleSwitch");
        return t;
    }

    private static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(new Border { Height = 1, Background = Separator });
            stack.Children.Add(rows[i]);
        }
        return ClipboardModule.SettingCard(stack);
    }
}
