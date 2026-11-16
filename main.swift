// ScreenInk — anotaciones sobre la pantalla para directos y clases.
//
// Atajos globales (funcionan siempre):
//   ⌃⌥D  activar / salir del modo dibujo
//   ⌃⌥L  puntero con estela (láser); de nuevo para salir
//   ⌃⌥H  halo del cursor + onda al hacer clic
//   ⌃⌥C  borrar todo al instante
//   ⌃⌥F  spotlight del cursor (oscurece todo menos un círculo que sigue al cursor)
//   ⌃⌥Q  nota rápida (se guarda en <vault>/Inbox, ver QuickNote.swift)
//
// En modo dibujo:
//   P lápiz · L estela · H resaltador · A flecha · R rectángulo · O elipse · T texto
//   F spotlight del cursor (también en la barra: botón + tamaño P/M/G)
//   1-6 colores · K color libre · [ ] tamaño · S cambia duración (2s / 30s / ∞)
//   ⌘Z o Backspace deshacer · C borrar todo · Tab oculta la barra · Esc salir
//   Texto: clic y escribe · Enter confirma · Shift+Enter nueva línea
import Cocoa
import Carbon.HIToolbox
import CoreAudio

// MARK: - Estado del micrófono (volumen de entrada; 0 = silenciado, igual que toggle-mic.sh)

func micVolume() -> Float? {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
          dev != 0 else { return nil }
    let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1]
    for el in elements {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                           mScope: kAudioDevicePropertyScopeInput, mElement: el)
        var vol = Float32(0)
        var s = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(dev, &a), AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &vol) == noErr {
            return vol
        }
    }
    return nil
}

// MARK: - Config

let fadeSeconds: CFTimeInterval = 1.0     // duración del desvanecido final
let trailLife: CFTimeInterval = 0.9       // vida de la estela
let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemCyan, .white, .systemPink]
let sizes: [CGFloat] = [3, 6, 12]
let spotRadii: [CGFloat] = [100, 150, 220]   // Pequeño / Mediano / Grande
let spotNames = ["Pequeño", "Mediano", "Grande"]
let lifes: [(String, CFTimeInterval?)] = [("2s", 2.5), ("30s", 30), ("∞", nil)]

enum Tool: CaseIterable { case pen, laser, highlighter, arrow, rect, ellipse, text }

enum Action: Equatable {
    case tool(Tool), color(Int), size(Int), life(Int), spotlight, spotSize, undo, clear, close
}

// MARK: - Modelo (coordenadas globales de pantalla)

final class Item {
    let tool: Tool
    var points: [NSPoint] = []
    var color: NSColor
    var width: CGFloat
    var text = ""
    var marked = ""
    var lifetime: CFTimeInterval?      // nil = fijo
    var endedAt: CFTimeInterval?

    init(tool: Tool, color: NSColor, width: CGFloat, lifetime: CFTimeInterval?) {
        self.tool = tool; self.color = color; self.width = width; self.lifetime = lifetime
    }
    func alpha(_ now: CFTimeInterval) -> CGFloat {
        guard let e = endedAt, let life = lifetime else { return 1 }
        let t = now - e - life
        return t <= 0 ? 1 : max(0, 1 - CGFloat(t / fadeSeconds))
    }
    func expired(_ now: CFTimeInterval) -> Bool {
        guard let e = endedAt, let life = lifetime else { return false }
        return now - e > life + fadeSeconds
    }
}

final class Model {
    static let shared = Model()
    var tool: Tool = .pen
    var colorIndex = 0                  // -1 = color libre
    var customColor = NSColor.orange
    var sizeIndex = 1
    var lifeIndex = 0
    var items: [Item] = []
    var current: Item?
    var editing: Item?
    var trail: [(NSPoint, CFTimeInterval)] = []
    var ripples: [(NSPoint, CFTimeInterval)] = []
    var halo = false
    var spotlight = false               // no se persiste: siempre arranca apagado
    var spotSize = 1
    var drawing = false
    var toolbarVisible = true
    var toolbarFrame: NSRect?
    var fakePointer: NSPoint?           // solo para --render-docs; nil = cursor real
    var views: [InkView] = []

    var color: NSColor { colorIndex < 0 ? customColor : palette[colorIndex] }
    var width: CGFloat { sizes[sizeIndex] }
    var lifetime: CFTimeInterval? { lifes[lifeIndex].1 }

    func save() {
        let d = UserDefaults.standard
        d.set(colorIndex, forKey: "ink.color"); d.set(sizeIndex, forKey: "ink.size")
        d.set(lifeIndex, forKey: "ink.life"); d.set(halo, forKey: "ink.halo")
        d.set(spotSize, forKey: "ink.spot")
        if let c = customColor.usingColorSpace(.sRGB) {
            d.set([c.redComponent, c.greenComponent, c.blueComponent], forKey: "ink.custom")
        }
    }
    func load() {
        let d = UserDefaults.standard
        if d.object(forKey: "ink.spot") != nil { spotSize = min(max(d.integer(forKey: "ink.spot"), 0), spotRadii.count - 1) }
        guard d.object(forKey: "ink.size") != nil else { return }
        colorIndex = min(max(d.integer(forKey: "ink.color"), -1), palette.count - 1)
        sizeIndex = min(max(d.integer(forKey: "ink.size"), 0), sizes.count - 1)
        lifeIndex = min(max(d.integer(forKey: "ink.life"), 0), lifes.count - 1)
        halo = d.bool(forKey: "ink.halo")
        if let a = d.array(forKey: "ink.custom") as? [Double], a.count == 3 {
            customColor = NSColor(srgbRed: a[0], green: a[1], blue: a[2], alpha: 1)
        }
    }

    func invalidate() { views.forEach { $0.needsDisplay = true } }
    func setTool(_ t: Tool) {
        commitText(); tool = t
        views.forEach { $0.window?.invalidateCursorRects(for: $0) }
        invalidate()
    }
    func commitText() {
        guard let t = editing else { return }
        if t.text.isEmpty && t.marked.isEmpty { items.removeAll { $0 === t } }
        else { t.text += t.marked; t.marked = ""; t.endedAt = CACurrentMediaTime() }
        editing = nil; invalidate()
    }
    func clearAll() { commitText(); items.removeAll(); trail.removeAll(); ripples.removeAll(); invalidate() }
    func undo() { commitText(); _ = items.popLast(); invalidate() }
}

// MARK: - Vista

final class InkView: NSView, NSTextInputClient {
    var swallow = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        guard Model.shared.drawing else { return }
        addCursorRect(bounds, cursor: Model.shared.tool == .text ? .iBeam : .crosshair)
    }

    var pointer: NSPoint { Model.shared.fakePointer ?? NSEvent.mouseLocation }

    var showsToolbar: Bool {
        let m = Model.shared
        return m.drawing && m.toolbarVisible && window?.frame == m.toolbarFrame
    }

    // MARK: Barra de herramientas

    func layout() -> (NSRect, [(Action, NSRect)]) {
        let groups: [[Action]] = [
            Tool.allCases.map { .tool($0) },
            (0..<palette.count).map { .color($0) } + [.color(-1)],
            [.size(0), .size(1), .size(2)],
            [.life(0), .life(1), .life(2)],
            [.spotlight, .spotSize],
            [.undo, .clear, .close],
        ]
        let b: CGFloat = 34, gap: CGFloat = 4, sep: CGFloat = 14, pad: CGFloat = 12
        let count = groups.reduce(0) { $0 + $1.count }
        let w = pad * 2 + CGFloat(count) * b + CGFloat(count - groups.count) * gap + CGFloat(groups.count - 1) * sep
        let bg = NSRect(x: bounds.midX - w / 2, y: 28, width: w, height: b + 16)
        var x = bg.minX + pad
        var out: [(Action, NSRect)] = []
        for (gi, g) in groups.enumerated() {
            for (i, a) in g.enumerated() {
                out.append((a, NSRect(x: x, y: bg.minY + 8, width: b, height: b)))
                x += b + (i < g.count - 1 ? gap : 0)
            }
            if gi < groups.count - 1 { x += sep }
        }
        return (bg, out)
    }

    func isSelected(_ a: Action) -> Bool {
        let m = Model.shared
        switch a {
        case .tool(let t): return m.tool == t
        case .color(let i): return m.colorIndex == i
        case .size(let i): return m.sizeIndex == i
        case .life(let i): return m.lifeIndex == i
        case .spotlight: return m.spotlight
        default: return false
        }
    }

    func symbol(_ name: String, fallback: String, in r: NSRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        } else { label(fallback, in: r) }
    }
    func label(_ s: String, in r: NSRect) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
    }

    func drawToolbar() {
        let (bg, buttons) = layout()
        NSColor(white: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 14, yRadius: 14).fill()
        let m = Model.shared
        for (a, r) in buttons {
            if isSelected(a) {
                NSColor(white: 1, alpha: 0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            }
            switch a {
            case .tool(let t):
                let map: [Tool: (String, String)] = [
                    .pen: ("pencil.tip", "P"), .laser: ("cursorarrow.rays", "L"), .highlighter: ("highlighter", "H"),
                    .arrow: ("arrow.up.right", "→"), .rect: ("rectangle", "▭"), .ellipse: ("circle", "○"), .text: ("textformat", "T")]
                symbol(map[t]!.0, fallback: map[t]!.1, in: r)
            case .color(let i):
                let c = i < 0 ? m.customColor : palette[i]
                let d = r.insetBy(dx: 7, dy: 7)
                c.setFill(); NSBezierPath(ovalIn: d).fill()
                NSColor(white: 1, alpha: i < 0 ? 0.9 : 0.35).setStroke()
                let ring = NSBezierPath(ovalIn: d); ring.lineWidth = i < 0 ? 2 : 1; ring.stroke()
                if i < 0 { label("+", in: r) }
            case .size(let i):
                let d = sizes[i] + 3
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            case .life(let i): label(lifes[i].0, in: r)
            case .spotlight: symbol("flashlight.on.fill", fallback: "◉", in: r)
            case .spotSize: label(["P", "M", "G"][m.spotSize], in: r)
            case .undo: symbol("arrow.uturn.backward", fallback: "↶", in: r)
            case .clear: symbol("trash", fallback: "🗑", in: r)
            case .close: symbol("xmark", fallback: "✕", in: r)
            }
        }
    }

    func hit(_ p: NSPoint) -> Action? {
        layout().1.first { $0.1.contains(p) }?.0
    }

    func perform(_ a: Action) {
        let m = Model.shared
        switch a {
        case .tool(let t): m.setTool(t)
        case .color(let i):
            m.colorIndex = i
            if i < 0 { (NSApp.delegate as? App)?.openColorPanel() }
        case .size(let i): m.sizeIndex = i
        case .life(let i): m.lifeIndex = i
        case .spotlight: (NSApp.delegate as? App)?.toggleSpotlight()
        case .spotSize: (NSApp.delegate as? App)?.cycleSpotSize()
        case .undo: m.undo()
        case .clear: m.clearAll()
        case .close: (NSApp.delegate as? App)?.setDrawing(false)
        }
        m.invalidate()
    }

    // MARK: Ratón

    override func mouseDown(with e: NSEvent) {
        let m = Model.shared
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if showsToolbar {
            if let a = hit(p) { perform(a); swallow = true; return }
            if layout().0.contains(p) { swallow = true; return }
        }
        swallow = false
        m.commitText()
        let g = NSEvent.mouseLocation
        switch m.tool {
        case .laser: break
        case .text:
            let it = Item(tool: .text, color: m.color, width: m.width, lifetime: m.lifetime)
            it.points = [g]; m.items.append(it); m.editing = it
        default:
            let it = Item(tool: m.tool, color: m.color, width: m.width, lifetime: m.lifetime)
            it.points = [g]
            if [.arrow, .rect, .ellipse].contains(m.tool) { it.points.append(g) }
            m.items.append(it); m.current = it
        }
        m.invalidate()
    }

    override func mouseDragged(with e: NSEvent) {
        if swallow { return }
        let m = Model.shared
        guard let it = m.current else { return }
        let g = NSEvent.mouseLocation
        if it.tool == .pen || it.tool == .highlighter {
            if let l = it.points.last, hypot(l.x - g.x, l.y - g.y) < 1.2 { return }
            it.points.append(g)
        } else { it.points[1] = g }
        m.invalidate()
    }

    override func mouseUp(with e: NSEvent) {
        let m = Model.shared
        swallow = false
        guard let it = m.current else { return }
        if it.points.count == 2, hypot(it.points[0].x - it.points[1].x, it.points[0].y - it.points[1].y) < 4 {
            m.items.removeAll { $0 === it }     // clic sin arrastre: no crea formas diminutas
        } else { it.endedAt = CACurrentMediaTime() }
        m.current = nil
        m.invalidate()
    }

    // MARK: Teclado

    override func keyDown(with e: NSEvent) {
        let m = Model.shared
        let code = Int(e.keyCode)
        if m.editing != nil {
            if !hasMarkedText() {
                if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                    if e.modifierFlags.contains(.shift) { m.editing?.text += "\n" } else { m.commitText() }
                    m.invalidate(); return
                }
                if code == kVK_Escape { m.commitText(); return }
            }
            interpretKeyEvents([e]); m.invalidate(); return
        }
        let app = NSApp.delegate as? App
        if code == kVK_Escape { app?.setDrawing(false); return }
        if code == kVK_Tab { m.toolbarVisible.toggle(); m.invalidate(); return }
        if code == kVK_Delete { m.undo(); return }
        let k = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if e.modifierFlags.contains(.command) { if k == "z" { m.undo() }; return }
        switch k {
        case "p": m.setTool(.pen)
        case "l": m.setTool(.laser)
        case "h": m.setTool(.highlighter)
        case "a": m.setTool(.arrow)
        case "r": m.setTool(.rect)
        case "o": m.setTool(.ellipse)
        case "t": m.setTool(.text)
        case "1", "2", "3", "4", "5", "6": m.colorIndex = Int(k)! - 1
        case "k": m.colorIndex = -1; app?.openColorPanel()
        case "[": m.sizeIndex = max(0, m.sizeIndex - 1)
        case "]": m.sizeIndex = min(sizes.count - 1, m.sizeIndex + 1)
        case "s": m.lifeIndex = (m.lifeIndex + 1) % lifes.count
        case "c": m.clearAll()
        case "u": m.undo()
        case "f": app?.toggleSpotlight()
        default: break
        }
        m.invalidate()
    }

    // MARK: NSTextInputClient (acentos, ñ, IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        Model.shared.editing?.text += s
        Model.shared.editing?.marked = ""
        Model.shared.invalidate()
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        Model.shared.editing?.marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        Model.shared.invalidate()
    }
    func unmarkText() { Model.shared.editing?.marked = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        let n = Model.shared.editing?.marked.count ?? 0
        return n == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: n)
    }
    func hasMarkedText() -> Bool { !(Model.shared.editing?.marked.isEmpty ?? true) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.deleteBackward(_:)), let t = Model.shared.editing, !t.text.isEmpty {
            t.text.removeLast(); Model.shared.invalidate()
        }
    }

    // MARK: Dibujo

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let win = window else { return }
        let m = Model.shared, now = CACurrentMediaTime()
        ctx.saveGState()
        ctx.translateBy(x: -win.frame.origin.x, y: -win.frame.origin.y)
        drawSpotlight(win.frame)
        for it in m.items { drawItem(it, now) }
        drawTrail(now)
        drawRipples(now)
        drawHalo()
        ctx.restoreGState()
        if showsToolbar { drawToolbar() }
    }

    /// Oscurece toda la pantalla salvo un círculo de bordes suaves alrededor del cursor.
    /// Se dibuja antes que tinta, estela, ondas y halo, así las anotaciones quedan por encima.
    func drawSpotlight(_ frame: NSRect) {
        let m = Model.shared
        guard m.spotlight, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = pointer, r = spotRadii[m.spotSize]
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 0, green: 0, blue: 0, alpha: 0), CGColor(red: 0, green: 0, blue: 0, alpha: 0.65)] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: frame)
        ctx.drawRadialGradient(grad, startCenter: g, startRadius: r * 0.7, endCenter: g, endRadius: r,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    func drawItem(_ it: Item, _ now: CFTimeInterval) {
        let a = it.alpha(now)
        guard a > 0, let f = it.points.first else { return }
        let col = it.color.withAlphaComponent(it.tool == .highlighter ? 0.35 * a : a)
        col.setStroke(); col.setFill()
        let path = NSBezierPath()
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.lineWidth = it.tool == .highlighter ? it.width * 3.5 : it.width
        switch it.tool {
        case .pen, .highlighter:
            if it.points.count < 2 {
                let r = path.lineWidth / 2
                NSBezierPath(ovalIn: NSRect(x: f.x - r, y: f.y - r, width: r * 2, height: r * 2)).fill()
                return
            }
            path.move(to: f); it.points.dropFirst().forEach { path.line(to: $0) }
            path.stroke()
        case .arrow:
            let l = it.points[1]
            path.move(to: f); path.line(to: l)
            let ang = atan2(l.y - f.y, l.x - f.x), hl = 14 + it.width * 2.5
            for s in [-1.0, 1.0] {
                let t = ang + .pi + CGFloat(s) * 0.5
                path.move(to: l); path.line(to: NSPoint(x: l.x + cos(t) * hl, y: l.y + sin(t) * hl))
            }
            path.stroke()
        case .rect, .ellipse:
            let l = it.points[1]
            let r = NSRect(x: min(f.x, l.x), y: min(f.y, l.y), width: abs(l.x - f.x), height: abs(l.y - f.y))
            let p = it.tool == .rect ? NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4) : NSBezierPath(ovalIn: r)
            p.lineWidth = it.width; p.stroke()
        case .text: drawText(it, a: a, now: now)
        case .laser: break
        }
    }

    func drawText(_ it: Item, a: CGFloat, now: CFTimeInterval) {
        let font = NSFont.systemFont(ofSize: 22 + it.width * 3, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: it.color.withAlphaComponent(a)]
        let full = it.text + it.marked
        let str = (full.isEmpty ? " " : full) as NSString
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let sz = str.boundingRect(with: NSSize(width: 4000, height: 4000), options: .usesLineFragmentOrigin, attributes: attrs).size
        let o = it.points[0]
        let rect = NSRect(x: o.x, y: o.y + lineH / 2 - sz.height, width: max(sz.width, 14), height: sz.height)
        let bright = (it.color.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1) > 0.5
        (bright ? NSColor(white: 0, alpha: 0.55 * a) : NSColor(white: 1, alpha: 0.8 * a)).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -10, dy: -6), xRadius: 8, yRadius: 8).fill()
        str.draw(with: rect, options: .usesLineFragmentOrigin, attributes: attrs)
        if Model.shared.editing === it, Int(now * 2) % 2 == 0 {
            let last = (full.components(separatedBy: "\n").last ?? "") as NSString
            let x = rect.minX + last.size(withAttributes: attrs).width + 2
            it.color.setFill()
            NSRect(x: x, y: rect.minY, width: 2.5, height: lineH).fill()
        }
    }

    func drawTrail(_ now: CFTimeInterval) {
        let m = Model.shared
        let pts = m.trail
        if pts.count > 1 {
            for i in 1..<pts.count {
                let k = max(0, 1 - CGFloat((now - pts[i].1) / trailLife))
                let p = NSBezierPath()
                p.lineCapStyle = .round
                p.lineWidth = 2 + (m.width + 5) * k
                m.color.withAlphaComponent(k).setStroke()
                p.move(to: pts[i - 1].0); p.line(to: pts[i].0); p.stroke()
            }
        }
        if m.drawing && m.tool == .laser {
            let g = pointer, r = m.width + 5
            m.color.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: g.x - r * 2, y: g.y - r * 2, width: r * 4, height: r * 4)).fill()
            m.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: g.x - r, y: g.y - r, width: r * 2, height: r * 2)).fill()
        }
    }

    func drawRipples(_ now: CFTimeInterval) {
        for (p, t0) in Model.shared.ripples {
            let k = CGFloat((now - t0) / 0.5); if k > 1 { continue }
            let r = 8 + 50 * k
            NSColor.systemYellow.withAlphaComponent(1 - k).setStroke()
            let c = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            c.lineWidth = 4; c.stroke()
        }
    }

    func drawHalo() {
        guard Model.shared.halo else { return }
        let g = pointer, r: CGFloat = 30
        let rect = NSRect(x: g.x - r, y: g.y - r, width: r * 2, height: r * 2)
        NSColor.systemYellow.withAlphaComponent(0.22).setFill(); NSBezierPath(ovalIn: rect).fill()
        NSColor.systemYellow.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(ovalIn: rect); ring.lineWidth = 2.5; ring.stroke()
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let m = Model.shared
    var windows: [(OverlayWindow, InkView)] = []
    var timer: Timer?
    var hotKeys: [EventHotKeyRef?] = []
    var statusItem: NSStatusItem!
    var haloItem: NSMenuItem!
    var spotItem: NSMenuItem!
    var spotSizeItems: [NSMenuItem] = []
    var previousApp: NSRunningApplication?
    var wasActive = false
    var lastMicCheck: CFTimeInterval = 0
    var lastSave: CFTimeInterval = 0
    var lastPomo: CFTimeInterval = 0
    let pomo = Pomodoro.shared
    var pomoPanel: PomoPanel!
    var pomoView: PomoView!
    var pomoShowItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        m.load(); pomo.load()
        buildWindows()
        (pomoPanel, pomoView) = makePomoPanel(
            onSettings: { [weak self] in self?.openPomoSettings() },
            onStats: { StatsWindow.shared.show() },
            onTag: { [weak self] in self?.editPomoTag() })
        if pomo.visible { pomoPanel.orderFrontRegardless() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildWindows() }
        registerHotKeys()
        buildMenu()
        let click: (NSEvent) -> Void = { [weak self] _ in
            if self?.m.halo == true { self?.m.ripples.append((NSEvent.mouseLocation, CACurrentMediaTime())) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: click)
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in click(e); return e }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    // 🟢 mic activo · 🔴 silenciado · ⚪ sin micrófono
    func updateTitle() {
        let light: String
        if let v = micVolume() { light = v > 0.001 ? "🟢" : "🔴" } else { light = "⚪" }
        let t = (m.drawing ? "✏️●" : "✏️") + light
        if statusItem.button?.title != t { statusItem.button?.title = t }
    }

    func tick() {
        let now = CACurrentMediaTime()
        if now - lastMicCheck > 0.3 { lastMicCheck = now; updateTitle() }
        if now - lastPomo > 0.2 || now < pomo.flashUntil {
            lastPomo = now; pomo.tick(); pomoView.needsDisplay = true
        }
        if now - lastSave > 1 { lastSave = now; m.save(); pomo.save(); StatsWindow.shared.refresh() }
        m.items.removeAll { $0.expired(now) }
        if m.drawing && m.tool == .laser {
            let g = NSEvent.mouseLocation
            if let l = m.trail.last?.0, hypot(l.x - g.x, l.y - g.y) < 1.5 {} else { m.trail.append((g, now)) }
        }
        m.trail.removeAll { now - $0.1 > trailLife }
        m.ripples.removeAll { now - $0.1 > 0.5 }
        let active = !m.items.isEmpty || !m.trail.isEmpty || !m.ripples.isEmpty || m.halo
            || m.spotlight || m.editing != nil || (m.drawing && m.tool == .laser)
        if active || wasActive { m.invalidate() }
        wasActive = active
    }

    func buildWindows() {
        windows.forEach { $0.0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = !m.drawing
            let v = InkView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            w.initialFirstResponder = v
            w.orderFrontRegardless()
            return (w, v)
        }
        m.views = windows.map { $0.1 }
    }

    func setDrawing(_ on: Bool) {
        if on == m.drawing { return }
        m.commitText()
        m.drawing = on
        if on {
            previousApp = NSWorkspace.shared.frontmostApplication
            let mouse = NSEvent.mouseLocation
            let target = windows.first { $0.0.frame.contains(mouse) } ?? windows.first
            m.toolbarFrame = target?.0.frame
            for (w, v) in windows {
                w.ignoresMouseEvents = false
                w.window_invalidate(v)
            }
            NSApp.activate(ignoringOtherApps: true)
            target?.0.makeKeyAndOrderFront(nil)
            if let t = target { t.0.makeFirstResponder(t.1) }
        } else {
            windows.forEach { $0.0.ignoresMouseEvents = true; $0.0.window_invalidate($0.1) }
            NSColorPanel.shared.orderOut(nil)
            m.current = nil
            if previousApp?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp?.activate() }
        }
        updateTitle()
        m.invalidate()
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✏️"
        let menu = NSMenu()
        func add(_ t: String, _ s: Selector) -> NSMenuItem {
            let i = menu.addItem(withTitle: t, action: s, keyEquivalent: ""); i.target = self; return i
        }
        _ = add("Dibujar  (⌃⌥D)", #selector(toggleDraw))
        _ = add("Puntero con estela  (⌃⌥L)", #selector(toggleLaser))
        haloItem = add("Halo del cursor  (⌃⌥H)", #selector(toggleHalo))
        haloItem.state = m.halo ? .on : .off
        spotItem = add("Spotlight del cursor  (⌃⌥F)", #selector(toggleSpotlight))
        let sizeMenu = NSMenu()
        for (i, n) in spotNames.enumerated() {
            let it = sizeMenu.addItem(withTitle: n, action: #selector(setSpotSize(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = i == m.spotSize ? .on : .off
            spotSizeItems.append(it)
        }
        let sizeParent = menu.addItem(withTitle: "Tamaño del spotlight", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu
        _ = add("Borrar todo  (⌃⌥C)", #selector(clear))
        _ = add("Nota rápida  (⌃⌥Q)", #selector(quickNote))
        menu.addItem(.separator())
        pomoShowItem = add("Mostrar pomodoro  (⌃⌥P)", #selector(togglePomoVisible))
        pomoShowItem.state = pomo.visible ? .on : .off
        _ = add("Iniciar / pausar pomodoro  (⌃⌥S)", #selector(pomoToggle))
        _ = add("Saltar fase  (⌃⌥N)", #selector(pomoSkip))
        _ = add("Tema de la sesión…", #selector(editPomoTag))
        _ = add("Estadísticas del pomodoro…", #selector(openStats))
        _ = add("Ajustes del pomodoro…", #selector(openPomoSettings))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func toggleDraw() { setDrawing(!m.drawing) }
    @objc func toggleLaser() {
        if m.drawing && m.tool == .laser { setDrawing(false); return }
        m.setTool(.laser); setDrawing(true)
    }
    @objc func toggleHalo() { m.halo.toggle(); haloItem.state = m.halo ? .on : .off; m.invalidate(); m.save() }
    @objc func clear() { m.clearAll() }
    @objc func toggleSpotlight() {
        m.spotlight.toggle(); spotItem.state = m.spotlight ? .on : .off; m.invalidate()
    }
    @objc func setSpotSize(_ item: NSMenuItem) {
        applySpotSize(item.tag)
    }
    func applySpotSize(_ i: Int) {
        m.spotSize = i
        spotSizeItems.forEach { $0.state = $0.tag == m.spotSize ? .on : .off }
        m.save(); m.invalidate()
    }
    func cycleSpotSize() { applySpotSize((m.spotSize + 1) % spotRadii.count) }
    @objc func quickNote() { QuickNote.shared.show() }

    // MARK: Pomodoro

    @objc func togglePomoVisible() {
        pomo.visible.toggle()
        if pomo.visible { pomoPanel.orderFrontRegardless() } else { pomoPanel.orderOut(nil) }
        pomoShowItem.state = pomo.visible ? .on : .off
        pomo.save()
    }
    @objc func pomoToggle() { pomo.toggle(); pomoView.needsDisplay = true }
    @objc func pomoSkip() { pomo.skip(); pomoView.needsDisplay = true }

    @objc func openStats() { StatsWindow.shared.show() }

    @objc func editPomoTag() {
        let f = NSTextField(string: pomo.tag)
        f.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        f.placeholderString = "Ej.: Matemáticas, Swift, Live de TikTok"
        let alert = NSAlert()
        alert.messageText = "Tema de la sesión"
        alert.informativeText = "Se guarda con cada foco para tus estadísticas. Déjalo vacío para quitarlo."
        alert.accessoryView = f
        alert.addButton(withTitle: "Guardar"); alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pomo.tag = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pomo.save(); pomoView.needsDisplay = true
    }

    @objc func openPomoSettings() {
        func field(_ v: Int) -> NSTextField { let f = NSTextField(string: "\(v)"); f.alignment = .right; return f }
        let fields = [field(pomo.focusMin), field(pomo.shortMin), field(pomo.longMin), field(pomo.cycle)]
        let names = ["Foco (min)", "Descanso corto (min)", "Descanso largo (min)", "Sesiones antes del largo"]
        let auto = NSButton(checkboxWithTitle: "Iniciar la siguiente fase automáticamente", target: nil, action: nil)
        auto.state = pomo.autoStart ? .on : .off
        let rows: [NSView] = zip(names, fields).map { n, f in
            let l = NSTextField(labelWithString: n)
            f.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let s = NSStackView(views: [l, f]); s.distribution = .equalSpacing; s.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return s
        } + [auto]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 140)
        let alert = NSAlert()
        alert.messageText = "Ajustes del pomodoro"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Guardar"); alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func val(_ f: NSTextField, _ def: Int) -> Int { min(max(Int(f.stringValue) ?? def, 1), 180) }
        pomo.focusMin = val(fields[0], 25); pomo.shortMin = val(fields[1], 5)
        pomo.longMin = val(fields[2], 15); pomo.cycle = val(fields[3], 4)
        pomo.autoStart = auto.state == .on
        if !pomo.running { pomo.remaining = pomo.duration(pomo.phase) }
        pomo.save(); pomoView.needsDisplay = true
    }

    func openColorPanel() {
        let p = NSColorPanel.shared
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.color = m.customColor
        p.setTarget(self); p.setAction(#selector(colorChanged(_:)))
        p.isContinuous = true
        p.orderFront(nil)
    }
    @objc func colorChanged(_ p: NSColorPanel) {
        m.customColor = p.color; m.colorIndex = -1; m.invalidate()
    }

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var id = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                guard let app = NSApp.delegate as? App else { return }
                switch id.id {
                case 1: app.toggleDraw()
                case 2: app.clear()
                case 3: app.toggleHalo()
                case 4: app.toggleLaser()
                case 5: app.togglePomoVisible()
                case 6: app.pomoToggle()
                case 7: app.pomoSkip()
                case 8: app.toggleSpotlight()
                case 9: app.quickNote()
                default: break
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey)
        for (i, key) in [kVK_ANSI_D, kVK_ANSI_C, kVK_ANSI_H, kVK_ANSI_L, kVK_ANSI_P, kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_F, kVK_ANSI_Q].enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5349_4E4B), id: UInt32(i + 1)),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }
}

extension NSWindow {
    func window_invalidate(_ v: NSView) { invalidateCursorRects(for: v); v.needsDisplay = true }
}

// Modo documentación: renderiza imágenes con datos de ejemplo y sale (sin ventanas, atajos ni datos reales).
if let i = CommandLine.arguments.firstIndex(of: "--render-docs"), i + 1 < CommandLine.arguments.count {
    renderDocs(to: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
