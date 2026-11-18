import Foundation

/// Un evento di un hook di Claude Code, ridotto ai campi che servono.
/// Il resto del JSON (prompt, transcript_path, input degli strumenti) viene ignorato e mai salvato.
struct HookEvent: Equatable, Sendable {
    static let maxField = 300

    var sessionId: String
    var cwd: String
    var name: String
    var tool: String
    var message: String

    /// Nil se il corpo non è un oggetto JSON con `session_id` e `hook_event_name`.
    static func parse(_ body: Data) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: body, options: []),
              let root = obj as? [String: Any] else { return nil }
        func get(_ key: String) -> String {
            guard let s = root[key] as? String else { return "" }
            return s.count > maxField ? String(s.prefix(maxField)) : s
        }
        let ev = HookEvent(sessionId: get("session_id"), cwd: get("cwd"), name: get("hook_event_name"),
                           tool: get("tool_name"), message: get("message"))
        return ev.sessionId.isEmpty || ev.name.isEmpty ? nil : ev
    }

    /// L'ultima cartella di un percorso ("/Users/a/Progetti/Isola/" → "Isola").
    static func folderName(_ cwd: String) -> String {
        var t = Substring(cwd)
        while let last = t.last, last == "/" || last == "\\" { t = t.dropLast() }
        let name = t.lastIndex(where: { $0 == "/" || $0 == "\\" }).map { t[t.index(after: $0)...] } ?? t
        return name.isEmpty ? cwd : String(name)
    }
}

/// "12 s", "5 min", "2 h".
func agentElapsed(_ t: TimeInterval) -> String {
    if t < 60 { return "\(max(0, Int(t))) s" }
    if t < 3600 { return "\(Int(t / 60)) min" }
    return "\(Int(t / 3600)) h"
}
