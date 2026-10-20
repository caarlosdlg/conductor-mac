import SwiftUI

/// Límites del plan de Claude: sesión de 5 h, semana y lo que te queda, con barras.
/// Los porcentajes vienen de Anthropic (no exponen conteo absoluto de tokens), así que
/// «lo que te queda» se expresa como porcentaje de la ventana más restrictiva.
struct UsagePanel: View {
    @Environment(EngineClient.self) private var engine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 11) {
                header(now: ctx.date)
                if let l = engine.limits, l.five_hour != nil || l.seven_day != nil {
                    if let w = l.five_hour {
                        UsageBar(title: "Sesión · 5 horas", symbol: "clock", used: w.utilization,
                                 detail: "reinicia en \(countdown(to: w.resetDate, now: ctx.date))")
                    }
                    if let w = l.seven_day {
                        UsageBar(title: "Semana · 7 días", symbol: "calendar", used: w.utilization,
                                 detail: "reinicia \(w.resetDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    }
                    if let rem = remaining(l) {
                        UsageBar(title: "Te queda ahora", symbol: "gauge.with.dots.needle.33percent", used: 1 - rem.fraction, invert: true,
                                 detail: rem.note)
                    }
                    if let until = engine.blockedUntil {
                        Label("Límite alcanzado: Conductor reanuda a las \(until.formatted(date: .omitted, time: .shortened))",
                              systemImage: "hourglass").font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    Text(engine.refreshingLimits ? "Consultando límites…" : "Sin datos de límites todavía").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack {
            Text("USO DEL PLAN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let ms = engine.limits?.updatedAt {
                Text(ago(Date(timeIntervalSince1970: ms / 1000), now: now)).font(.caption2).foregroundStyle(.tertiary)
            }
            Button { engine.refreshLimits() } label: {
                Image(systemName: "arrow.clockwise").font(.caption2)
                    .rotationEffect(.degrees(engine.refreshingLimits ? 360 : 0))
                    .animation(engine.refreshingLimits ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: engine.refreshingLimits)
            }
            .buttonStyle(.borderless).help("Actualizar (consulta mínima, ~$0.03)").disabled(engine.refreshingLimits)
        }
    }

    /// Lo que queda de la ventana más restrictiva.
    private func remaining(_ l: UsageLimits) -> (fraction: Double, note: String)? {
        let five = l.five_hour.map { (1 - $0.utilization, "limita la sesión de 5 h") }
        let week = l.seven_day.map { (1 - $0.utilization, "limita la semana") }
        guard let m = [five, week].compactMap({ $0 }).min(by: { $0.0 < $1.0 }) else { return nil }
        return (max(0, m.0), m.1)
    }

    private func countdown(to d: Date, now: Date) -> String {
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return "ahora" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    private func ago(_ d: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        return m < 1 ? "ahora" : m < 60 ? "hace \(m) min" : "hace \(m / 60) h"
    }
}

struct UsageBar: View {
    let title: String
    let symbol: String
    let used: Double          // 0...1
    var invert = false        // true: la barra muestra lo que queda (más lleno = mejor)
    let detail: String

    private var color: Color {
        let danger = invert ? 1 - used : used   // fracción usada real
        return danger >= 0.9 ? .red : danger >= 0.7 ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol).font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
                Spacer()
                Text("\(Int((invert ? 1 - used : used) * 100))%\(invert ? " libre" : " usado")")
                    .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * min(1, max(0, invert ? 1 - used : used))))
                }
            }
            .frame(height: 7)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
