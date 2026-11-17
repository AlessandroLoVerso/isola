using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace Isola.Tray;

/// <summary>Draws the app icon in code: a black rounded pill with a thin light outline (so it
/// reads on both dark and light taskbars) and a small blue dot. Produces a multi-size .ico.</summary>
public static class IconFactory
{
    private static readonly int[] Sizes = { 16, 20, 24, 32, 40, 48, 64, 256 };

    public static Bitmap Render(int size)
    {
        var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(Color.Transparent);

        float stroke = Math.Max(1f, size / 16f);
        float w = size * 0.94f;
        float h = size * 0.50f;
        float x = (size - w) / 2f;
        float y = (size - h) / 2f;
        var rect = new RectangleF(x + stroke / 2, y + stroke / 2, w - stroke, h - stroke);

        using (var path = Pill(rect))
        {
            using var fill = new SolidBrush(Color.FromArgb(255, 0x0B, 0x0B, 0x0D));
            g.FillPath(fill, path);
            using var pen = new Pen(Color.FromArgb(235, 0xE6, 0xE6, 0xEA), stroke);
            g.DrawPath(pen, path);
        }

        float d = Math.Max(2f, h * 0.30f);
        float dx = rect.Right - rect.Height / 2f - d / 2f;
        float dy = rect.Top + (rect.Height - d) / 2f;
        using (var dot = new SolidBrush(Color.FromArgb(255, 0x0A, 0x84, 0xFF)))
            g.FillEllipse(dot, dx, dy, d, d);

        return bmp;
    }

    private static GraphicsPath Pill(RectangleF r)
    {
        var p = new GraphicsPath();
        float d = r.Height;
        p.AddArc(r.Left, r.Top, d, d, 90, 180);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }

    /// <summary>ICO bytes: 32-bit DIB frames up to 64 px (loadable by System.Drawing.Icon) plus a
    /// PNG 256 px frame for the shell.</summary>
    public static byte[] CreateIcoBytes()
    {
        var frames = new List<(int Size, byte[] Data)>();
        foreach (var s in Sizes)
        {
            using var bmp = Render(s);
            frames.Add((s, s >= 256 ? Png(bmp) : Dib(bmp)));
        }

        using var ms = new MemoryStream();
        using var bw = new BinaryWriter(ms);
        bw.Write((short)0);
        bw.Write((short)1);
        bw.Write((short)frames.Count);
        int offset = 6 + 16 * frames.Count;
        foreach (var (size, data) in frames)
        {
            bw.Write((byte)(size >= 256 ? 0 : size));
            bw.Write((byte)(size >= 256 ? 0 : size));
            bw.Write((byte)0);
            bw.Write((byte)0);
            bw.Write((short)1);
            bw.Write((short)32);
            bw.Write(data.Length);
            bw.Write(offset);
            offset += data.Length;
        }
        foreach (var (_, data) in frames) bw.Write(data);
        bw.Flush();
        return ms.ToArray();
    }

    public static void WriteIco(string path) => File.WriteAllBytes(path, CreateIcoBytes());

    /// <summary>The tray icon at the system's small-icon size.</summary>
    public static Icon CreateTrayIcon()
    {
        var size = System.Windows.Forms.SystemInformation.SmallIconSize;
        using var ms = new MemoryStream(CreateIcoBytes());
        return new Icon(ms, size);
    }

    private static byte[] Png(Bitmap bmp)
    {
        using var ms = new MemoryStream();
        bmp.Save(ms, ImageFormat.Png);
        return ms.ToArray();
    }

    private static byte[] Dib(Bitmap bmp)
    {
        int s = bmp.Width;
        using var ms = new MemoryStream();
        using var bw = new BinaryWriter(ms);
        // BITMAPINFOHEADER (height doubled: XOR + AND masks)
        bw.Write(40);
        bw.Write(s);
        bw.Write(s * 2);
        bw.Write((short)1);
        bw.Write((short)32);
        bw.Write(0);
        bw.Write(0);
        bw.Write(0);
        bw.Write(0);
        bw.Write(0);
        bw.Write(0);

        var data = bmp.LockBits(new Rectangle(0, 0, s, s), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var row = new byte[s * 4];
            for (int y = s - 1; y >= 0; y--) // bottom-up
            {
                System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                bw.Write(row);
            }
        }
        finally
        {
            bmp.UnlockBits(data);
        }

        // AND mask: all zero (alpha channel carries transparency); rows padded to 32 bits.
        int maskStride = ((s + 31) / 32) * 4;
        bw.Write(new byte[maskStride * s]);
        bw.Flush();
        return ms.ToArray();
    }
}
