import IsolaCore
import IsolaMusic
import IsolaAgents
import IsolaClipboard
import IsolaShelf
import IsolaControls
import IsolaCalendar
import IsolaReminders
import IsolaWidgets
import IsolaPerf
import IsolaBattery
import IsolaBluetooth
import IsolaClock

/// L'elenco dei moduli. È l'unico posto in cui il core li nomina.
@MainActor
enum ModuleRegistry {
    static let all: [IslandModule.Type] = [
        MusicModule.self,
        AgentsModule.self,
        ClipboardModule.self,
        ShelfModule.self,
        ControlsModule.self,
        CalendarModule.self,
        RemindersModule.self,
        WidgetsModule.self,
        PerfModule.self,
        BatteryModule.self,
        BluetoothModule.self,
        ClockModule.self,
    ]
}
