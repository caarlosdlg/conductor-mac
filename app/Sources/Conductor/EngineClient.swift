import Foundation
import Observation
import AppKit
import UserNotifications

/// Lanza el motor Node como proceso hijo y mantiene el estado reflejado para la UI.
@MainActor
@Observable
final class EngineClient {
    static let shared = EngineClient()
    var tasks: [TaskItem] = []
    var config: AppConfig?
    var running = 0
    var connected = false
    var toast: String?
    var fatal: String?
    var limits: UsageLimits?
    var blockedUntil: Date?
    var refreshingLimits = false

    private var process: Process?
    private var input: FileHandle?
    private var stderrTail = ""
    private var activity: NSObjectProtocol?
    private var toastWork: DispatchWorkItem?
    /// Carpetas recibidas (Dock/Finder) antes de que el motor enviara la configuración.
    var pendingFolders: [URL] = []

    // MARK: Ciclo de vida

    func start() {
        guard process == nil else { return }
        fatal = nil
        guard let engine = Self.enginePath() else {
            fatal = "No encontré el motor (Resources/engine/server.js)."
            return
        }
        let p = Process()
        // Shell de login: hereda el PATH real del usuario (node, claude, git, vercel).
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec node \"\(engine)\""]
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        input = inp.fileHandleForWriting

        let splitter = LineSplitter()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let lines = splitter.feed(d)
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach { self?.handle($0) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.stderrTail = String(((self?.stderrTail ?? "") + s).suffix(1500)) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.connected = false
                self.process = nil
                if proc.terminationStatus != 0 || self.tasks.isEmpty {
                    self.fatal = "El motor se detuvo (código \(proc.terminationStatus)). ¿Está Node instalado?\n\(self.stderrTail)"
                }
            }
        }
        do {
            try p.run()
            process = p
            connected = true
        } catch {
            fatal = "No pude iniciar el motor: \(error.localizedDescription)"
        }
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
        endActivity()
    }

    private static func enginePath() -> String? {
        if let o = ProcessInfo.processInfo.environment["CONDUCTOR_ENGINE"], FileManager.default.fileExists(atPath: o) { return o }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("engine/server.js").path
        if let b = bundled, FileManager.default.fileExists(atPath: b) { return b }
        let dev = NSString(string: "~/conductor/src/server.js").expandingTildeInPath
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    // MARK: Entrada

    private func handle(_ line: Data) {
        guard let m = try? JSONDecoder().decode(EngineMessage.self, from: line) else { return }
        switch m.t {
        case "state":
            if let t = m.tasks { tasks = t }
            if let c = m.cfg { config = c }
            if config != nil && !pendingFolders.isEmpty { let f = pendingFolders; pendingFolders = []; addProjects(f) }
            running = m.running ?? 0
            if let l = m.limits { limits = l; refreshingLimits = false }
            blockedUntil = (m.blockedUntil ?? 0) > 0 ? Date(timeIntervalSince1970: m.blockedUntil! / 1000) : nil
            updateBadgeAndSleep()
        case "toast":
            showToast(m.msg ?? "")
        case "event":
            notify(kind: m.kind ?? "", title: m.title ?? "", note: m.note ?? "")
        default: break
        }
    }

    func notice(_ s: String) { if !s.isEmpty { showToast(s) } }

    private func showToast(_ s: String) {
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.toast = nil } }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    private func updateBadgeAndSleep() {
        let n = tasks.filter(\.needsAttention).count
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
        if running > 0 && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Conductor está ejecutando tareas")
        } else if running == 0 {
            endActivity()
        }
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    private func notify(kind: String, title: String, note: String) {
        let c = UNMutableNotificationContent()
        switch kind {
        case "waiting": c.title = "Requiere tu atención"
        case "failed": c.title = "Una tarea falló"
        case "done": c.title = "Tarea completada"
        default: return
        }
        c.subtitle = title
        c.body = String(note.prefix(160))
        c.sound = kind == "done" ? nil : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Salida

    private func send(_ obj: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    func start(_ ids: [String]) { send(["cmd": "start", "ids": ids]) }
    func stop(_ ids: [String]) { send(["cmd": "stop", "ids": ids]) }
    func stopAll() { send(["cmd": "stopAll"]) }
    func approve(_ id: String) { send(["cmd": "approve", "id": id]) }
    func guide(_ id: String, _ text: String) { send(["cmd": "guide", "id": id, "text": text]) }
    func add(project: String, title: String, desc: String) { send(["cmd": "add", "project": project, "title": title, "desc": desc]) }
    func remove(_ ids: [String]) { send(["cmd": "remove", "ids": ids]) }
    func importTasks() { send(["cmd": "import"]) }
    func cleanup(_ id: String) { send(["cmd": "cleanup", "id": id]) }
    func cleanupAll() { send(["cmd": "cleanupAll"]) }
    func refreshLimits() {
        refreshingLimits = true
        send(["cmd": "refreshLimits"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.refreshingLimits = false }
    }
    func openTerminal(_ id: String) { send(["cmd": "openTerminal", "id": id]) }

    func apply(_ cfg: AppConfig) {
        guard let data = try? JSONEncoder().encode(cfg),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        config = cfg
        send(["cmd": "setConfig", "cfg": obj])
    }

    // MARK: Consultas

    func project(_ id: String) -> ProjectConfig? { config?.projects.first { $0.id == id } }
    func projectName(_ id: String) -> String { project(id)?.name ?? id }
}


/// Acumula bytes de stdout y entrega líneas completas (el handler corre en un hilo de fondo).
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ d: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}
