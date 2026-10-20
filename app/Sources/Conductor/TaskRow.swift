import SwiftUI

struct TaskRow: View {
    let task: TaskItem
    let projectName: String
    let ctxLimit: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.status.symbol)
                .foregroundStyle(task.status.color)
                .font(.title3)
                .frame(width: 24)
                .padding(.top, 1)
                .symbolEffect(.pulse, isActive: task.status == .running)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).lineLimit(2).font(.body.weight(.medium))
                HStack(spacing: 10) {
                    ProjectTag(name: projectName, id: task.project)
                    if task.status != .backlog {
                        Text(task.phase.label).font(.caption).foregroundStyle(task.status == .running ? .primary : .secondary)
                    }
                    PhaseStepper(task: task).frame(width: 84)
                    if task.status != .backlog && task.status != .done {
                        ContextGauge(pct: task.ctxPct, limit: ctxLimit)
                    }
                    Spacer(minLength: 0)
                    if task.cost > 0 {
                        Text(task.cost, format: .currency(code: "USD")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if task.needsAttention, let note = task.gate?.note {
                    Label(note, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(task.status.color).lineLimit(2)
                } else if task.status == .running, let last = task.log.last(where: { !$0.hasPrefix("⚖") }) {
                    Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 5)
    }
}
