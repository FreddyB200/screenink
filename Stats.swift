// Ventana de estadísticas del pomodoro: hoy, semana, racha, 14 días y temas.
import Cocoa

final class StatsView: NSView {
    override var isFlipped: Bool { true }
    var records: [SessionRecord]?      // solo para --render-docs; nil = historial real

    private let dayFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "es"); f.dateFormat = "EEEEE"; return f }()
    private let numFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d"; return f }()

    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
              color: NSColor = .white, align: NSTextAlignment = .left, width: CGFloat = 300) {
        let ps = NSMutableParagraphStyle(); ps.alignment = align; ps.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: ps]
        (s as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size * 1.5), withAttributes: a)
    }

    func dur(_ m: Double) -> String {
        let t = Int(m.rounded())
        return t >= 60 ? "\(t / 60)h \(String(format: "%02d", t % 60))m" : "\(t) min"
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill(); bounds.fill()
        let gray = NSColor(white: 1, alpha: 0.55)
        let accent = Phase.focus.color
        let recs = records ?? History.shared.records
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ off: Int) -> Date { cal.date(byAdding: .day, value: -off, to: today)! }

        var minutes: [Date: Double] = [:], sessions: [Date: Int] = [:]
        for r in recs {
            let d = cal.startOfDay(for: r.end)
            minutes[d, default: 0] += r.minutes
            if r.completed { sessions[d, default: 0] += 1 }
        }
        let weekMin = (0..<7).reduce(0.0) { $0 + (minutes[day($1)] ?? 0) }
        let weekN = (0..<7).reduce(0) { $0 + (sessions[day($1)] ?? 0) }
        var streak = 0
        var off = (sessions[today] ?? 0) > 0 ? 0 : 1      // si hoy aún no hay sesión, la racha de ayer sigue viva
        while (sessions[day(off)] ?? 0) > 0 { streak += 1; off += 1 }
        let totalMin = recs.reduce(0.0) { $0 + $1.minutes }
        let totalN = recs.filter { $0.completed }.count

        text("Estadísticas de enfoque", 24, 18, size: 20, weight: .bold, width: 400)

        // Tarjetas
        let cards: [(String, String, String)] = [
            ("HOY", dur(minutes[today] ?? 0), "\(sessions[today] ?? 0) sesiones"),
            ("7 DÍAS", dur(weekMin), "\(weekN) sesiones"),
            ("RACHA", "\(streak) \(streak == 1 ? "día" : "días")", "con ≥1 sesión"),
            ("TOTAL", dur(totalMin), "\(totalN) sesiones"),
        ]
        let cw = (bounds.width - 48 - 36) / 4
        for (i, c) in cards.enumerated() {
            let x = 24 + CGFloat(i) * (cw + 12)
            NSColor(white: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 58, width: cw, height: 80), xRadius: 12, yRadius: 12).fill()
            text(c.0, x + 12, 68, size: 10, weight: .heavy, color: gray, width: cw - 24)
            text(c.1, x + 12, 86, size: 20, weight: .bold, width: cw - 24)
            text(c.2, x + 12, 114, size: 11, color: gray, width: cw - 24)
        }

        if recs.isEmpty {
            text("Aún no hay sesiones. Inicia un foco con ⌃⌥S y aquí verás tu progreso.",
                 24, 200, size: 14, color: gray, width: bounds.width - 48)
            return
        }

        // Barras: últimos 14 días
        text("MINUTOS DE FOCO · ÚLTIMOS 14 DÍAS", 24, 162, size: 10, weight: .heavy, color: gray, width: 400)
        let vals = (0..<14).reversed().map { (d: day($0), v: minutes[day($0)] ?? 0) }
        let maxV = max(30, vals.map { $0.v }.max() ?? 0)
        let areaX: CGFloat = 24, areaW = bounds.width - 48, baseY: CGFloat = 330, maxH: CGFloat = 120
        let slot = areaW / 14
        for (i, e) in vals.enumerated() {
            let x = areaX + CGFloat(i) * slot + (slot - 22) / 2
            let h = max(e.v > 0 ? 3 : 1, CGFloat(e.v / maxV) * maxH)
            let isToday = e.d == today
            (isToday ? accent : accent.withAlphaComponent(0.45)).setFill()
            if e.v == 0 { NSColor(white: 1, alpha: 0.12).setFill() }
            NSBezierPath(roundedRect: NSRect(x: x, y: baseY - h, width: 22, height: h), xRadius: 4, yRadius: 4).fill()
            if e.v > 0 { text("\(Int(e.v.rounded()))", x - 8, baseY - h - 16, size: 10, color: gray, align: .center, width: 38) }
            text(dayFmt.string(from: e.d).uppercased(), x - 8, baseY + 6, size: 10, weight: isToday ? .bold : .regular,
                 color: isToday ? .white : gray, align: .center, width: 38)
            text(numFmt.string(from: e.d), x - 8, baseY + 19, size: 10, color: gray, align: .center, width: 38)
        }

        // Temas (30 días)
        text("TEMAS · ÚLTIMOS 30 DÍAS", 24, 380, size: 10, weight: .heavy, color: gray, width: 400)
        let since = day(29)
        var byTag: [String: Double] = [:]
        for r in recs where r.end >= since { byTag[r.tag.isEmpty ? "Sin tema" : r.tag, default: 0] += r.minutes }
        let top = byTag.sorted { $0.value > $1.value }.prefix(5)
        let topMax = top.first?.value ?? 1
        for (i, t) in top.enumerated() {
            let y = 404 + CGFloat(i) * 26
            text(t.key, 24, y, size: 13, width: 150)
            let bw = (bounds.width - 24 - 190 - 90) * CGFloat(t.value / topMax)
            NSColor(white: 1, alpha: 0.08).setFill()
            NSBezierPath(roundedRect: NSRect(x: 180, y: y + 2, width: bounds.width - 24 - 190 - 90, height: 14), xRadius: 5, yRadius: 5).fill()
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 180, y: y + 2, width: max(6, bw), height: 14), xRadius: 5, yRadius: 5).fill()
            text(dur(t.value), bounds.width - 24 - 80, y, size: 12, color: gray, align: .right, width: 80)
        }
    }
}

final class StatsWindow {
    static let shared = StatsWindow()
    private var window: NSWindow?
    private var view: StatsView?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Pomodoro — Estadísticas"
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]
            let v = StatsView(frame: NSRect(x: 0, y: 0, width: 580, height: 560))
            w.contentView = v
            w.center()
            window = w; view = v
        }
        view?.needsDisplay = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func refresh() { if window?.isVisible == true { view?.needsDisplay = true } }
}
