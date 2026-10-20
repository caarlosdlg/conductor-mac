import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: EngineClient?

    /// Carpetas soltadas sobre el icono del Dock o abiertas con «Abrir con».
    func application(_ application: NSApplication, open urls: [URL]) {
        engine?.addProjects(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // El motor arranca con la app, haya o no ventana abierta.
        engine = EngineClient.shared
        EngineClient.shared.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Cerrar la ventana no detiene el trabajo: sigue en la barra de menús.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let e = engine, e.running > 0 {
            let a = NSAlert()
            a.messageText = "Hay \(e.running) tarea(s) en ejecución"
            a.informativeText = "Si sales, se detienen; al abrir Conductor otra vez se reanudan solas desde donde quedaron."
            a.addButton(withTitle: "Salir")
            a.addButton(withTitle: "Cancelar")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        engine?.stop()
        return .terminateNow
    }
}

@main
struct ConductorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var engine = EngineClient.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Conductor", id: "main") {
            MainView()
                .environment(engine)
                .frame(minWidth: 1000, minHeight: 600)
                .onAppear { boot() }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Añadir proyecto…") { engine.addProjects(FinderPicker.chooseFolders()) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Importar tareas") { engine.importTasks() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environment(engine)
        }

        MenuBarExtra {
            MenuBarContent().environment(engine)
        } label: {
            let n = engine.tasks.filter(\.needsAttention).count
            Label(engine.running > 0 ? "\(engine.running)" : (n > 0 ? "\(n)" : ""),
                  systemImage: n > 0 ? "bolt.badge.exclamationmark.fill" : (engine.running > 0 ? "bolt.fill" : "bolt"))
        }
    }

    private func boot() {
        delegate.engine = engine
        engine.start() // idempotente
    }
}

struct MenuBarContent: View {
    @Environment(EngineClient.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(engine.running) corriendo · \(engine.tasks.filter(\.needsAttention).count) requieren atención")
        Divider()
        let attention = engine.tasks.filter(\.needsAttention)
        ForEach(attention.prefix(8)) { t in
            if t.gate?.type == "deploy" {
                Button("Aprobar deploy: \(t.title.prefix(40))") { engine.approve(t.id) }
            } else {
                Button("\(t.status.label): \(t.title.prefix(40))") { show() }
            }
        }
        if !attention.isEmpty { Divider() }
        Button("Abrir Conductor") { show() }
        Button("Detener todo") { engine.stopAll() }.disabled(engine.running == 0)
        Divider()
        Button("Salir") { NSApplication.shared.terminate(nil) }
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
