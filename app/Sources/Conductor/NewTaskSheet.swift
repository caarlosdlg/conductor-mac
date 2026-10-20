import SwiftUI

struct NewTaskSheet: View {
    @Environment(EngineClient.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var title = ""
    @State private var desc = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nueva tarea").font(.title2.bold())
            Picker("Proyecto", selection: $project) {
                ForEach(engine.config?.projects ?? []) { Text($0.name).tag($0.id) }
            }
            TextField("Qué hay que lograr", text: $title)
            VStack(alignment: .leading, spacing: 4) {
                Text("Detalle (opcional)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $desc)
                    .font(.body)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Crear") {
                    engine.add(project: project, title: title.trimmingCharacters(in: .whitespacesAndNewlines), desc: desc)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || project.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { project = engine.config?.projects.first?.id ?? "" }
    }
}
