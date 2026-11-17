using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Isola.Modules.Widgets;

public enum WeatherKind { Clear, PartlyCloudy, Cloudy, Fog, Drizzle, Rain, Snow, Thunder }

internal sealed record WeatherNow(double Temperature, int Code, bool IsDay, double? Max, double? Min, DateTime Fetched)
{
    public WeatherKind Kind => WeatherCodes.Kind(Code);
    public string Label => WeatherCodes.Label(Code, IsDay);
    public string TemperatureText => $"{Math.Round(Temperature).ToString("0", CultureInfo.InvariantCulture)}°";
}

internal sealed record GeoPlace(string Label, double Latitude, double Longitude);

/// <summary>Open-Meteo (no key). Only the city name typed by the user leaves the PC.</summary>
internal static class WeatherClient
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    static WeatherClient() => Http.DefaultRequestHeaders.UserAgent.ParseAdd("Isola/0.1");

    public static async Task<GeoPlace?> GeocodeAsync(string city, CancellationToken ct)
    {
        var url = $"https://geocoding-api.open-meteo.com/v1/search?name={Uri.EscapeDataString(city.Trim())}&count=1&language=it&format=json";
        using var doc = JsonDocument.Parse(await Http.GetStringAsync(url, ct).ConfigureAwait(false));
        if (!doc.RootElement.TryGetProperty("results", out var results) || results.GetArrayLength() == 0) return null;
        var r = results[0];
        var name = r.GetProperty("name").GetString() ?? city;
        var parts = new List<string> { name };
        if (r.TryGetProperty("admin1", out var a1) && a1.GetString() is { Length: > 0 } admin && admin != name) parts.Add(admin);
        if (r.TryGetProperty("country", out var c) && c.GetString() is { Length: > 0 } country) parts.Add(country);
        return new GeoPlace(string.Join(", ", parts), r.GetProperty("latitude").GetDouble(), r.GetProperty("longitude").GetDouble());
    }

    public static async Task<WeatherNow> ForecastAsync(double lat, double lon, CancellationToken ct)
    {
        var inv = CultureInfo.InvariantCulture;
        var url = "https://api.open-meteo.com/v1/forecast?latitude=" + lat.ToString("0.####", inv) +
                  "&longitude=" + lon.ToString("0.####", inv) +
                  "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto";
        using var doc = JsonDocument.Parse(await Http.GetStringAsync(url, ct).ConfigureAwait(false));
        var cur = doc.RootElement.GetProperty("current");
        double? max = null, min = null;
        if (doc.RootElement.TryGetProperty("daily", out var daily))
        {
            if (daily.TryGetProperty("temperature_2m_max", out var mx) && mx.GetArrayLength() > 0 && mx[0].ValueKind == JsonValueKind.Number) max = mx[0].GetDouble();
            if (daily.TryGetProperty("temperature_2m_min", out var mn) && mn.GetArrayLength() > 0 && mn[0].ValueKind == JsonValueKind.Number) min = mn[0].GetDouble();
        }
        return new WeatherNow(
            cur.GetProperty("temperature_2m").GetDouble(),
            cur.GetProperty("weather_code").GetInt32(),
            !cur.TryGetProperty("is_day", out var d) || d.GetInt32() == 1,
            max, min, DateTime.Now);
    }
}

/// <summary>WMO weather codes used by Open-Meteo.</summary>
internal static class WeatherCodes
{
    public static WeatherKind Kind(int code) => code switch
    {
        0 or 1 => WeatherKind.Clear,
        2 => WeatherKind.PartlyCloudy,
        3 => WeatherKind.Cloudy,
        45 or 48 => WeatherKind.Fog,
        51 or 53 or 55 or 56 or 57 => WeatherKind.Drizzle,
        61 or 63 or 65 or 66 or 67 or 80 or 81 or 82 => WeatherKind.Rain,
        71 or 73 or 75 or 77 or 85 or 86 => WeatherKind.Snow,
        95 or 96 or 99 => WeatherKind.Thunder,
        _ => WeatherKind.Cloudy,
    };

    public static string Label(int code, bool isDay) => code switch
    {
        0 => isDay ? "Sereno" : "Notte serena",
        1 => "Poco nuvoloso",
        2 => "Parzialmente nuvoloso",
        3 => "Coperto",
        45 => "Nebbia",
        48 => "Nebbia con brina",
        51 => "Pioviggine leggera",
        53 => "Pioviggine",
        55 => "Pioviggine intensa",
        56 or 57 => "Pioviggine gelata",
        61 => "Pioggia leggera",
        63 => "Pioggia",
        65 => "Pioggia forte",
        66 or 67 => "Pioggia gelata",
        71 => "Neve leggera",
        73 => "Neve",
        75 => "Neve forte",
        77 => "Nevischio",
        80 => "Rovesci leggeri",
        81 => "Rovesci",
        82 => "Rovesci violenti",
        85 or 86 => "Rovesci di neve",
        95 => "Temporale",
        96 or 99 => "Temporale con grandine",
        _ => "Variabile",
    };
}

/// <summary>Weather icons built from Segoe Fluent Icons outlines (sun, moon, cloud, bolt), with
/// rain/snow marks drawn under the cloud and the sun cut out where the cloud covers it.</summary>
internal static class WeatherIcon
{
    private const string Sun = "", Moon = "", Cloud = "", Bolt = "";
    private static readonly Dictionary<(WeatherKind, bool), Geometry> Cache = new();

    /// <summary>A new element of the given size, filled with the given brush resource key.</summary>
    public static FrameworkElement Create(WeatherKind kind, bool isDay, double size, string brushKey = "Isola.Brush.Foreground")
    {
        var path = new System.Windows.Shapes.Path { Data = Get(kind, isDay) };
        path.SetResourceReference(Shape.FillProperty, brushKey);
        var canvas = new Canvas { Width = 24, Height = 24 };
        canvas.Children.Add(path);
        return new Viewbox { Width = size, Height = size, Child = canvas, Stretch = Stretch.Uniform };
    }

    public static Geometry Get(WeatherKind kind, bool isDay)
    {
        if (Cache.TryGetValue((kind, isDay), out var g)) return g;
        g = Build(kind, isDay);
        g.Freeze();
        Cache[(kind, isDay)] = g;
        return g;
    }

    private static Geometry Build(WeatherKind kind, bool isDay)
    {
        string body = isDay ? Sun : Moon;
        switch (kind)
        {
            case WeatherKind.Clear:
                return GlyphIn(body, new Rect(1, 1, 22, 22));
            case WeatherKind.Cloudy:
                return GlyphIn(Cloud, new Rect(0.5, 2, 23, 20));
            case WeatherKind.PartlyCloudy:
            {
                var cloud = GlyphIn(Cloud, new Rect(0, 7.5, 19, 15));
                var sun = GlyphIn(body, new Rect(isDay ? 8 : 10, 0.5, isDay ? 15.5 : 13, isDay ? 15.5 : 13));
                var cut = Silhouette(cloud, 2.2);
                return Combine(Geometry.Combine(sun, cut, GeometryCombineMode.Exclude, null), cloud);
            }
        }

        // Precipitation, fog, thunder: smaller cloud on top, marks below.
        var top = GlyphIn(Cloud, new Rect(1.5, 0.5, 21, 15));
        var marks = new GeometryGroup { FillRule = FillRule.Nonzero };
        switch (kind)
        {
            case WeatherKind.Rain:
                for (int i = 0; i < 3; i++) marks.Children.Add(Line(7.5 + i * 4.5, 16.5, 6 + i * 4.5, 22, 1.5));
                break;
            case WeatherKind.Drizzle:
                for (int i = 0; i < 3; i++) marks.Children.Add(Line(7.5 + i * 4.5, 17.5, 6.8 + i * 4.5, 20, 1.5));
                break;
            case WeatherKind.Snow:
                for (int i = 0; i < 3; i++) marks.Children.Add(new EllipseGeometry(new Point(7 + i * 4.5, 19 + (i % 2) * 2), 1.3, 1.3));
                break;
            case WeatherKind.Fog:
                marks.Children.Add(Line(4, 18.5, 20, 18.5, 1.5));
                marks.Children.Add(Line(7, 22, 17, 22, 1.5));
                break;
            case WeatherKind.Thunder:
                marks.Children.Add(GlyphIn(Bolt, new Rect(8.5, 13.5, 8, 10)));
                break;
        }
        var cutMarks = Geometry.Combine(marks, Silhouette(top, 2), GeometryCombineMode.Exclude, null);
        return Combine(top, cutMarks);
    }

    private static Geometry Combine(Geometry a, Geometry b)
    {
        var g = new GeometryGroup { FillRule = FillRule.Nonzero };
        g.Children.Add(a);
        g.Children.Add(b);
        return g;
    }

    private static Geometry Line(double x1, double y1, double x2, double y2, double thickness)
        => new LineGeometry(new Point(x1, y1), new Point(x2, y2))
            .GetWidenedPathGeometry(new Pen(Brushes.Black, thickness) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round });

    /// <summary>The glyph outline scaled uniformly to fit (and centred in) <paramref name="target"/>.</summary>
    private static Geometry GlyphIn(string glyph, Rect target)
    {
        var ft = new FormattedText(glyph, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            100, Brushes.Black, 1.0);
        var geo = ft.BuildGeometry(new Point(0, 0)).GetFlattenedPathGeometry(0.02, ToleranceType.Relative);
        var b = geo.Bounds;
        if (b.IsEmpty || b.Width <= 0) return Geometry.Empty;
        double s = Math.Min(target.Width / b.Width, target.Height / b.Height);
        var tg = new TransformGroup();
        tg.Children.Add(new TranslateTransform(-b.X, -b.Y));
        tg.Children.Add(new ScaleTransform(s, s));
        tg.Children.Add(new TranslateTransform(target.X + (target.Width - b.Width * s) / 2, target.Y + (target.Height - b.Height * s) / 2));
        var result = geo.Clone();
        result.Transform = tg;
        return result.GetFlattenedPathGeometry(0.01, ToleranceType.Absolute);
    }

    /// <summary>Filled outer shape of an outline glyph, grown by <paramref name="gap"/> so whatever is
    /// cut with it keeps a clean margin.</summary>
    private static Geometry Silhouette(Geometry outline, double gap)
    {
        var flat = outline.GetFlattenedPathGeometry();
        PathFigure? outer = null;
        double best = -1;
        foreach (var f in flat.Figures)
        {
            var area = new PathGeometry(new[] { f }).Bounds;
            double a = area.Width * area.Height;
            if (a > best) { best = a; outer = f; }
        }
        if (outer == null) return Geometry.Empty;
        var filled = new PathGeometry(new[] { outer.Clone() }) { FillRule = FillRule.Nonzero };
        var widened = filled.GetWidenedPathGeometry(new Pen(Brushes.Black, gap * 2));
        return Geometry.Combine(filled, widened, GeometryCombineMode.Union, null);
    }
}
