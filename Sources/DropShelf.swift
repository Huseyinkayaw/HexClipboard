// HexClipboard — sürükleyince beliren bırakma paneli.
//
// Nasıl çalışır: macOS'ta herhangi bir uygulamada bir şey sürüklenmeye başlayınca sistemin
// "sürükleme panosu" (NSPasteboard .drag) değişir. Bu sayaç sol tuş basılıyken değişirse panel
// ekranın üst ortasında belirir. Fare ya da klavye olayları dinlenmez, ek izin gerekmez;
// panoya yalnızca siz bir şeyi panelin üstüne bıraktığınızda bakılır.

import Cocoa
import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class ShelfModel {
    enum State: Equatable { case waiting, hover, done(String), failed(String) }
    var state: State = .waiting
    var hint: [Kind] = []
}

/// Sürüklenen içeriği kabul eden görünüm.
final class DropView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onDrop: (NSPasteboard) -> Bool = { _ in false }

    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .string, .png, .tiff, .init("public.jpeg"), .init("public.heic"), .rtf, .html,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.acceptedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onEnter(); return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onExit() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop(sender.draggingPasteboard) }
}

struct ShelfView: View {
    @Bindable var model: ShelfModel

    private var hovering: Bool { model.state == .hover }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(iconTint.opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .scaleEffect(hovering ? 1.12 : 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(Kind.allCases) { k in
                        let on = model.hint.contains(k)
                        Label(k.title, systemImage: k.symbol)
                            .font(.system(size: 10, weight: on ? .semibold : .regular))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 380, height: 92)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.18),
                              style: StrokeStyle(lineWidth: hovering ? 2 : 1.2, dash: hovering ? [] : [6, 4]))
                .padding(4)
        )
        .animation(.easeOut(duration: 0.15), value: model.state)
    }

    private var title: String {
        switch model.state {
        case .waiting: "HexClipboard'a bırak"
        case .hover: "Bırakın, kaydedilsin"
        case .done(let s): s
        case .failed(let s): s
        }
    }

    private var icon: String {
        switch model.state {
        case .waiting: "tray.and.arrow.down"
        case .hover: "tray.and.arrow.down.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var iconTint: Color {
        switch model.state {
        case .done: .green
        case .failed: .orange
        default: .accentColor
        }
    }
}

@MainActor
final class DropShelfController {
    private let monitor: PasteboardMonitor
    private let model = ShelfModel()
    private var panel: NSPanel?
    private var lastDragCount = NSPasteboard(name: .drag).changeCount
    private var dragActive = false
    private var hideWork: DispatchWorkItem?
    /// Kendi panelimizden dışarı sürüklerken belirmesin.
    var isOwnDrag: () -> Bool = { false }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: Prefs.dragShelfKey) }

    init(monitor: PasteboardMonitor) { self.monitor = monitor }

    /// Uygulamanın ortak zamanlayıcısından çağrılır.
    func poll() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if dragActive {
            if !buttonDown { dragEnded() }
            return
        }
        let pb = NSPasteboard(name: .drag)
        let c = pb.changeCount
        guard c != lastDragCount else { return }
        lastDragCount = c
        guard buttonDown, Self.enabled, !isOwnDrag() else { return }

        let types = pb.types ?? []
        let raw = Set(types.map(\.rawValue))
        if raw.contains(ClipStore.markerType.rawValue) { return }
        if !raw.isDisjoint(with: PasteboardMonitor.skipTypes) { return } // parola vb.
        let hint = Self.hint(for: pb)
        guard !hint.isEmpty else { return }
        dragActive = true
        show(hint: hint)
    }

    /// Sürüklenen şey kaydedilebilir mi? Dosyalarda yalnızca adlarına (uzantı) bakılır,
    /// içerikleri okunmaz; görsel olmayan dosyalar için panel hiç açılmaz.
    static func hint(for pb: NSPasteboard) -> [Kind] {
        let types = pb.types ?? []
        if types.contains(.fileURL) {
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let hasImage = urls.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            return hasImage ? [.image] : []
        }
        return guess(types)
    }

    /// Yalnızca türlere bakarak (içerik okunmadan) neyin bırakılabileceğini tahmin eder.
    static func guess(_ types: [NSPasteboard.PasteboardType]) -> [Kind] {
        let raw = Set(types.map(\.rawValue))
        var k: [Kind] = []
        if types.contains(.fileURL) { return [.image] } // dosyalardan yalnızca görseller alınır
        if types.contains(.png) || types.contains(.tiff) || raw.contains("public.jpeg") || raw.contains("public.heic") {
            k.append(.image)
        }
        if types.contains(.URL) { k.append(.link) }
        if types.contains(.string) && !k.contains(.link) { k.append(.text) }
        return k
    }

    private func build() {
        let size = NSSize(width: 380, height: 92)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let drop = DropView(frame: effect.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onEnter = { [weak self] in MainActor.assumeIsolated { self?.model.state = .hover } }
        drop.onExit = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.state == .hover else { return }
                self.model.state = .waiting
            }
        }
        drop.onDrop = { [weak self] pb in
            MainActor.assumeIsolated { self?.receive(pb) ?? false }
        }
        let host = NSHostingView(rootView: ShelfView(model: model))
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        effect.addSubview(drop)
        p.contentView = effect
        panel = p
    }

    func show(hint: [Kind]) {
        if panel == nil { build() }
        guard let p = panel else { return }
        hideWork?.cancel()
        model.state = .waiting
        model.hint = hint
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        // Ekranın tam ortasında
        let f = NSRect(x: vis.midX - p.frame.width / 2, y: vis.midY - p.frame.height / 2,
                       width: p.frame.width, height: p.frame.height)
        p.setFrame(f.offsetBy(dx: 0, dy: -8), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
            p.animator().setFrame(f, display: true)
        }
    }

    private func receive(_ pb: NSPasteboard) -> Bool {
        let raw = Set((pb.types ?? []).map(\.rawValue))
        guard raw.isDisjoint(with: PasteboardMonitor.skipTypes) else {
            model.state = .failed("Gizli içerik kaydedilmez")
            return false
        }
        let kinds = monitor.ingest(pb, source: "Sürükle-bırak")
        if kinds.isEmpty {
            model.state = .failed("Bu içerik alınamadı")
            return false
        }
        let names = Set(kinds).sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", ")
        model.state = .done("\(names) grubuna kaydedildi")
        return true
    }

    private func dragEnded() {
        dragActive = false
        lastDragCount = NSPasteboard(name: .drag).changeCount
        let finished: Bool
        switch model.state {
        case .done, .failed: finished = true
        default: finished = false
        }
        hide(after: finished ? 1.1 : 0.15)
    }

    /// Gizliyken bırakma panelini bellekten bırakır (bir sonraki sürüklemede yeniden kurulur).
    func releaseUI() {
        guard let p = panel, !p.isVisible else { return }
        p.contentView = nil
        p.close()
        panel = nil
    }

    private func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                p.orderOut(nil)
                MainActor.assumeIsolated { self?.releaseUI() } // her sürüklemeden sonra bırak
            })
        }
        hideWork = job
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }

    #if HEXTEST
    /// Test için: paneli "görsel + link" ipucuyla gösterip PNG kaydeder.
    func snapshot(to path: String) {
        show(hint: [.image, .link])
        if let panel { Snapshot.write(panel, to: path) }
    }

    /// Test için: paneli gösterir ve verilen panoyu bırakılmış gibi işler.
    func simulateDrop(_ pb: NSPasteboard) -> (shown: Bool, kinds: String) {
        show(hint: Self.guess(pb.types ?? []))
        _ = receive(pb)
        var shown = panel?.isVisible == true
        if let p = panel, let vis = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame {
            let target = NSPoint(x: vis.midX, y: vis.midY)
            shown = shown && abs(p.frame.midX - target.x) < 2 && abs(p.frame.midY - target.y) < 10
        }
        var text = ""
        if case .done(let s) = model.state { text = s }
        if case .failed(let s) = model.state { text = s }
        hide(after: 0.1)
        return (shown, text)
    }
    #endif
}
