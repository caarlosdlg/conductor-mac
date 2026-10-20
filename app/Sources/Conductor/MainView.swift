import SwiftUI

enum SidebarItem: Hashable {
    case all, attention
    case project(String)
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "Todas", open = "Pendientes", active = "Activas", done = "Listas"
    var id: String { rawValue }
}

struct MainView: View {
    @Environment(EngineClient.self) private var engine
    @State private var sidebar: SidebarItem? = .all
    @State private var selection = Set<String>()
    @State private var filter: StatusFilter = .all
    @State private var search = ""
    @State private var showNew = false
    @State private var confirmDelete = false
    @State private var dropTargeted = false

    private var limit: Double { engine.config?.ctxLimit ?? 0.4 }

    private var visible: [TaskItem] {
        engine.tasks.filter { t in
            switch sidebar {
            case .project(let id): if t.project != id { return false }
            case .attention: if !t.needsAttention { return false }
            default: break
            }
            switch filter {
            case .all: break
            case .open: if t.status == .done { return false }
            case .active: if !(t.status.isActive || t.status == .waiting) { return false }
            case .done: if t.status != .done { return false }
            }
            return search.isEmpty || t.title.localizedCaseInsensitiveContains(search)
        }
        .sorted { ($0.status.order, $0.project, $0.createdAt ?? 0) < ($1.status.order, $1.project, $1.createdAt ?? 0) }
    }

    private struct Group: Identifiable { let id: String; let title: String; let symbol: String; let tasks: [TaskItem] }

    private var groups: [Group] {
        let v = visible
        let defs: [(String, String, String, (TaskItem) -> Bool)] = [
            ("attention", "Requieren atención", "exclamationmark.bubble", { $0.needsAttention }),
            ("active", "En ejecución", "bolt.fill", { $0.status.isActive }),
            ("paused", "Pausadas", "pause.circle", { $0.status == .paused }),
            ("backlog", "Pendientes", "tray", { $0.status == .backlog }),
            ("done", "Listas", "checkmark.circle", { $0.status == .done }),
        ]
        return defs.compactMap { id, title, sym, f in
            let ts = v.filter(f)
            return ts.isEmpty ? nil : Group(id: id, title: title, symbol: sym, tasks: ts)
        }
    }

    private var selectedTasks: [TaskItem] { engine.tasks.filter { selection.contains($0.id) } }
    private var startable: [TaskItem] { selectedTasks.filter { ![.running, .queued, .done].contains($0.status) } }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $sidebar)
        } content: {
            VStack(spacing: 0) {
                if (engine.config?.projects ?? []).isEmpty {
                    ContentUnavailableView {
                        Label("Añade tu primer proyecto", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Arrastra la carpeta de un repositorio a esta ventana, o elígela en el Finder.")
                    } actions: {
                        Button("Elegir carpeta…") { engine.addProjects(FinderPicker.chooseFolders()) }.buttonStyle(.borderedProminent)
                    }
                } else if engine.tasks.isEmpty {
                    ContentUnavailableView("Sin tareas", systemImage: "tray",
                        description: Text("Crea una con ⌘N o impórtalas de TASKS.md con ⇧⌘I."))
                } else {
                    SummaryBar()
                    List(selection: $selection) {
                        ForEach(groups) { g in
                            Section {
                                ForEach(g.tasks) { t in
                                    TaskRow(task: t, projectName: engine.projectName(t.project), ctxLimit: limit)
                                        .tag(t.id)
                                        .contextMenu { rowMenu(t) }
                                }
                            } header: {
                                Label("\(g.title) · \(g.tasks.count)", systemImage: g.symbol)
                                    .font(.caption.weight(.semibold)).textCase(nil)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                if let toast = engine.toast {
                    Label(toast, systemImage: "info.circle.fill")
                        .font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.quaternary))
                        .shadow(radius: 6, y: 2)
                        .padding(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: engine.toast)
            .searchable(text: $search, prompt: "Buscar tarea")
            .navigationSplitViewColumnWidth(min: 420, ideal: 560, max: 760)
        } detail: {
            if selectedTasks.count == 1, let t = selectedTasks.first {
                DetailView(taskID: t.id)
            } else if selectedTasks.count > 1 {
                ContentUnavailableView("\(selectedTasks.count) tareas seleccionadas", systemImage: "checklist",
                    description: Text("Pulsa Iniciar para lanzarlas todas en paralelo (hasta \(engine.config?.maxParallel ?? 3) a la vez)."))
            } else {
                ContentUnavailableView("Selecciona una tarea", systemImage: "sidebar.right")
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showNew) { NewTaskSheet() }
        .confirmationDialog("¿Borrar \(selectedTasks.count) tarea(s)?", isPresented: $confirmDelete) {
            Button("Borrar", role: .destructive) { engine.remove(Array(selection)); selection = [] }
        }
        .overlay {
            if let f = engine.fatal {
                ContentUnavailableView {
                    Label("Motor detenido", systemImage: "exclamationmark.triangle")
                } description: { Text(f) } actions: {
                    Button("Reintentar") { engine.start() }
                }
                .background(.regularMaterial)
            }
        }
        .onChange(of: sidebar) { _, _ in selection = [] }
        .dropDestination(for: URL.self) { urls, _ in
            engine.addProjects(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Label("Suelta carpetas para añadirlas como proyectos", systemImage: "folder.badge.plus").font(.title3.bold()))
                    .padding(8).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ t: TaskItem) -> some View {
        Button("Iniciar") { engine.start([t.id]) }.disabled([.running, .queued, .done].contains(t.status))
        Button("Detener") { engine.stop([t.id]) }.disabled(!t.status.isActive)
        Divider()
        Button("Abrir en Terminal") { engine.openTerminal(t.id) }
        Button("Borrar", role: .destructive) { engine.remove([t.id]) }.disabled(t.status == .running)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Filtro", selection: $filter) {
                    ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filtrar por estado")

            Button { selection = Set(visible.filter { $0.status != .done }.map(\.id)) } label: {
                Label("Seleccionar todas", systemImage: "checklist.checked")
            }
            .help("Seleccionar todas las visibles no terminadas")

            Button { engine.start(startable.map(\.id)); selection = [] } label: {
                Label(startable.isEmpty ? "Iniciar" : "Iniciar (\(startable.count))", systemImage: "play.fill")
            }
            .disabled(startable.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Iniciar las tareas seleccionadas")

            Button { engine.stop(selectedTasks.map(\.id)) } label: { Label("Detener", systemImage: "pause.fill") }
                .disabled(!selectedTasks.contains { $0.status.isActive })

            Button { engine.stopAll() } label: { Label("Detener todo", systemImage: "stop.fill") }
                .disabled(engine.running == 0)
                .help("Detener todas las tareas en ejecución")

            Divider()

            Button { showNew = true } label: { Label("Nueva tarea", systemImage: "plus") }
                .keyboardShortcut("n")
            Button { engine.addProjects(FinderPicker.chooseFolders()) } label: { Label("Añadir proyecto", systemImage: "folder.badge.plus") }
                .help("Añadir proyectos desde el Finder (también puedes arrastrar carpetas a la ventana)")
            Menu {
                Button("Añadir proyecto…") { engine.addProjects(FinderPicker.chooseFolders()) }
                Button("Importar de TASKS.md y orchestrator") { engine.importTasks() }
                Button("Limpiar worktrees de tareas listas") { engine.cleanupAll() }
                Divider()
                Button("Borrar selección…", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
            } label: { Label("Más", systemImage: "ellipsis.circle") }
        }
    }
}

struct Sidebar: View {
    @Environment(EngineClient.self) private var engine
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                row("Todas", "tray.full", engine.tasks.filter { $0.status != .done }.count, .all)
                row("Requieren atención", "exclamationmark.bubble", engine.tasks.filter(\.needsAttention).count, .attention, tint: .orange)
            }
            Section {
                ForEach(engine.config?.projects ?? []) { p in
                    row(p.name, "folder.fill", engine.tasks.filter { $0.project == p.id && $0.status != .done }.count, .project(p.id), tint: projectColor(p.id))
                        .contextMenu {
                            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                            Button("Quitar proyecto", role: .destructive) { engine.removeProject(p.id) }
                        }
                }
                if (engine.config?.projects ?? []).isEmpty {
                    Text("Arrastra una carpeta aquí").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Proyectos")
                    Spacer()
                    Button { engine.addProjects(FinderPicker.chooseFolders()) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Añadir proyecto desde el Finder")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                UsagePanel()
                Divider()
                HStack {
                    Image(systemName: "bolt.fill").foregroundStyle(engine.running > 0 ? .green : .secondary).font(.caption)
                    Text("\(engine.running) / \(engine.config?.maxParallel ?? 3) en ejecución").font(.caption)
                    Spacer()
                    if let c = engine.config {
                        Stepper("", value: Binding(
                            get: { c.maxParallel },
                            set: { var n = c; n.maxParallel = $0; engine.apply(n) }), in: 1...12)
                            .labelsHidden().controlSize(.small)
                            .help("Tareas en paralelo")
                    }
                }
                Text("\(engine.tasks.reduce(0) { $0 + $1.cost }, format: .currency(code: "USD")) gastados por Conductor")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private func row(_ title: String, _ icon: String, _ count: Int, _ item: SidebarItem, tint: Color = .accentColor) -> some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            .badge(count)
            .tag(item)
    }
}


/// Resumen del panel: lo que corre, lo que te necesita y lo que ya terminó.
struct SummaryBar: View {
    @Environment(EngineClient.self) private var engine

    var body: some View {
        let t = engine.tasks
        let attention = t.filter(\.needsAttention).count
        HStack(spacing: 8) {
            StatPill(value: "\(engine.running)/\(engine.config?.maxParallel ?? 3)", label: "En ejecución", symbol: "bolt.fill", color: .green, highlight: engine.running > 0)
            StatPill(value: "\(attention)", label: "Te necesitan", symbol: "exclamationmark.bubble.fill", color: .orange, highlight: attention > 0)
            StatPill(value: "\(t.filter { $0.status == .backlog || $0.status == .paused }.count)", label: "Pendientes", symbol: "tray.fill", color: .secondary)
            StatPill(value: "\(t.filter { $0.status == .done }.count)", label: "Listas", symbol: "checkmark.circle.fill", color: .blue)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
