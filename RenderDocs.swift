// Modo documentación: `ScreenInk --render-docs <carpeta>` dibuja las vistas de la propia app
// (InkView, PomoView, StatsView) en PNG a 2x, sobre un fondo de ejemplo y con datos inventados.
// No crea ventanas visibles, ni icono de barra de menús, ni atajos, ni temporizadores, y no lee
// ni escribe UserDefaults ni el historial real.
import Cocoa

/// Fondo neutro: degradado oscuro con "ventanas" difusas que simulan contenido.
final class DocsBackdrop: NSView {
    var windows = false
    override func draw(_ dirty: NSRect) {
        NSGradient(colors: [NSColor(red: 0.13, green: 0.15, blue: 0.22, alpha: 1),
                            NSColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)])!
            .draw(in: bounds, angle: -60)
        guard windows else { return }
        func win(_ r: NSRect, _ lines: [CGFloat], _ tint: NSColor) {
            NSColor(white: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            NSColor(white: 1, alpha: 0.10).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + 16 + CGFloat(i) * 18, y: r.maxY - 26, width: 11, height: 11)).fill()
            }
            for (i, w) in lines.enumerated() {
                tint.withAlphaComponent(i % 3 == 0 ? 0.30 : 0.18).setFill()
                let y = r.maxY - 70 - CGFloat(i) * 30
                NSBezierPath(roundedRect: NSRect(x: r.minX + 30, y: y, width: w, height: 10), xRadius: 5, yRadius: 5).fill()
            }
        }
        win(DocsLayout.winA, [330, 210, 400, 280, 360, 440, 250, 380, 300, 180, 330], .systemTeal)
        win(DocsLayout.winB, [260, 320, 200, 0, 0, 0, 300, 240, 280, 200], .systemPurple)
        NSColor(white: 1, alpha: 0.10).setFill()
        NSBezierPath(roundedRect: DocsLayout.card, xRadius: 10, yRadius: 10).fill()
    }
}

enum DocsLayout {
    static let size = NSSize(width: 1440, height: 810)
    static let winA = NSRect(x: 80, y: 150, width: 700, height: 560)
    static let winB = NSRect(x: 860, y: 230, width: 480, height: 480)
    static let card = NSRect(x: 890, y: 450, width: 420, height: 100)
    /// Y de la línea i de la ventana A (coincide con el fondo).
    static func lineY(_ i: Int) -> CGFloat { winA.maxY - 70 - CGFloat(i) * 30 + 5 }
}

private func png(_ view: NSView, to path: String, crop: NSRect? = nil) {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = b.size
    view.cacheDisplay(in: b, to: rep)
    var out = rep
    if let c = crop, let cg = rep.cgImage {
        // c en puntos con origen abajo-izquierda -> píxeles con origen arriba-izquierda
        let px = CGRect(x: c.minX * 2, y: (b.height - c.maxY) * 2, width: c.width * 2, height: c.height * 2)
        if let part = cg.cropping(to: px) { out = NSBitmapImageRep(cgImage: part) }
    }
    if let data = out.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("escrito \(path) (\(out.pixelsWide)x\(out.pixelsHigh))")
    }
}

private func stroke(_ tool: Tool, _ color: NSColor, _ width: CGFloat, _ pts: [NSPoint]) -> Item {
    let it = Item(tool: tool, color: color, width: width, lifetime: nil)   // endedAt nil: nunca se desvanece
    it.points = pts
    return it
}

private func sampleRecords() -> [SessionRecord] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let counts = [3, 4, 2, 3, 5, 4, 3, 1, 0, 4, 3, 5, 2, 4, 3, 0, 4, 2, 5, 3, 4, 0, 2, 3, 4, 3, 1, 4, 2, 3]
    let tags = ["Swift", "Swift", "English practice", "Live stream", "Reading", "Swift", "English practice", "Math"]
    var out: [SessionRecord] = []
    var k = 0
    for (off, n) in counts.enumerated() {
        let day = cal.date(byAdding: .day, value: -off, to: today)!
        for j in 0..<n {
            let end = cal.date(byAdding: .minute, value: 9 * 60 + j * 55, to: day)!
            let tag = tags[k % tags.count]; k += 1
            out.append(SessionRecord(end: end, minutes: 25, completed: true, tag: tag))
            if (off + j) % 7 == 3 { out.append(SessionRecord(end: end.addingTimeInterval(1800), minutes: 11, completed: false, tag: tag)) }
        }
    }
    return out
}

func renderDocs(to dir: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let L = DocsLayout.self
    let m = Model.shared

    // Ventana anfitriona fuera de pantalla: nunca se muestra.
    let host = OverlayWindow(contentRect: NSRect(origin: .zero, size: L.size), styleMask: .borderless,
                             backing: .buffered, defer: false)
    let root = DocsBackdrop(frame: NSRect(origin: .zero, size: L.size))
    root.windows = true
    let ink = InkView(frame: root.bounds)
    root.addSubview(ink)
    host.contentView = root
    m.toolbarFrame = host.frame

    // 1) Capa de dibujo con anotaciones reales (modelo Item)
    var circle: [NSPoint] = []
    let cx = L.winA.minX + 280, cy = L.lineY(5), rx: CGFloat = 270, ry: CGFloat = 32
    for i in 0...96 {
        let t = -0.6 + Double(i) / 96 * 7.1
        let wob = 1 + 0.03 * sin(t * 3)
        circle.append(NSPoint(x: cx + rx * wob * CGFloat(cos(t)), y: cy + ry * wob * CGFloat(sin(t)) + CGFloat(t) * 1.2))
    }
    var hl: [NSPoint] = []
    for i in 0...30 { hl.append(NSPoint(x: L.winA.minX + 28 + CGFloat(i) * 10.5, y: L.lineY(2) + CGFloat(sin(Double(i) / 4)) * 1.5)) }
    let text = stroke(.text, palette[4], sizes[0], [NSPoint(x: 900, y: 170)]); text.text = "Look here"
    m.items = [
        stroke(.highlighter, palette[1], sizes[1], hl),
        stroke(.pen, palette[0], sizes[1], circle),
        stroke(.arrow, palette[2], sizes[1], [NSPoint(x: 940, y: 205), NSPoint(x: 640, y: 455)]),
        stroke(.rect, palette[3], sizes[0], [NSPoint(x: L.card.minX - 12, y: L.card.minY - 12),
                                             NSPoint(x: L.card.maxX + 12, y: L.card.maxY + 12)]),
        text,
    ]
    m.tool = .pen; m.colorIndex = 0; m.sizeIndex = 1; m.lifeIndex = 2
    m.drawing = true; m.toolbarVisible = true; m.spotlight = false; m.halo = false
    png(root, to: dir + "/drawing-overlay.png")

    // 2) Solo la barra de herramientas
    let (bg, _) = ink.layout()
    png(root, to: dir + "/toolbar.png", crop: bg.insetBy(dx: -16, dy: -12))

    // 3) Spotlight (círculo suave, resto atenuado)
    m.items = []; m.drawing = false; m.spotlight = true; m.spotSize = 2
    m.fakePointer = NSPoint(x: L.winA.minX + 300, y: L.lineY(4))
    png(root, to: dir + "/spotlight.png")
    m.spotlight = false; m.fakePointer = nil

    // 4) Pomodoro (completo y compacto) con datos de ejemplo; no se guarda nada
    let p = Pomodoro.shared
    p.phase = .focus; p.tag = "Swift"; p.completed = 2; p.cycle = 4
    p.running = true; p.endDate = Date(timeIntervalSinceNow: 17 * 60 + 42)
    for compact in [false, true] {
        p.compact = compact
        let s = PomoView.size(compact: compact)
        let box = DocsBackdrop(frame: NSRect(x: 0, y: 0, width: s.width + 60, height: s.height + 60))
        let v = PomoView(frame: NSRect(x: 30, y: 30, width: s.width, height: s.height))
        box.addSubview(v)
        png(box, to: dir + (compact ? "/pomodoro-compact.png" : "/pomodoro.png"))
    }

    // 5) Estadísticas con registros inventados (no se toca el historial real)
    let sv = StatsView(frame: NSRect(x: 0, y: 0, width: 580, height: 560))
    sv.records = sampleRecords()
    png(sv, to: dir + "/stats.png")
}
