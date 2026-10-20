import Foundation
import SwiftUI

enum Phase: String, CaseIterable, Codable {
    case plan, validate, build, test, deploy, done

    static let pipeline: [Phase] = [.plan, .validate, .build, .test, .deploy]

    var label: String {
        switch self {
        case .plan: "Planear"
        case .validate: "Validar"
        case .build: "Construir"
        case .test: "Probar"
        case .deploy: "Desplegar"
        case .done: "Completa"
        }
    }
    var index: Int { Phase.pipeline.firstIndex(of: self) ?? Phase.pipeline.count }
}

enum TaskStatus: String, Codable {
    case backlog, queued, running, waiting, paused, failed, done

    var label: String {
        switch self {
        case .backlog: "Pendiente"
        case .queued: "En cola"
        case .running: "Corriendo"
        case .waiting: "Requiere atención"
        case .paused: "Pausada"
        case .failed: "Falló"
        case .done: "Lista"
        }
    }
    var symbol: String {
        switch self {
        case .backlog: "circle"
        case .queued: "clock"
        case .running: "play.circle.fill"
        case .waiting: "exclamationmark.bubble.fill"
        case .paused: "pause.circle"
        case .failed: "xmark.octagon.fill"
        case .done: "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .backlog: .secondary
        case .queued: .cyan
        case .running: .green
        case .waiting: .orange
        case .paused: .gray
        case .failed: .red
        case .done: .blue
        }
    }
    /// Orden en la lista: lo que necesita al humano primero.
    var order: Int {
        switch self {
        case .waiting: 0
        case .running: 1
        case .queued: 2
        case .failed: 3
        case .paused: 4
        case .backlog: 5
        case .done: 6
        }
    }
    var isActive: Bool { self == .running || self == .queued }
}

struct Gate: Codable, Hashable {
    var type: String
    var note: String?
}

struct TaskItem: Codable, Identifiable, Hashable {
    var id: String
    var project: String
    var title: String
    var desc: String?
    var status: TaskStatus
    var phase: Phase
    var ctxPct: Int
    var sessions: Int
    var cost: Double
    var loops: Int?
    var log: [String]
    var createdAt: Double?
    var startedAt: Double?
    var finishedAt: Double?
    var branch: String?
    var workspace: String?
    var sessionId: String?
    var gate: Gate?
    var guidance: String?
    var adminInterventions: Int?

    var needsAttention: Bool { status == .waiting || status == .failed }
}

struct ProjectConfig: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var baseBranch: String?
    var testCmd: String?
    var deployCmd: String?
    var autoDeploy: Bool
    var scanPaths: [String]?
}

struct AppConfig: Codable, Equatable {
    var maxParallel: Int
    var ctxLimit: Double
    var ctxWindow: Int
    var adminAgent: Bool
    var maxAdminInterventions: Int
    var maxFixLoops: Int
    var models: [String: String?]
    var projects: [ProjectConfig]
}

struct LimitWindow: Codable, Equatable {
    var utilization: Double   // 0...1
    var resetsAt: Double      // segundos epoch
    var resetDate: Date { Date(timeIntervalSince1970: resetsAt) }
}

struct UsageLimits: Codable, Equatable {
    var five_hour: LimitWindow?
    var seven_day: LimitWindow?
    var status: String?
    var updatedAt: Double?    // ms epoch
}

/// Mensajes que llegan del motor.
struct EngineMessage: Decodable {
    var t: String
    var tasks: [TaskItem]?
    var cfg: AppConfig?
    var running: Int?
    var kind: String?
    var taskId: String?
    var title: String?
    var note: String?
    var msg: String?
    var limits: UsageLimits?
    var blockedUntil: Double?
}
