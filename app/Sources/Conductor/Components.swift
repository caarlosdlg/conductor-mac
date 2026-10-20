import SwiftUI

/// Cinco segmentos: planear · validar · construir · probar · desplegar.
struct PhaseStepper: View {
    let task: TaskItem
    var labels = false

    var body: some View {
        let current = task.phase.index
        HStack(spacing: 4) {
            ForEach(Array(Phase.pipeline.enumerated()), id: \.offset) { i, p in
                VStack(spacing: 3) {
                    Capsule()
                        .fill(color(i, current))
                        .frame(height: 5)
                        .overlay(alignment: .leading) {
                            if i == current && task.status == .running {
                                Capsule().fill(.white.opacity(0.5)).frame(width: 10, height: 5)
                                    .phaseAnimator([0.0, 1.0]) { c, v in c.offset(x: v * 20) } animation: { _ in .easeInOut(duration: 1) }
                                    .clipShape(Capsule())
                            }
                        }
                    if labels {
                        Text(p.label).font(.caption2).foregroundStyle(i == current ? .primary : .secondary)
                    }
                }
            }
        }
    }

    private func color(_ i: Int, _ current: Int) -> Color {
        if i < current { return .accentColor }
        if i == current { return task.phase == .done ? .accentColor : task.status.color }
        return Color.secondary.opacity(0.25)
    }
}

/// Medidor de contexto; se pone rojo al llegar al límite de rotación.
struct ContextGauge: View {
    let pct: Int
    let limit: Double

    var body: some View {
        let lim = limit * 100
        let color: Color = Double(pct) >= lim ? .red : Double(pct) >= lim * 0.75 ? .orange : .green
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: g.size.width * min(1, Double(pct) / 100))
                    Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5).offset(x: g.size.width * limit)
                }
            }
            .frame(width: 54, height: 6)
            Text("\(pct)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .help("Contexto usado · la marca es el límite de rotación (\(Int(lim))%)")
    }
}

struct StatusChip: View {
    let status: TaskStatus
    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.color.opacity(0.15), in: Capsule())
            .foregroundStyle(status.color)
    }
}

func formatDuration(_ ms: Double) -> String {
    let s = Int(ms / 1000)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}


/// Color estable por proyecto, para reconocerlo de un vistazo.
func projectColor(_ id: String) -> Color {
    let palette: [Color] = [.indigo, .teal, .pink, .orange, .mint, .purple, .cyan, .brown]
    let h = id.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    return palette[abs(h) % palette.count]
}

struct StatPill: View {
    let value: String
    let label: String
    let symbol: String
    let color: Color
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.callout).foregroundStyle(color)
                Text(value).font(.title3.weight(.semibold).monospacedDigit())
            }
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? color.opacity(0.14) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlight ? color.opacity(0.5) : .clear))
    }
}

struct ProjectTag: View {
    let name: String
    let id: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(projectColor(id)).frame(width: 7, height: 7)
            Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .lineLimit(1).fixedSize()
    }
}
