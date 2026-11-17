using System.Text.Json;
using System.Text.Json.Nodes;

namespace Isola.Modules.Agents;

/// <summary>Adds / removes Isola's curl hooks in a Claude Code settings.json, leaving everything
/// else untouched. Pure file logic (path in, result out) so it can be tested on a copy.</summary>
public static class HooksInstaller
{
    public const string Command = "curl -s -m 1 -X POST http://127.0.0.1:47321/agent --data-binary @-";

    /// <summary>Event name → matcher (null = no matcher).</summary>
    public static readonly (string Event, string? Matcher)[] Events =
    {
        ("UserPromptSubmit", null), ("PreToolUse", "*"), ("PostToolUse", "*"),
        ("Notification", null), ("Stop", null), ("SessionEnd", null),
    };

    public static string DefaultPath =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "settings.json");

    /// <summary>True when every event already has our hook.</summary>
    public static bool IsInstalled(string path)
    {
        try
        {
            if (!File.Exists(path)) return false;
            var hooks = Load(path)["hooks"] as JsonObject;
            return hooks != null && Events.All(e => hooks[e.Event] is JsonArray a && Contains(a));
        }
        catch { return false; }
    }

    /// <summary>Merges our hooks. Returns the number of entries added; backs up first.</summary>
    public static int Install(string path)
    {
        var root = File.Exists(path) ? Load(path) : new JsonObject();
        // Never replace something we don't understand: a "hooks" that isn't an object (or an event
        // that isn't an array) stops the merge instead of being overwritten.
        JsonObject hooks;
        if (root["hooks"] is null) { hooks = new JsonObject(); root["hooks"] = hooks; }
        else hooks = root["hooks"] as JsonObject ?? throw new InvalidDataException("\"hooks\" in settings.json non è un oggetto");
        int added = 0;
        foreach (var (ev, matcher) in Events)
        {
            JsonArray groups;
            if (hooks[ev] is null) { groups = new JsonArray(); hooks[ev] = groups; }
            else groups = hooks[ev] as JsonArray ?? throw new InvalidDataException($"\"hooks.{ev}\" in settings.json non è una lista");
            if (Contains(groups)) continue;
            var group = new JsonObject();
            if (matcher != null) group["matcher"] = matcher;
            group["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = Command });
            groups.Add(group);
            added++;
        }
        if (added > 0) Save(path, root);
        return added;
    }

    /// <summary>Removes exactly our entries (and groups/events left empty by that). Returns count.</summary>
    public static int Uninstall(string path)
    {
        if (!File.Exists(path)) return 0;
        var root = Load(path);
        if (root["hooks"] is not JsonObject hooks) return 0;
        int removed = 0;
        foreach (var (ev, _) in Events)
        {
            if (hooks[ev] is not JsonArray groups) continue;
            for (int g = groups.Count - 1; g >= 0; g--)
            {
                if (groups[g] is not JsonObject grp || grp["hooks"] is not JsonArray list) continue;
                bool hadOurs = false;
                for (int i = list.Count - 1; i >= 0; i--)
                    if (IsOurs(list[i])) { list.RemoveAt(i); removed++; hadOurs = true; }
                if (hadOurs && list.Count == 0) groups.RemoveAt(g);
            }
            if (groups.Count == 0) hooks.Remove(ev);
        }
        if (hooks.Count == 0) root.Remove("hooks");
        if (removed > 0) Save(path, root);
        return removed;
    }

    private static bool Contains(JsonArray groups) =>
        groups.OfType<JsonObject>().Any(g => g["hooks"] is JsonArray l && l.Any(IsOurs));

    private static bool IsOurs(JsonNode? n) =>
        n is JsonObject o && o["command"] is JsonValue v && v.TryGetValue<string>(out var s) && s == Command;

    private static JsonObject Load(string path)
    {
        var text = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(text)) return new JsonObject();
        return JsonNode.Parse(text, documentOptions: new JsonDocumentOptions
        { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true }) as JsonObject
            ?? throw new InvalidDataException("settings.json non è un oggetto JSON");
    }

    private static void Save(string path, JsonObject root)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        if (File.Exists(path))
            File.Copy(path, $"{path}.isola-backup-{DateTime.Now:yyyyMMdd-HHmmss-fff}", overwrite: true);
        // Relaxed escaping keeps the user's other entries readable ("&&", "<", accents) instead of
        // turning them into escape sequences; the JSON is the same either way.
        var json = root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
        JsonNode.Parse(json); // sanity check before anything is replaced
        var tmp = path + ".isola-tmp";
        try
        {
            using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
            using (var w = new StreamWriter(fs, new System.Text.UTF8Encoding(false)))
            {
                w.Write(json);
                w.Flush();
                fs.Flush(flushToDisk: true);
            }
            File.Move(tmp, path, overwrite: true); // atomic replace: the old file or the new one, never half
        }
        catch
        {
            try { File.Delete(tmp); } catch { }
            throw;
        }
    }
}
