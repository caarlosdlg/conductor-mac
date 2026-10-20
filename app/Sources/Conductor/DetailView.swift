import SwiftUI

struct DetailView: View {
    @Environment(EngineClient.self) private var engine
    let taskID: String
    @State private var guidance = ""
    @State private var follow = true
    @State private var assumptions: String?

    private var task: TaskItem? { engine.tasks.first { $0.id == taskID } }

    var body: some View {
        if let t = task {
            VStack(alignment: .leading, spacing: 14) {
                header(t)
                PhaseStepper(task: t, labels: true)
                metrics(t)
                if let g = t.gate, t.needsAttention { gateCard(t, g) }
                if let g = t.guidance, !g.isEmpty {
                    Label(g, systemImage: "arrow.turn.down.right").font(.callout).foregroundStyle(.cyan).lineLimit(3)
                }
                if let a = assumptions { assumptionsCard(a) }
                logView(t)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(t.title)
            .task(id: "\(t.id)-\(t.phase.rawValue)-\(t.status.rawValue)") { assumptions = loadAssumptions(t.id) }
        } else {
            ContentUnavailableView("Tarea no encontrada", systemImage: "questionmark.folder")
        }
    }

    private func header(_ t: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(t.title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                StatusChip(status: t.status)
            }
            if let d = t.desc, !d.isEmpty { Text(d).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack(spacing: 14) {
                Label(engine.projectName(t.project), systemImage: "folder")
                if let b = t.branch { Label(b, systemImage: "arrow.triangle.branch") }
                Text(t.id).font(.caption.monospaced())
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                if [.running, .queued].contains(t.status) {
                    Button { engine.stop([t.id]) } label: { Label("Detener", systemImage: "pause.fill") }
                } else if t.status != .done {
                    Button { engine.start([t.id]) } label: { Label(t.status == .failed ? "Reintentar" : "Iniciar", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                }
                Menu {
                    Button("Abrir plan (PLAN.md)") { NSWorkspace.shared.open(URL(fileURLWithPath: taskDir(t.id) + "/PLAN.md")) }
                        .disabled(!FileManager.default.fileExists(atPath: taskDir(t.id) + "/PLAN.md"))
                    Button("Mostrar carpeta de la tarea") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: taskDir(t.id))]) }
                    if let w = t.workspace {
                        Button("Mostrar código (worktree)") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w)]) }
                    }
                } label: { Label("Archivos", systemImage: "doc.text") }
                Button { engine.openTerminal(t.id) } label: { Label("Abrir en Terminal", systemImage: "terminal") }
                    .help("Abre esta sesión de Claude en Terminal (claude --resume) para intervenir a mano")
                if t.workspace != nil && t.workspace != engine.project(t.project)?.path && t.status != .running {
                    Button { engine.cleanup(t.id) } label: { Label("Limpiar worktree", systemImage: "trash.slash") }
                }
            }
        }
    }

    private func metrics(_ t: TaskItem) -> some View {
        HStack(spacing: 24) {
            metric("Contexto") { ContextGauge(pct: t.ctxPct, limit: engine.config?.ctxLimit ?? 0.4) }
            metric("Sesiones") { Text("\(t.sessions)").font(.body.monospacedDigit()) }
            metric("Costo") { Text(t.cost, format: .currency(code: "USD")).font(.body.monospacedDigit()) }
            if let s = t.startedAt {
                metric("Tiempo") { Text(formatDuration((t.finishedAt ?? Date().timeIntervalSince1970 * 1000) - s)).font(.body.monospacedDigit()) }
            }
            if let n = t.adminInterventions, n > 0 { metric("Admin") { Text("\(n)× intervino").font(.body) } }
        }
    }

    private func metric<V: View>(_ label: String, @ViewBuilder _ v: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            v()
        }
    }

    private func gateCard(_ t: TaskItem, _ g: Gate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title(g), systemImage: t.status.symbol).font(.headline).foregroundStyle(t.status.color)
            Text(g.note ?? "").font(.callout).textSelection(.enabled)
            if g.type == "deploy" {
                Button("Aprobar despliegue") { engine.approve(t.id) }.buttonStyle(.borderedProminent)
            } else {
                HStack {
                    TextField("Indicación para el agente…", text: $guidance, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .onSubmit(send)
                    Button("Enviar y reintentar", action: send).buttonStyle(.borderedProminent)
                        .disabled(guidance.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Reintentar") { t.status == .waiting ? engine.approve(t.id) : engine.start([t.id]) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.status.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.status.color.opacity(0.4)))
    }

    private func title(_ g: Gate) -> String {
        switch g.type {
        case "deploy": "Aprobación de despliegue"
        case "blocked": "El agente necesita una decisión"
        default: "La tarea falló"
        }
    }

    private func taskDir(_ id: String) -> String { NSHomeDirectory() + "/.conductor/tasks/" + id }

    /// Decisiones que el admin tomó por ti, registradas en «## Supuestos» del plan.
    private func loadAssumptions(_ id: String) -> String? {
        guard let text = try? String(contentsOfFile: taskDir(id) + "/PLAN.md", encoding: .utf8),
              let r = text.range(of: "## Supuestos") else { return nil }
        let rest = text[r.upperBound...]
        let body = rest.components(separatedBy: "\n## ").first ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(1200))
    }

    private func assumptionsCard(_ text: String) -> some View {
        DisclosureGroup {
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            Label("Supuestos tomados por el admin — revísalos", systemImage: "lightbulb").font(.callout.weight(.medium)).foregroundStyle(.purple)
        }
        .padding(10)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func send() {
        let text = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        engine.guide(taskID, text)
        guidance = ""
    }

    private func logView(_ t: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Actividad").font(.headline)
                Spacer()
                Toggle("Seguir", isOn: $follow).toggleStyle(.switch).controlSize(.mini)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(t.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: t.log.count) { _, n in
                    if follow, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
    }

    private func color(_ l: String) -> Color {
        if l.hasPrefix("⚙") { return .secondary }
        if l.hasPrefix("✓") || l.hasPrefix("★") { return .green }
        if l.hasPrefix("✗") { return .red }
        if l.hasPrefix("⏸") || l.hasPrefix("↻") || l.hasPrefix("↺") || l.hasPrefix("⚑") { return .orange }
        if l.hasPrefix("⚖") { return .purple }
        return .primary
    }
}
