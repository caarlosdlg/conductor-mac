import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(EngineClient.self) private var engine
    @State private var draft: AppConfig?
    @State private var selectedProject: String?

    var body: some View {
        Group {
            if draft != nil {
                TabView {
                    general.tabItem { Label("General", systemImage: "gearshape") }
                    projects.tabItem { Label("Proyectos", systemImage: "folder") }
                    models.tabItem { Label("Modelos", systemImage: "cpu") }
                }
            } else {
                ProgressView("Conectando con el motor…")
            }
        }
        .frame(width: 640, height: 460)
        .onAppear { draft = engine.config }
        .onChange(of: engine.config) { _, new in if draft == nil { draft = new } }
        .onChange(of: draft) { _, new in if let new, new != engine.config { engine.apply(new) } }
    }

    private var general: some View {
        Form {
            if let d = Binding($draft) {
                Section("Ejecución") {
                    Stepper("Tareas en paralelo: \(d.wrappedValue.maxParallel)", value: d.maxParallel, in: 1...12)
                    VStack(alignment: .leading) {
                        Text("Rotar a sesión nueva al \(Int(d.wrappedValue.ctxLimit * 100))% del contexto")
                        Slider(value: d.ctxLimit, in: 0.2...0.9, step: 0.05)
                        Text("Tu configuración de Claude (hooks, skills, MCP) ya ocupa parte de la ventana antes de empezar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Ventana de contexto", selection: d.ctxWindow) {
                        Text("200 mil tokens").tag(200_000)
                        Text("1 millón de tokens").tag(1_000_000)
                    }
                    Stepper("Reintentos de pruebas fallidas: \(d.wrappedValue.maxFixLoops)", value: d.maxFixLoops, in: 0...5)
                }
                Section("Administrador") {
                    Toggle("Agente admin (decide bloqueos y revisa despliegues)", isOn: d.adminAgent)
                    Stepper("Intervenciones máximas por tarea: \(d.wrappedValue.maxAdminInterventions)", value: d.maxAdminInterventions, in: 0...6)
                        .disabled(!d.wrappedValue.adminAgent)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var projects: some View {
        HStack(spacing: 0) {
            List(selection: $selectedProject) {
                ForEach(draft?.projects ?? []) { Text($0.name).tag($0.id as String?) }
            }
            .frame(width: 170)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { addProject() } label: { Image(systemName: "plus") }
                    Button { removeProject() } label: { Image(systemName: "minus") }.disabled(selectedProject == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            Divider()
            if let i = draft?.projects.firstIndex(where: { $0.id == selectedProject }), let d = Binding($draft) {
                projectForm(d.projects[i])
            } else {
                ContentUnavailableView("Elige un proyecto", systemImage: "folder").frame(maxWidth: .infinity)
            }
        }
        .onAppear { selectedProject = selectedProject ?? draft?.projects.first?.id }
    }

    private func projectForm(_ p: Binding<ProjectConfig>) -> some View {
        Form {
            TextField("Nombre", text: p.name)
            HStack {
                TextField("Ruta del repo", text: p.path)
                Button("Elegir…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let u = panel.url { p.wrappedValue.path = u.path }
                }
            }
            TextField("Comando de pruebas", text: opt(p.testCmd), prompt: Text("npm run lint && npm run build"))
            TextField("Comando de despliegue", text: opt(p.deployCmd), prompt: Text("vacío = no desplegar, solo dejar la rama lista"))
            Toggle("Desplegar sin pedirme aprobación", isOn: p.autoDeploy)
                .disabled((p.wrappedValue.deployCmd ?? "").isEmpty)
            if p.wrappedValue.autoDeploy {
                Text("El agente admin revisará el diff antes de desplegar y te consultará si ve riesgo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var models: some View {
        Form {
            if draft != nil {
                Section {
                    ForEach(Phase.pipeline, id: \.rawValue) { ph in
                        TextField(ph.label, text: Binding(
                            get: { (draft?.models[ph.rawValue] ?? nil) ?? "" },
                            set: { draft?.models[ph.rawValue] = $0.isEmpty ? nil : $0 }),
                            prompt: Text("predeterminado"))
                    }
                } footer: {
                    Text("Alias (opus, sonnet, haiku) o un ID de modelo. Vacío usa el predeterminado de tu Claude Code.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func opt(_ b: Binding<String?>) -> Binding<String> {
        Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func addProject() {
        let id = "proyecto\((draft?.projects.count ?? 0) + 1)"
        draft?.projects.append(ProjectConfig(id: id, name: "Nuevo proyecto", path: NSHomeDirectory(), baseBranch: nil, testCmd: nil, deployCmd: nil, autoDeploy: false, scanPaths: nil))
        selectedProject = id
    }

    private func removeProject() {
        draft?.projects.removeAll { $0.id == selectedProject }
        selectedProject = draft?.projects.first?.id
    }
}
