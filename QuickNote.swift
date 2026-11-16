// Nota rápida (⌃⌥Q): panel flotante con texto multilínea que guarda un .md en <vault>/Inbox.
import Cocoa

/// Carpeta del vault (se expande el ~). Solo se escribe dentro de <vault>/Inbox.
let noteVaultPath = "~/SegundoCerebro"

final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NoteTextView: NSTextView {
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    override func keyDown(with e: NSEvent) {
        let code = Int(e.keyCode)
        if (code == 36 || code == 76), !hasMarkedText() {      // Return / Enter del teclado numérico
            if e.modifierFlags.contains(.shift) { insertText("\n", replacementRange: selectedRange()) }
            else { onSave() }
            return
        }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) { onCancel() }   // Esc
}

final class QuickNote: NSObject {
    static let shared = QuickNote()
    private var panel: NotePanel?
    private var textView: NoteTextView?
    private var hint: NSTextField?
    private var previousApp: NSRunningApplication?
    private var closing = false

    func show() {
        if let p = panel, !closing {
            NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil)
            p.makeFirstResponder(textView); return
        }
        if closing { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let size = NSSize(width: 520, height: 160)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        let origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height / 3 - size.height / 2)

        let p = NotePanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow; bg.blendingMode = .behindWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 14; bg.layer?.masksToBounds = true

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 34, width: size.width - 28, height: size.height - 48))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let tv = NoteTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false; tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.textColor = .labelColor; tv.insertionPointColor = .labelColor
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.onSave = { [weak self] in self?.save() }
        tv.onCancel = { [weak self] in self?.close() }
        scroll.documentView = tv

        let h = NSTextField(labelWithString: "Nota rápida · Enter guarda · Shift+Enter nueva línea · Esc cancela")
        h.font = NSFont.systemFont(ofSize: 11); h.textColor = .secondaryLabelColor
        h.frame = NSRect(x: 16, y: 10, width: size.width - 32, height: 16)

        bg.addSubview(scroll); bg.addSubview(h)
        p.contentView = bg
        panel = p; textView = tv; hint = h; closing = false

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(tv)
    }

    private func save() {
        guard let tv = textView, !closing else { return }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }                       // no se guardan notas vacías
        if let err = QuickNote.write(text) {
            hint?.stringValue = "No se pudo guardar: \(err)"; hint?.textColor = .systemRed
            return
        }
        closing = true
        tv.isEditable = false
        hint?.stringValue = "Guardado en Inbox ✓"; hint?.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.close() }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil; textView = nil; hint = nil; closing = false
        previousApp?.activate()
        previousApp = nil
    }

    /// Escribe <vault>/Inbox/<YYYY-MM-DD HHmmss>.md. Devuelve un mensaje de error o nil.
    static func write(_ text: String) -> String? {
        let inbox = URL(fileURLWithPath: (noteVaultPath as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
        let now = Date()
        let nameFmt = DateFormatter()
        nameFmt.locale = Locale(identifier: "en_US_POSIX"); nameFmt.timeZone = .current
        nameFmt.dateFormat = "yyyy-MM-dd HHmmss"
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current; iso.formatOptions = [.withInternetDateTime]
        let content = "---\norigen: yo\ntipo: captura\ncreado: \(iso.string(from: now))\n---\n\n\(text)\n"
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            var url = inbox.appendingPathComponent(nameFmt.string(from: now) + ".md")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {      // nunca sobrescribe
                url = inbox.appendingPathComponent(nameFmt.string(from: now) + "-\(n).md"); n += 1
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch { return error.localizedDescription }
    }
}
