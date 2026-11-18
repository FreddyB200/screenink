// Música de foco: reproduce un archivo de audio local mientras corre una fase de FOCO del pomodoro.
// Solo archivos locales (AVAudioPlayer). Fundido de entrada/salida de 3 s, en bucle si el archivo es corto.
import Cocoa
import AVFoundation
import UniformTypeIdentifiers

final class FocusMusic {
    static let shared = FocusMusic()
    static let extensions = ["mp3", "m4a", "aac", "wav", "aiff", "aif"]
    static let fade: TimeInterval = 3

    // Ajustes persistidos en UserDefaults ("music.*")
    var enabled = false
    var path = ""
    var volume: Float = 0.5            // 0...1
    var resumeWhereLeft = true         // true: continuar donde quedó; false: empezar desde el inicio en cada foco
    private(set) var lastError: String?   // motivo por el que se desactivó (se muestra en los ajustes)

    private let d = UserDefaults.standard
    private var player: AVAudioPlayer?
    private var wantsPlay = false
    private var generation = 0          // invalida pausas diferidas si se vuelve a pedir reproducir
    private var rewindPending = false   // un foco terminó/se saltó/se reinició: el siguiente puede empezar de cero

    var fileName: String { path.isEmpty ? "" : (path as NSString).lastPathComponent }

    /// Lo llama la app al arrancar (no en `--render-docs`, que no debe leer ajustes reales).
    func load() {
        enabled = d.bool(forKey: "music.enabled")
        path = d.string(forKey: "music.path") ?? ""
        volume = Float(min(max(d.object(forKey: "music.volume") as? Double ?? 0.5, 0), 1))
        resumeWhereLeft = d.object(forKey: "music.resume") as? Bool ?? true
        if enabled { revalidate() }
    }

    func save() {
        d.set(enabled, forKey: "music.enabled"); d.set(path, forKey: "music.path")
        d.set(Double(volume), forKey: "music.volume"); d.set(resumeWhereLeft, forKey: "music.resume")
    }

    /// Comprueba que el archivo sigue existiendo; si no, desactiva la música y guarda el motivo.
    func revalidate() {
        guard !path.isEmpty else { lastError = nil; return }
        let name = fileName
        if !FileManager.default.fileExists(atPath: path) {
            fail("No se encuentra el archivo «\(name)». La música está desactivada; elige otro archivo.")
        } else if !FileManager.default.isReadableFile(atPath: path) {
            fail("No se puede leer el archivo «\(name)». La música está desactivada.")
        } else { lastError = nil }
    }

    private func fail(_ msg: String) {
        lastError = msg; enabled = false; player = nil; wantsPlay = false; save()
    }

    /// Intenta abrir el archivo como audio. Devuelve el reproductor o el mensaje de error.
    static func makePlayer(path: String) -> (AVAudioPlayer?, String?) {
        let name = (path as NSString).lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else { return (nil, "No se encuentra el archivo «\(name)».") }
        guard extensions.contains((path as NSString).pathExtension.lowercased()) else {
            return (nil, "«\(name)» no es un formato admitido (mp3, m4a, aac, wav, aiff).")
        }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.numberOfLoops = -1       // en bucle: cubre sesiones más largas que el archivo
            p.prepareToPlay()
            return (p, nil)
        } catch {
            return (nil, "No se pudo leer «\(name)» como audio.")
        }
    }

    /// Cambia el archivo elegido. Devuelve un mensaje si no es utilizable (y deja el anterior intacto).
    @discardableResult
    func setFile(_ newPath: String) -> String? {
        let (p, err) = FocusMusic.makePlayer(path: newPath)
        if let err = err { return err }
        player?.stop()
        player = p; path = newPath; lastError = nil
        wantsPlay = false; rewindPending = false
        save()
        return nil
    }

    // MARK: Reproducción

    /// Estado deseado según el pomodoro (corriendo + foco + sin silenciar). Idempotente.
    func update(shouldPlay: Bool) {
        if shouldPlay && enabled {
            generation += 1
            if player == nil {
                let (p, err) = FocusMusic.makePlayer(path: path)
                guard let p = p else { fail(err.map { $0 + " La música está desactivada." } ?? ""); return }
                player = p
            }
            guard let p = player else { return }
            let alreadyOn = wantsPlay && p.isPlaying
            if !p.isPlaying {
                if rewindPending && !resumeWhereLeft { p.currentTime = 0 }
                p.volume = 0
                p.play()
            }
            rewindPending = false
            p.setVolume(volume, fadeDuration: alreadyOn ? 0.3 : FocusMusic.fade)   // 0.3 s si solo cambió el volumen
            wantsPlay = true
        } else {
            guard wantsPlay || player?.isPlaying == true else { return }
            wantsPlay = false
            generation += 1
            let g = generation
            player?.setVolume(0, fadeDuration: FocusMusic.fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + FocusMusic.fade + 0.1) { [weak self] in
                guard let self = self, self.generation == g else { return }
                self.player?.pause()    // pausa (conserva la posición)
            }
        }
    }

    /// Un foco terminó, se saltó o se reinició: fundido de salida y, según el modo, el próximo empieza de cero.
    func focusDidEnd() {
        rewindPending = true
        update(shouldPlay: false)
    }
}

// MARK: - Sección "Música de foco" del diálogo de ajustes del pomodoro

final class FocusMusicSettings: NSObject {
    let view: NSStackView
    private let music = FocusMusic.shared
    private let enabledBox = NSButton(checkboxWithTitle: "Reproducir música en las sesiones de foco", target: nil, action: nil)
    private let fileLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volLabel = NSTextField(labelWithString: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var path: String
    private var valid: Bool

    override init() {
        music.revalidate()
        path = music.path
        valid = !music.path.isEmpty && music.lastError == nil
        view = NSStackView()
        super.init()

        let title = NSTextField(labelWithString: "Música de foco")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        enabledBox.state = music.enabled && valid ? .on : .off
        enabledBox.isEnabled = valid

        let choose = NSButton(title: "Elegir archivo…", target: self, action: #selector(chooseFile))
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let fileRow = NSStackView(views: [choose, fileLabel]); fileRow.spacing = 8

        slider.target = self; slider.action = #selector(sliderMoved)
        slider.doubleValue = Double(music.volume) * 100
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        volLabel.alignment = .right
        volLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let volRow = NSStackView(views: [NSTextField(labelWithString: "Volumen"), slider, volLabel]); volRow.spacing = 8

        modePopup.addItems(withTitles: ["Continuar donde quedó", "Empezar desde el inicio"])
        modePopup.selectItem(at: music.resumeWhereLeft ? 0 : 1)
        let modeRow = NSStackView(views: [NSTextField(labelWithString: "En el siguiente foco"), modePopup]); modeRow.spacing = 8

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.preferredMaxLayoutWidth = 300
        errorLabel.widthAnchor.constraint(equalToConstant: 300).isActive = true
        errorLabel.heightAnchor.constraint(equalToConstant: 30).isActive = true   // reserva 2 líneas: el diálogo no cambia de alto

        view.setViews([title, enabledBox, fileRow, volRow, modeRow, errorLabel], in: .top)
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        view.widthAnchor.constraint(equalToConstant: 300).isActive = true
        refresh(error: music.lastError)
    }

    private func refresh(error: String?) {
        fileLabel.stringValue = path.isEmpty ? "(ningún archivo)" : (path as NSString).lastPathComponent
        volLabel.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        errorLabel.stringValue = error ?? ""
    }

    @objc private func sliderMoved() { refresh(error: errorLabel.stringValue.isEmpty ? nil : errorLabel.stringValue) }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = FocusMusic.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Elige un archivo de audio (mp3, m4a, aac, wav, aiff)"
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let (_, err) = FocusMusic.makePlayer(path: url.path)
        if let err = err { refresh(error: err); return }
        path = url.path; valid = true
        enabledBox.isEnabled = true; enabledBox.state = .on
        refresh(error: nil)
    }

    /// Se llama al pulsar "Guardar" en el diálogo.
    func apply() {
        if valid && path != music.path { if music.setFile(path) != nil { valid = false } }
        music.enabled = valid && enabledBox.state == .on
        music.volume = Float(slider.doubleValue / 100)
        music.resumeWhereLeft = modePopup.indexOfSelectedItem == 0
        music.save()
    }
}
