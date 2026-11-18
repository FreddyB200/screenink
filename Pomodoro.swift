// Pomodoro flotante: siempre encima, no roba el foco, recuerda su estado tras reiniciar.
import Cocoa

enum Phase: String {
    case focus, short, long
    var title: String {
        switch self { case .focus: return "FOCO"; case .short: return "DESCANSO"; case .long: return "DESCANSO LARGO" }
    }
    var color: NSColor {
        switch self {
        case .focus: return NSColor(red: 0.96, green: 0.36, blue: 0.32, alpha: 1)
        case .short: return NSColor(red: 0.30, green: 0.80, blue: 0.50, alpha: 1)
        case .long: return NSColor(red: 0.25, green: 0.72, blue: 0.90, alpha: 1)
        }
    }
}

// MARK: - Historial (JSON en ~/Library/Application Support/ScreenInk/history.json)

struct SessionRecord: Codable {
    var end: Date
    var minutes: Double
    var completed: Bool      // false = interrumpida (reiniciada o saltada antes de terminar)
    var tag: String
}

final class History {
    static let shared = History()
    var records: [SessionRecord] = []
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenInk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let r = try? dec.decode([SessionRecord].self, from: data) { records = r }
    }
    func add(_ r: SessionRecord) {
        records.append(r)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(records) { try? data.write(to: url, options: .atomic) }
    }
}

final class Pomodoro {
    static let shared = Pomodoro()
    var tag = ""                      // tema de la sesión actual (para las estadísticas)
    private let d = UserDefaults.standard

    var focusMin = 25, shortMin = 5, longMin = 15, cycle = 4
    var autoStart = true
    var phase: Phase = .focus
    var completed = 0                 // sesiones de foco completadas en el ciclo actual
    var running = false
    var endDate = Date()
    var remaining: TimeInterval = 25 * 60
    var flashUntil: CFTimeInterval = 0
    var visible = true
    var compact = false
    var musicMuted = false            // silencia la música de foco solo durante esta sesión de la app (no se guarda)

    func duration(_ p: Phase) -> TimeInterval {
        switch p { case .focus: return Double(focusMin) * 60; case .short: return Double(shortMin) * 60; case .long: return Double(longMin) * 60 }
    }
    var left: TimeInterval { running ? max(0, endDate.timeIntervalSinceNow) : remaining }
    var progress: Double { min(1, max(0, 1 - left / duration(phase))) }

    // MARK: Acciones

    func toggle() {
        if running { remaining = left; running = false }
        else { endDate = Date(timeIntervalSinceNow: remaining); running = true }
        save(); syncMusic()
    }
    func reset() {
        logInterrupted()
        if phase == .focus { FocusMusic.shared.focusDidEnd() }
        running = false; remaining = duration(phase); save(); syncMusic()
    }
    func skip() { logInterrupted(); advance(counted: false, autoRun: false) }

    /// Si se corta un foco con al menos 1 min avanzado, queda registrado como interrumpido.
    private func logInterrupted() {
        guard phase == .focus else { return }
        let elapsed = duration(.focus) - left
        if elapsed >= 60 { History.shared.add(SessionRecord(end: Date(), minutes: elapsed / 60, completed: false, tag: tag)) }
    }

    func tick() {
        if running && left <= 0 {
            if phase == .focus {
                History.shared.add(SessionRecord(end: Date(), minutes: duration(.focus) / 60, completed: true, tag: tag))
            }
            NSSound(named: "Glass")?.play()
            flashUntil = CACurrentMediaTime() + 4
            advance(counted: true, autoRun: autoStart)
        }
    }

    /// La música suena solo con el pomodoro corriendo, en fase de foco y sin silenciar; FocusMusic aplica los fundidos.
    func syncMusic() {
        FocusMusic.shared.update(shouldPlay: running && phase == .focus && !musicMuted)
    }

    private func advance(counted: Bool, autoRun: Bool) {
        if phase == .focus { FocusMusic.shared.focusDidEnd() }
        switch phase {
        case .focus:
            if counted { completed += 1 }
            phase = (counted && completed % cycle == 0) ? .long : .short
        case .short: phase = .focus
        case .long: phase = .focus; completed = 0
        }
        remaining = duration(phase)
        running = autoRun
        if autoRun { endDate = Date(timeIntervalSinceNow: remaining) }
        save(); syncMusic()
    }

    // MARK: Persistencia

    func save() {
        d.set(focusMin, forKey: "pomo.focus"); d.set(shortMin, forKey: "pomo.short")
        d.set(longMin, forKey: "pomo.long"); d.set(cycle, forKey: "pomo.cycle")
        d.set(autoStart, forKey: "pomo.auto"); d.set(phase.rawValue, forKey: "pomo.phase")
        d.set(completed, forKey: "pomo.completed"); d.set(running, forKey: "pomo.running")
        d.set(endDate, forKey: "pomo.end"); d.set(left, forKey: "pomo.remaining")
        d.set(Date(), forKey: "pomo.savedAt")
        d.set(visible, forKey: "pomo.visible"); d.set(compact, forKey: "pomo.compact")
        d.set(tag, forKey: "pomo.tag")
    }

    func load() {
        guard d.object(forKey: "pomo.focus") != nil else { remaining = duration(.focus); return }
        focusMin = d.integer(forKey: "pomo.focus"); shortMin = d.integer(forKey: "pomo.short")
        longMin = d.integer(forKey: "pomo.long"); cycle = max(1, d.integer(forKey: "pomo.cycle"))
        autoStart = d.bool(forKey: "pomo.auto")
        phase = Phase(rawValue: d.string(forKey: "pomo.phase") ?? "") ?? .focus
        completed = d.integer(forKey: "pomo.completed")
        visible = d.object(forKey: "pomo.visible") as? Bool ?? true
        compact = d.bool(forKey: "pomo.compact")
        tag = d.string(forKey: "pomo.tag") ?? ""
        remaining = d.double(forKey: "pomo.remaining")
        if remaining <= 0 { remaining = duration(phase) }
        // Si estaba corriendo y volvió rápido (la app se relanzó), sigue contando.
        // Si pasó mucho tiempo (apagado/reinicio), vuelve en pausa con el tiempo que quedaba.
        let savedAt = d.object(forKey: "pomo.savedAt") as? Date ?? .distantPast
        if d.bool(forKey: "pomo.running"), Date().timeIntervalSince(savedAt) < 120,
           let end = d.object(forKey: "pomo.end") as? Date {
            endDate = end; running = true
            if end.timeIntervalSinceNow <= 0 { tick() }
        }
        syncMusic()
    }
}

// MARK: - Vista del widget

final class PomoView: NSView {
    let p = Pomodoro.shared
    var downScreen: NSPoint?
    var downOrigin: NSPoint?
    var moved = false
    var onSettings: () -> Void = {}
    var onStats: () -> Void = {}
    var onTag: () -> Void = {}

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    static func size(compact: Bool) -> NSSize { compact ? NSSize(width: 150, height: 58) : NSSize(width: 250, height: 132) }

    enum Btn { case toggle, skip, reset, music, shrink, settings, stats }
    func buttons() -> [(Btn, NSRect)] {
        guard !p.compact else { return [] }
        var items: [Btn] = [.toggle, .skip, .reset, .stats, .settings, .shrink]
        // Con la música de foco activada entra un séptimo botón; se estrechan para que la fila siga cabiendo.
        let hasMusic = FocusMusic.shared.enabled
        if hasMusic { items.insert(.music, at: 3) }
        let b: CGFloat = hasMusic ? 28 : 32, gap: CGFloat = hasMusic ? 4 : 6
        let w = CGFloat(items.count) * b + CGFloat(items.count - 1) * gap
        var x = bounds.midX - w / 2
        return items.map { i in defer { x += b + gap }; return (i, NSRect(x: x, y: 12, width: b, height: b)) }
    }

    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        moved = false
        if let (b, _) = buttons().first(where: { $0.1.contains(pt) }) {
            switch b {
            case .toggle: p.toggle()
            case .skip: p.skip()
            case .reset: p.reset()
            case .music: p.musicMuted.toggle(); p.syncMusic()
            case .settings: onSettings()
            case .stats: onStats()
            case .shrink: setCompact(true)
            }
            needsDisplay = true; downScreen = nil; return
        }
        if !p.compact, e.clickCount >= 2, pt.y > bounds.maxY - 34 { onTag(); downScreen = nil; return }  // doble clic en el título: cambia el tema
        downScreen = NSEvent.mouseLocation
        downOrigin = window?.frame.origin
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = downScreen, let o = downOrigin else { return }
        let g = NSEvent.mouseLocation
        if hypot(g.x - s.x, g.y - s.y) > 3 { moved = true }
        if moved { window?.setFrameOrigin(NSPoint(x: o.x + g.x - s.x, y: o.y + g.y - s.y)) }
    }
    override func mouseUp(with e: NSEvent) {
        defer { downScreen = nil }
        guard downScreen != nil else { return }
        if moved {
            if let o = window?.frame.origin { UserDefaults.standard.set([o.x, o.y], forKey: "pomo.origin") }
        } else if p.compact {
            if e.clickCount >= 2 { setCompact(false) } else { p.toggle() }
            needsDisplay = true
        }
    }

    func setCompact(_ c: Bool) {
        guard let w = window else { return }
        p.compact = c; p.save()
        let old = w.frame, new = PomoView.size(compact: c)
        w.setFrame(NSRect(x: old.minX, y: old.maxY - new.height, width: new.width, height: new.height), display: true)
        needsDisplay = true
    }

    func symbol(_ name: String, fallback: String, in r: NSRect, size: CGFloat = 15) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        } else {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
            let sz = (fallback as NSString).size(withAttributes: a)
            (fallback as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
        }
    }

    override func draw(_ dirty: NSRect) {
        let now = CACurrentMediaTime()
        let col = p.phase.color
        let card = bounds.insetBy(dx: 2, dy: 2)
        NSColor(white: 0.07, alpha: 0.9).setFill()
        let shape = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        shape.fill()

        // Parpadeo al terminar una fase
        if now < p.flashUntil, Int(now * 3) % 2 == 0 {
            col.withAlphaComponent(0.35).setFill(); shape.fill()
        }

        // Barra de progreso (abajo)
        let bar = NSRect(x: card.minX + 16, y: card.minY + 7, width: card.width - 32, height: 4)
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        col.setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * CGFloat(p.progress)), height: 4),
                     xRadius: 2, yRadius: 2).fill()

        // Tiempo
        let secs = Int(ceil(p.left))
        let time = String(format: "%02d:%02d", secs / 60, secs % 60)
        let fs: CGFloat = p.compact ? 30 : 48
        let ta: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fs, weight: .bold),
            .foregroundColor: p.running ? NSColor.white : NSColor(white: 1, alpha: 0.6)]
        let tsz = (time as NSString).size(withAttributes: ta)
        let ty = p.compact ? card.minY + 16 : card.maxY - 30 - tsz.height
        (time as NSString).draw(at: NSPoint(x: bounds.midX - tsz.width / 2 + (p.compact ? 8 : 0), y: ty), withAttributes: ta)

        if p.compact {
            col.setFill()
            NSBezierPath(ovalIn: NSRect(x: card.minX + 14, y: ty + tsz.height / 2 - 5, width: 10, height: 10)).fill()
            return
        }

        // Fase + puntos de sesiones
        let la: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: col]
        let dot: CGFloat = 8, dgap: CGFloat = 5
        let total = CGFloat(p.cycle) * dot + CGFloat(p.cycle - 1) * dgap
        var x = card.maxX - 16 - total
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        var head = p.phase.title
        if !p.tag.isEmpty { head += " · " + p.tag }
        var la2 = la; la2[.paragraphStyle] = ps
        (head as NSString).draw(in: NSRect(x: card.minX + 16, y: card.maxY - 24, width: x - card.minX - 28, height: 16), withAttributes: la2)
        for i in 0..<p.cycle {
            let r = NSRect(x: x, y: card.maxY - 22, width: dot, height: dot)
            if i < p.completed { col.setFill(); NSBezierPath(ovalIn: r).fill() }
            else { NSColor(white: 1, alpha: 0.35).setStroke(); let c = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)); c.lineWidth = 1; c.stroke() }
            x += dot + dgap
        }

        // Botones
        for (b, r) in buttons() {
            NSColor(white: 1, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            switch b {
            case .toggle: symbol(p.running ? "pause.fill" : "play.fill", fallback: p.running ? "⏸" : "▶", in: r)
            case .skip: symbol("forward.end.fill", fallback: "⏭", in: r)
            case .reset: symbol("arrow.counterclockwise", fallback: "↺", in: r)
            case .music:
                if p.musicMuted {
                    // Silenciada en esta sesión: nota atenuada y tachada
                    NSGraphicsContext.current?.cgContext.setAlpha(0.4)
                    symbol("music.note", fallback: "♪", in: r, size: 14)
                    NSGraphicsContext.current?.cgContext.setAlpha(1)
                    NSColor(white: 1, alpha: 0.8).setStroke()
                    let l = NSBezierPath(); l.lineWidth = 1.8; l.lineCapStyle = .round
                    l.move(to: NSPoint(x: r.minX + 7, y: r.maxY - 7)); l.line(to: NSPoint(x: r.maxX - 7, y: r.minY + 7)); l.stroke()
                } else {
                    col.withAlphaComponent(0.35).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
                    symbol("music.note", fallback: "♪", in: r, size: 14)
                }
            case .settings: symbol("gearshape.fill", fallback: "⚙", in: r)
            case .stats: symbol("chart.bar.fill", fallback: "▥", in: r)
            case .shrink: symbol("arrow.down.right.and.arrow.up.left", fallback: "–", in: r, size: 13)
            }
        }
    }
}

final class PomoPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func makePomoPanel(onSettings: @escaping () -> Void, onStats: @escaping () -> Void,
                   onTag: @escaping () -> Void) -> (PomoPanel, PomoView) {
    let p = Pomodoro.shared
    let size = PomoView.size(compact: p.compact)
    var origin: NSPoint
    if let a = UserDefaults.standard.array(forKey: "pomo.origin") as? [Double], a.count == 2,
       NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: a[0] + 20, y: a[1] + 20)) }) {
        origin = NSPoint(x: a[0], y: a[1])
    } else {
        let f = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        origin = NSPoint(x: f.maxX - size.width - 20, y: f.maxY - size.height - 20)
    }
    let w = PomoPanel(contentRect: NSRect(origin: origin, size: size),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    w.isFloatingPanel = true
    w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
    w.hidesOnDeactivate = false
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let v = PomoView(frame: NSRect(origin: .zero, size: size))
    v.onSettings = onSettings; v.onStats = onStats; v.onTag = onTag
    w.contentView = v
    return (w, v)
}
