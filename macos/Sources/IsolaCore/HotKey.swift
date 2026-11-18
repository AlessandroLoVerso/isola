import Carbon.HIToolbox
import Foundation

/// Scorciatoia globale (Carbon RegisterEventHotKey): non chiede il permesso di Accessibilità.
/// Esempio: `HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)) { ... }`.
/// `isRegistered` è falso se la combinazione è già presa da un'altra app.
@MainActor
public final class HotKey {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public private(set) var isRegistered = false

    private var ref: EventHotKeyRef?
    private let handler: () -> Void
    private let hotKeyID: UInt32

    private static var nextID: UInt32 = 1
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false

    public init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
        self.hotKeyID = HotKey.nextID
        HotKey.nextID += 1
        HotKey.installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4953_4C41), id: hotKeyID) // "ISLA"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr
        if isRegistered { HotKey.handlers[hotKeyID] = handler }
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        isRegistered = false
        HotKey.handlers[hotKeyID] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[key]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
