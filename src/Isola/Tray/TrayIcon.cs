using System.Drawing;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace Isola.Tray;

/// <summary>Notification-area icon with the menu "Impostazioni / Riavvia / Esci".</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.ContextMenuStrip _menu;
    private readonly Icon _image;

    public TrayIcon(Action openSettings, Action restart, Action exit)
    {
        _image = IconFactory.CreateTrayIcon();

        _menu = new Forms.ContextMenuStrip
        {
            Renderer = new DarkRenderer(),
            ShowImageMargin = false,
            BackColor = DarkRenderer.Back,
            ForeColor = DarkRenderer.Text,
            Font = new Font("Segoe UI", 9.5f),
            Padding = new Forms.Padding(0, 4, 0, 4),
        };
        _menu.Items.Add(Item("Impostazioni", openSettings));
        _menu.Items.Add(Item("Riavvia", restart));
        _menu.Items.Add(new Forms.ToolStripSeparator());
        _menu.Items.Add(Item("Esci", exit));
        // Windows 11: rounded corners and the system border, like the shell's own menus.
        _menu.Opened += (_, _) =>
        {
            if (Environment.OSVersion.Version.Build < 22000) return;
            int round = 3; // DWMWCP_ROUNDSMALL
            DwmSetWindowAttribute(_menu.Handle, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
            int border = 0x00423A3A; // COLORREF of #3A3A42
            DwmSetWindowAttribute(_menu.Handle, 34 /* DWMWA_BORDER_COLOR */, ref border, sizeof(int));
        };

        _icon = new Forms.NotifyIcon
        {
            Icon = _image,
            Text = "Isola",
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) openSettings();
        };
    }

    private static Forms.ToolStripMenuItem Item(string text, Action onClick)
    {
        var item = new Forms.ToolStripMenuItem(text) { Padding = new Forms.Padding(10, 5, 24, 5) };
        item.Click += (_, _) => onClick();
        return item;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
        _image.Dispose();
    }

    private sealed class DarkRenderer : Forms.ToolStripProfessionalRenderer
    {
        public static readonly Color Back = Color.FromArgb(0x20, 0x20, 0x24);
        public static readonly Color Text = Color.FromArgb(0xF2, 0xF2, 0xF5);
        private static readonly Color Hover = Color.FromArgb(0x33, 0x33, 0x3A);
        private static readonly Color Line = Color.FromArgb(0x3A, 0x3A, 0x42);

        public DarkRenderer() : base(new DarkColors()) => RoundedEdges = false;

        protected override void OnRenderMenuItemBackground(Forms.ToolStripItemRenderEventArgs e)
        {
            var r = new Rectangle(4, 1, e.Item.Width - 8, e.Item.Height - 2);
            using var b = new SolidBrush(e.Item.Selected ? Hover : Back);
            e.Graphics.FillRectangle(b, e.Item.Selected ? r : new Rectangle(Point.Empty, e.Item.Size));
        }

        protected override void OnRenderItemText(Forms.ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = Text;
            base.OnRenderItemText(e);
        }

        protected override void OnRenderSeparator(Forms.ToolStripSeparatorRenderEventArgs e)
        {
            int y = e.Item.Height / 2;
            using var p = new Pen(Line);
            e.Graphics.DrawLine(p, 8, y, e.Item.Width - 8, y);
        }

        protected override void OnRenderToolStripBorder(Forms.ToolStripRenderEventArgs e)
        {
            if (Environment.OSVersion.Version.Build >= 22000) return; // DWM draws a rounded border
            using var p = new Pen(Line);
            e.Graphics.DrawRectangle(p, 0, 0, e.AffectedBounds.Width - 1, e.AffectedBounds.Height - 1);
        }

        protected override void OnRenderToolStripBackground(Forms.ToolStripRenderEventArgs e)
        {
            using var b = new SolidBrush(Back);
            e.Graphics.FillRectangle(b, e.AffectedBounds);
        }
    }

    private sealed class DarkColors : Forms.ProfessionalColorTable
    {
        public override Color MenuBorder => Color.FromArgb(0x3A, 0x3A, 0x42);
        public override Color ToolStripDropDownBackground => DarkRenderer.Back;
        public override Color ImageMarginGradientBegin => DarkRenderer.Back;
        public override Color ImageMarginGradientMiddle => DarkRenderer.Back;
        public override Color ImageMarginGradientEnd => DarkRenderer.Back;
    }
}
