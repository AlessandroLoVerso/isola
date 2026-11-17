using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Isola.Modules.Music;

/// <summary>Decodes album covers and finds their dominant saturated colour. Thread-safe (frozen output).</summary>
internal static class CoverArt
{
    public static BitmapSource? Decode(byte[] bytes, int pixelWidth)
    {
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            img.StreamSource = new MemoryStream(bytes);
            img.DecodePixelWidth = pixelWidth;
            img.EndInit();
            img.Freeze();
            return img;
        }
        catch { return null; }
    }

    /// <summary>Downscales to 8x8 and picks the most saturated, reasonably bright pixel, then
    /// lifts it so it reads well on the dark island. Null when the cover is basically grey.</summary>
    public static Color? DominantColor(byte[] bytes)
    {
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            img.StreamSource = new MemoryStream(bytes);
            img.DecodePixelWidth = 8;
            img.DecodePixelHeight = 8;
            img.EndInit();
            img.Freeze();

            var bgra = new FormatConvertedBitmap(img, PixelFormats.Bgra32, null, 0);
            int w = bgra.PixelWidth, h = bgra.PixelHeight;
            var px = new byte[w * h * 4];
            bgra.CopyPixels(px, w * 4, 0);

            double bestScore = -1, bestH = 0, bestS = 0, bestV = 0;
            for (int i = 0; i < px.Length; i += 4)
            {
                ToHsv(px[i + 2], px[i + 1], px[i], out double hue, out double s, out double v);
                if (v < 0.18) continue; // letterbox bars, shadows
                double score = s * (0.35 + 0.65 * v);
                if (score > bestScore) { bestScore = score; bestH = hue; bestS = s; bestV = v; }
            }
            if (bestScore < 0 || bestS < 0.2) return null;

            double sat = Math.Clamp(bestS, 0.45, 0.8);
            double val = Math.Max(bestV, 0.88);
            return FromHsv(bestH, sat, val);
        }
        catch { return null; }
    }

    private static void ToHsv(byte r8, byte g8, byte b8, out double h, out double s, out double v)
    {
        double r = r8 / 255.0, g = g8 / 255.0, b = b8 / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), d = max - min;
        v = max;
        s = max <= 0 ? 0 : d / max;
        if (d <= 0) { h = 0; return; }
        if (max == r) h = 60 * (((g - b) / d) % 6);
        else if (max == g) h = 60 * ((b - r) / d + 2);
        else h = 60 * ((r - g) / d + 4);
        if (h < 0) h += 360;
    }

    private static Color FromHsv(double h, double s, double v)
    {
        double c = v * s, x = c * (1 - Math.Abs(h / 60 % 2 - 1)), m = v - c;
        (double r, double g, double b) = h switch
        {
            < 60 => (c, x, 0.0),
            < 120 => (x, c, 0.0),
            < 180 => (0.0, c, x),
            < 240 => (0.0, x, c),
            < 300 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        return Color.FromRgb((byte)Math.Round((r + m) * 255), (byte)Math.Round((g + m) * 255), (byte)Math.Round((b + m) * 255));
    }
}
