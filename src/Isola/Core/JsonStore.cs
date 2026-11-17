using System.Text.Json;
using System.Text.Json.Serialization;

namespace Isola.Core;

/// <summary>JSON load/save with atomic writes. Corrupt or missing files yield new T().</summary>
public static class JsonStore
{
    private static readonly object Gate = new();

    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static T Load<T>(string path) where T : new()
    {
        try
        {
            lock (Gate)
            {
                if (!File.Exists(path)) return new T();
                var json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<T>(json, Options) ?? new T();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"Impostazioni illeggibili, uso i valori predefiniti: {Path.GetFileName(path)} ({ex.GetType().Name})");
            return new T();
        }
    }

    public static void Save<T>(string path, T value)
    {
        try
        {
            var json = JsonSerializer.Serialize(value, Options);
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                WriteAtomic(path, json);
            }
        }
        catch (Exception ex)
        {
            Log.Error($"Salvataggio non riuscito: {Path.GetFileName(path)}", ex);
        }
    }

    /// <summary>Writes "path.tmp", flushes it to disk, then renames it over the file: a crash or a
    /// power cut leaves either the old file or the new one, never a truncated one.</summary>
    public static void WriteAtomic(string path, string text)
    {
        var tmp = path + ".tmp";
        using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        using (var w = new StreamWriter(fs, new System.Text.UTF8Encoding(false)))
        {
            w.Write(text);
            w.Flush();
            fs.Flush(flushToDisk: true);
        }
        File.Move(tmp, path, overwrite: true);
    }
}
