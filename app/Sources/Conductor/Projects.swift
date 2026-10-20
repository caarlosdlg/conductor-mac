import Foundation
import AppKit

/// Deduce la configuración de un proyecto a partir de su carpeta.
enum ProjectDetector {
    struct Result {
        var project: ProjectConfig
        var isGitRoot: Bool
        var isInsideGit: Bool
        var gitDir: String?
    }

    static func detect(_ url: URL, existingIDs: Set<String>) -> Result {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let name = url.lastPathComponent
        var id = slug(name)
        var n = 2
        while existingIDs.contains(id) { id = "\(slug(name))-\(n)"; n += 1 }

        let top = git(path, ["rev-parse", "--show-toplevel"])
        let isGitRoot = top.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == path } ?? false
        let project = ProjectConfig(id: id, name: name, path: path, baseBranch: nil,
                                    testCmd: testCommand(path), deployCmd: nil, autoDeploy: false, scanPaths: nil)
        let gitDir = git(path, ["rev-parse", "--absolute-git-dir"])
        return Result(project: project, isGitRoot: isGitRoot, isInsideGit: top != nil, gitDir: gitDir)
    }

    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let out = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(out).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "proyecto" : joined
    }

    /// Lint + tests + build cuando existen los scripts; si no, el comando estándar del ecosistema.
    static func testCommand(_ path: String) -> String? {
        let fm = FileManager.default
        func exists(_ f: String) -> Bool { fm.fileExists(atPath: "\(path)/\(f)") }
        if let data = fm.contents(atPath: "\(path)/package.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = obj["scripts"] as? [String: Any] {
            var parts: [String] = []
            if scripts["lint"] != nil { parts.append("npm run lint") }
            if scripts["typecheck"] != nil { parts.append("npm run typecheck") }
            if scripts["test"] != nil { parts.append("npm test") }
            if scripts["build"] != nil { parts.append("npm run build") }
            return parts.isEmpty ? nil : parts.joined(separator: " && ")
        }
        if exists("Package.swift") { return "swift build && swift test" }
        if exists("Cargo.toml") { return "cargo test" }
        if exists("go.mod") { return "go test ./..." }
        if exists("pyproject.toml") || exists("pytest.ini") { return "pytest" }
        return nil
    }

    private static func git(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}

enum FinderPicker {
    /// Selector de carpetas del Finder (acepta varias).
    @MainActor static func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Añadir proyectos"
        panel.message = "Elige la carpeta de cada proyecto (la raíz del repositorio)."
        panel.prompt = "Añadir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        return panel.runModal() == .OK ? panel.urls : []
    }
}

extension EngineClient {
    /// Añade carpetas como proyectos, importa sus tareas y avisa de lo relevante.
    func addProjects(_ urls: [URL]) {
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !dirs.isEmpty else { notice("Arrastra carpetas, no archivos."); return }
        guard var cfg = config else { pendingFolders.append(contentsOf: dirs); return }

        var added: [String] = []
        var warnings: [String] = []
        for url in dirs {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if cfg.projects.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path }) {
                warnings.append("«\(url.lastPathComponent)» ya estaba añadido")
                continue
            }
            let r = ProjectDetector.detect(url, existingIDs: Set(cfg.projects.map(\.id)))
            cfg.projects.append(r.project)
            added.append(r.project.name)
            let heads = (r.gitDir ?? path + "/.git") + "/refs/heads"
            if r.isInsideGit && !FileManager.default.isWritableFile(atPath: heads) {
                warnings.append("«\(r.project.name)» tiene su .git bloqueado (dueño root): corre sudo chown -R $(whoami) \"\(path)\"")
            }
            if !r.isInsideGit {
                warnings.append("«\(r.project.name)» no es un repo git: sólo correrá una tarea a la vez ahí")
            } else if !r.isGitRoot {
                warnings.append("«\(r.project.name)» es una subcarpeta de un repo: elige la raíz del repo para aislar tareas")
            }
        }
        if !added.isEmpty {
            apply(cfg)
            importTasks()
        }
        let head = added.isEmpty ? "" : "Añadido: \(added.joined(separator: ", ")). Revisa pruebas y despliegue en Ajustes. "
        notice(head + warnings.joined(separator: " · "))
    }

    func removeProject(_ id: String) {
        guard var cfg = config else { return }
        let mine = tasks.filter { $0.project == id }
        if mine.contains(where: { $0.status == .running || $0.status == .queued }) {
            notice("Detén las tareas de ese proyecto antes de quitarlo.")
            return
        }
        remove(mine.map(\.id))
        cfg.projects.removeAll { $0.id == id }
        apply(cfg)
        notice("Proyecto quitado (el repositorio no se toca).")
    }
}
