// HexClipboard — yerel pano geçmişi (yazılar, linkler, görseller).
// Ağ kodu yoktur. Veriler ~/Belgeler/HexClipboard klasöründe durur.

import Cocoa
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import ApplicationServices

// MARK: - Kısayol

/// Kullanıcının atadığı kısayol (HexShot ile aynı yapı).
struct Shortcut: Equatable {
    var keyCode: UInt32
    var mods: UInt32 // Carbon modifier mask
    var key: String

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var dict: [String: Any] { ["k": Int(keyCode), "m": Int(mods), "l": key] }

    init(keyCode: UInt32, mods: UInt32, key: String) {
        self.keyCode = keyCode; self.mods = mods; self.key = key
    }

    init?(dict: Any?) {
        guard let d = dict as? [String: Any], let k = d["k"] as? Int, let m = d["m"] as? Int, let l = d["l"] as? String
        else { return nil }
        self.init(keyCode: UInt32(k), mods: UInt32(m), key: l)
    }

    static let fallback = Shortcut(keyCode: UInt32(kVK_ANSI_V), mods: UInt32(controlKey | cmdKey), key: "V")

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    static func keyName(_ e: NSEvent) -> String {
        let code = Int(e.keyCode)
        if let f = functionKeys[code] { return f }
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (e.characters(byApplyingModifiers: []) ?? "?").uppercased(with: Locale(identifier: "tr_TR"))
        }
    }
}

/// Carbon global kısayolu: Erişilebilirlik izni gerektirmez, tuş vuruşlarını dinlemez.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    static let defaultsKey = "hotkey.open"
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    /// Kısayol başka bir uygulamada kayıtlıysa true (ayarlarda uyarı gösterilir).
    private(set) var registrationFailed = false
    var onPress: (() -> Void)?

    /// nil → kısayol kapalı.
    var shortcut: Shortcut? {
        let d = UserDefaults.standard
        if let v = d.object(forKey: Self.defaultsKey) { return Shortcut(dict: v) } // "none" → nil
        // Önceki sürümün hazır seçeneklerinden taşı
        let mods: UInt32?
        switch d.string(forKey: "hotkeyPreset") {
        case "off": mods = nil
        case "shiftCmdV": mods = UInt32(shiftKey | cmdKey)
        case "optCmdV": mods = UInt32(optionKey | cmdKey)
        case "ctrlOptV": mods = UInt32(controlKey | optionKey)
        default: mods = UInt32(controlKey | cmdKey)
        }
        return mods.map { Shortcut(keyCode: UInt32(kVK_ANSI_V), mods: $0, key: "V") }
    }

    func set(_ s: Shortcut?) {
        UserDefaults.standard.set(s?.dict ?? "none", forKey: Self.defaultsKey)
        register()
    }

    func register() {
        unregister()
        installHandler()
        registrationFailed = false
        guard let s = shortcut else { return }
        var r: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4845_5843), id: 1) // 'HEXC'
        if RegisterEventHotKey(s.keyCode, s.mods, id, GetApplicationEventTarget(), 0, &r) == noErr {
            ref = r
        } else {
            registrationFailed = true
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in HotKeyCenter.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Tıklayıp yeni kısayola basılarak ayarlanan kutu. ⌫ kaldırır, Esc vazgeçer.
final class ShortcutField: NSView {
    var onChange: (() -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 26) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        p.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        p.lineWidth = 1
        p.stroke()
        let text = recording ? "Kısayola basın…" : (MainActor.assumeIsolated { HotKeyCenter.shared.shortcut?.display } ?? "Yok — tıklayıp atayın")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func becomeFirstResponder() -> Bool {
        recording = true
        MainActor.assumeIsolated { HotKeyCenter.shared.unregister() } // kayıt sırasında tetiklenmesin
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        MainActor.assumeIsolated { HotKeyCenter.shared.register() }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with e: NSEvent) {
        guard recording else { super.keyDown(with: e); return }
        let code = Int(e.keyCode)
        switch code {
        case kVK_Escape:
            window?.makeFirstResponder(nil)
            return
        case kVK_Delete, kVK_ForwardDelete:
            MainActor.assumeIsolated { HotKeyCenter.shared.set(nil) }
        default:
            let mods = Shortcut.carbonMods(e.modifierFlags)
            if Shortcut.functionKeys[code] == nil && mods & UInt32(cmdKey | controlKey | optionKey) == 0 {
                NSSound.beep() // ⌘, ⌃ veya ⌥ olmadan tek tuş kabul edilmez (F tuşları hariç)
                return
            }
            let s = Shortcut(keyCode: UInt32(code), mods: mods, key: Shortcut.keyName(e))
            MainActor.assumeIsolated { HotKeyCenter.shared.set(s) }
        }
        window?.makeFirstResponder(nil)
        onChange?()
    }
}

/// Ayarlar ekranında kullanılan SwiftUI sarmalayıcısı.
struct ShortcutRecorder: NSViewRepresentable {
    var token = 0 // değişince kutu yeniden çizilir
    var onChange: () -> Void = {}
    func makeNSView(context: Context) -> ShortcutField {
        let f = ShortcutField()
        f.onChange = onChange
        return f
    }
    func updateNSView(_ v: ShortcutField, context: Context) { v.needsDisplay = true }
}

// MARK: - Girişte başlat (HexShot ile aynı yaklaşım)

enum LoginItem {
    static let pathKey = "loginItemPath"
    static let wantedKey = "loginItemWanted"

    static var wanted: Bool { UserDefaults.standard.bool(forKey: wantedKey) }

    /// Uygulama taşındı ya da yeniden kurulduysa giriş öğesini tercihe göre yeniden kaydeder.
    @MainActor static func refreshLocationIfNeeded() {
        guard wanted else { return }
        let here = Bundle.main.bundlePath
        let svc = SMAppService.mainApp
        if svc.status == .enabled && UserDefaults.standard.string(forKey: pathKey) == here { return }
        if svc.status == .enabled { try? svc.unregister() }
        if (try? svc.register()) != nil { UserDefaults.standard.set(here, forKey: pathKey) }
    }

    @MainActor static func toggle() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: wantedKey)
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: wantedKey)
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: pathKey)
            }
        } catch {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// MARK: - Doğrudan yapıştırma

/// Seçilen öğeyi önceki uygulamaya yapıştırmak için yalnızca ⌘V tuşu gönderilir.
/// Erişilebilirlik izni ister; tuş vuruşu okunmaz, başka hiçbir şey yapılmaz.
enum Paster {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Etkin klavye düzeninde "v" harfini üreten tuş (Türkçe-F gibi düzenlerde konumu farklıdır).
    static func keyCodeForV() -> CGKeyCode {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return CGKeyCode(kVK_ANSI_V) }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return CGKeyCode(kVK_ANSI_V) }
            for code in 0..<UInt16(128) {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if st == noErr, len == 1, chars[0] == 0x76 { return CGKeyCode(code) } // "v"
            }
            return CGKeyCode(kVK_ANSI_V)
        }
    }

    static func pasteToFrontApp() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = keyCodeForV()
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: - Panel

/// Spotlight gibi: uygulamayı öne getirmeden açılır, böylece çalıştığınız uygulama odakta kalır.
final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let store: ClipStore
    let model: PanelModel
    var openSettings: () -> Void = {}
    private var panel: ClipPanel?
    private var keyMonitor: Any?
    private let hud = HUD()

    init(store: ClipStore) {
        self.store = store
        model = PanelModel(store: store)
        super.init()
        model.onChoose = { [weak self] item, copyOnly in self?.choose(item, copyOnly: copyOnly) }
        model.onOpenSettings = { [weak self] in self?.hide(); self?.openSettings() }
        model.onOpenFolder = { [weak self] in self?.hide(); self?.openFolder() }
        model.onEnablePaste = { [weak self] in
            UserDefaults.standard.set(true, forKey: Prefs.autoPasteKey)
            if !Paster.trusted { self?.hide(); Paster.requestTrust() }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func build() {
        let size = NSSize(width: 920, height: 600)
        let p = ClipPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                          backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        p.delegate = self

        // Bulanık, yuvarlak köşeli arka plan
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        p.contentView = effect
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleKey(e) ?? e }
        }
    }

    func toggle(near button: NSStatusBarButton?) {
        if isVisible { hide() } else { show(near: button) }
    }

    func show(near button: NSStatusBarButton? = nil) {
        releaseWork?.cancel()
        if panel == nil { build() }
        guard let p = panel else { return }
        var f = p.frame
        // Her zaman ekranın tam ortasında: menü simgesiyle açılırsa simgenin ekranında,
        // kısayolla ya da uygulama simgesiyle açılırsa farenin olduğu ekranda.
        do {
            let mouse = NSEvent.mouseLocation
            let screen = button?.window?.screen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let vis = screen?.visibleFrame {
                f.origin.x = vis.midX - f.width / 2
                f.origin.y = vis.midY - f.height / 2
            }
        }
        p.setFrame(f, display: false)
        model.onShow()
        p.makeKeyAndOrderFront(nil)
        p.invalidateShadow()
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        model.commitDraft()
        p.orderOut(nil)
        scheduleRelease()
    }

    // MARK: Bellek

    /// Panel kapandıktan sonra bu kadar saniye açılmazsa arayüzü bellekten tamamen bırakılır.
    /// (Hemen tekrar açarsanız beklemeden açılsın diye kısa bir süre tutulur.)
    static let releaseDelay: TimeInterval = 3
    private var releaseWork: DispatchWorkItem?

    private func scheduleRelease(after delay: TimeInterval = PanelController.releaseDelay) {
        releaseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.releaseUI() }
        releaseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Paneli, SwiftUI görünümlerini, klavye dinleyicisini ve küçük resim önbelleğini bırakır.
    /// Bir sonraki açılışta yeniden kurulur. Pano kaydı bundan etkilenmez.
    func releaseUI() {
        releaseWork?.cancel()
        guard let p = panel, !p.isVisible else { return }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        p.delegate = nil
        p.contentView = nil
        p.close()
        panel = nil
        ThumbCache.cache.removeAllObjects()
        // Serbest kalan belleği hemen sisteme geri ver (yoksa ayrılmış olarak kalabiliyor).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = malloc_zone_pressure_relief(nil, 0) }
    }

    func openFolder() {
        store.storage.ensureDirs()
        NSWorkspace.shared.activateFileViewerSelecting([store.storage.root])
    }

    /// Seçilen öğeyi panoya koyar; ayar açıksa önceki uygulamaya yapıştırır.
    func choose(_ item: ClipItem, copyOnly: Bool) {
        model.commitDraft()
        let current = store.items.first { $0.id == item.id } ?? item
        guard store.copyToPasteboard(current) else { model.flash("Kopyalanamadı"); return }
        let wantsPaste = !copyOnly && UserDefaults.standard.bool(forKey: Prefs.autoPasteKey)
        hide()
        if wantsPaste && Paster.trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.pasteToFrontApp() }
        } else {
            hud.show(wantsPaste ? "Kopyalandı · yapıştırma için izin gerekli" : "Kopyalandı")
        }
    }

    /// Klavye: panel açıkken çalışır. Düzenleme kutusu odaktayken yalnızca Esc yakalanır.
    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard let p = panel, p.isKeyWindow, e.window === p else { return e }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let cmd = mods.contains(.command)
        let code = Int(e.keyCode)
        let editing = (p.firstResponder as? NSTextView).map { !$0.isFieldEditor } ?? false

        if code == kVK_Escape {
            if model.clearPrompt { model.clearPrompt = false; return nil }
            if editing { model.commitDraft(); model.requestFocus(.search) }
            else if !model.search.isEmpty { model.search = "" }
            else { hide() }
            return nil
        }
        if editing {
            if cmd && code == kVK_Return { model.commitDraft(); model.requestFocus(.search); return nil }
            if cmd && e.charactersIgnoringModifiers == "s" { model.commitDraft(); return nil }
            return e
        }

        switch code {
        case kVK_DownArrow: model.move(1); return nil
        case kVK_UpArrow: model.move(-1); return nil
        case kVK_PageDown: model.move(8); return nil
        case kVK_PageUp: model.move(-8); return nil
        case kVK_Tab: model.cycleFilter(mods.contains(.shift) ? -1 : 1); return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let s = model.selected { choose(s, copyOnly: cmd) }
            return nil
        case kVK_Delete where cmd:
            if let s = model.selected { model.delete(s) }
            return nil
        default: break
        }

        guard cmd, let ch = e.charactersIgnoringModifiers?.lowercased() else { return e }
        if let n = Int(ch), (1...9).contains(n) {
            let v = model.visible
            if n <= v.count { choose(v[n - 1], copyOnly: false) }
            return nil
        }
        switch ch {
        case "p": if let s = model.selected { model.togglePin(s) }; return nil
        case "e":
            if model.selected.map({ $0.kind != .image }) == true { model.requestFocus(.editor) }
            return nil
        case "f": model.requestFocus(.search); return nil
        case ",": model.onOpenSettings(); return nil
        case "w": hide(); return nil
        default: return e
        }
    }

    /// Başka yere tıklanınca kapan.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let p = self?.panel, p.isVisible, !p.isKeyWindow, p.attachedSheet == nil else { return }
            self?.hide()
        }
    }

    #if HEXTEST
    var debugPanel: NSPanel? { panel }
    /// Test (--selftest): klavye olaylarını panele gönderip sonucu yazdırır.
    func selfTest(shelf: DropShelfController) {
        show()
        func key(_ code: Int, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            guard let p = panel else { return nil }
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: p.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))
            return e.flatMap { handleKey($0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var ok = true
            func check(_ name: String, _ cond: Bool) { print((cond ? "OK   " : "FAIL ") + name); if !cond { ok = false } }
            let v = self.model.visible
            check("panel anahtar pencere", self.panel?.isKeyWindow == true)
            check("ilk öğe seçili", self.model.selectedID == v.first?.id)
            if let p = self.panel, let vis = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame {
                check("ekranın ortasında", abs(p.frame.midX - vis.midX) < 2 && abs(p.frame.midY - vis.midY) < 2)
            }
            // Kısayol kaydedici: ⌥⌘K atanır, sonra eski değer geri konur.
            let saved = UserDefaults.standard.object(forKey: HotKeyCenter.defaultsKey)
            let field = ShortcutField(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
            let w = NSWindow(contentRect: field.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView?.addSubview(field)
            w.makeFirstResponder(field)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                        windowNumber: w.windowNumber, context: nil, characters: "˚",
                                        charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)) {
                field.keyDown(with: e)
            }
            check("kısayol atandı (\(HotKeyCenter.shared.shortcut?.display ?? "-"))", HotKeyCenter.shared.shortcut?.display == "⌥⌘K")
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: w.windowNumber, context: nil, characters: "k",
                                        charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)) {
                w.makeFirstResponder(field); field.keyDown(with: e); w.makeFirstResponder(nil)
            }
            check("tek harf reddedildi", HotKeyCenter.shared.shortcut?.display == "⌥⌘K")
            UserDefaults.standard.set(saved, forKey: HotKeyCenter.defaultsKey)
            if saved == nil { UserDefaults.standard.removeObject(forKey: HotKeyCenter.defaultsKey) }
            HotKeyCenter.shared.register()
            w.close()
            self.panel?.makeKeyAndOrderFront(nil)
            _ = key(kVK_DownArrow)
            check("↓ ikinci öğe", self.model.selectedID == v[1].id)
            _ = key(kVK_Tab, "\t")
            check("⇥ Yazılar grubu", self.model.filter == .text)
            _ = key(kVK_Tab, "\t", [.shift])
            check("⇧⇥ Tümü grubu", self.model.filter == .all)
            _ = key(kVK_DownArrow)
            let target = self.model.selected
            _ = key(kVK_Return, "\r", [.command])
            let pb = NSPasteboard.general
            let copied = target?.kind == .image ? pb.data(forType: .png) != nil : pb.string(forType: .string) == target?.text
            check("⌘↩ panoya kopyaladı", copied)
            check("panel kapandı", self.panel?.isVisible == false)
            self.show()
            let before = self.store.items.count
            let first = self.model.selected
            _ = key(kVK_Delete, "\u{7f}", [.command])
            check("⌘⌫ sildi", self.store.items.count == before - 1 && !self.store.items.contains { $0.id == first?.id })
            _ = key(kVK_ANSI_P, "p", [.command])
            check("⌘P sabitledi", self.model.selected?.pinned == true)
            _ = key(kVK_ANSI_P, "p", [.command])
            check("⌘P sabitlemeyi kaldırdı", self.model.selected?.pinned == false)
            self.model.search = "github"
            check("arama süzüyor", self.model.visible.count == 1 && self.model.selected?.kind == .link)
            _ = key(kVK_Escape, "\u{1b}")
            check("Esc aramayı temizledi", self.model.search.isEmpty && self.panel?.isVisible == true)
            _ = key(kVK_Escape, "\u{1b}")
            check("Esc paneli kapattı", self.panel?.isVisible == false)
            // Sürükle-bırak paneli: özel (geçici) panolarla bırakma taklidi
            func dropBoard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
                let pb = NSPasteboard(name: .init("local.hexclipboard.test.\(UUID().uuidString)"))
                pb.clearContents(); fill(pb); return pb
            }
            let n0 = self.store.items.count
            let r1 = shelf.simulateDrop(dropBoard { $0.setString("Sürüklenen yazı örneği", forType: .string) })
            check("bırakma paneli ekranın ortasında göründü", r1.shown)
            check("yazı bırakıldı → \(r1.kinds)", r1.kinds.contains("Yazılar") && self.store.items.count == n0 + 1)
            let r2 = shelf.simulateDrop(dropBoard { $0.writeObjects([NSURL(string: "https://example.org/drop")!]) })
            check("link bırakıldı → \(r2.kinds)", r2.kinds.contains("Linkler"))
            let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
                .representation(using: .png, properties: [:]) ?? Data()
            let r3 = shelf.simulateDrop(dropBoard { $0.setData(png, forType: .png) })
            check("görsel bırakıldı → \(r3.kinds)", r3.kinds.contains("Görseller"))
            let r4 = shelf.simulateDrop(dropBoard {
                $0.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
                $0.setString("parola123", forType: .string)
            })
            check("gizli içerik reddedildi → \(r4.kinds)", !self.store.items.contains { $0.text == "parola123" })
            let r5 = shelf.simulateDrop(dropBoard { $0.writeObjects([NSURL(fileURLWithPath: "/etc/hosts")]) })
            check("görsel olmayan dosya alınmadı → \(r5.kinds)", r5.kinds == "Bu içerik alınamadı")
            let img = FileManager.default.temporaryDirectory.appendingPathComponent("hexclip-test.png")
            try? png.write(to: img)
            check("görsel olmayan dosya sürüklenince panel açılmaz",
                  DropShelfController.hint(for: dropBoard { $0.writeObjects([NSURL(fileURLWithPath: "/etc/hosts")]) }).isEmpty)
            check("klasör sürüklenince panel açılmaz",
                  DropShelfController.hint(for: dropBoard { $0.writeObjects([NSURL(fileURLWithPath: NSHomeDirectory())]) }).isEmpty)
            check("görsel dosyası sürüklenince panel açılır",
                  DropShelfController.hint(for: dropBoard { $0.writeObjects([img as NSURL]) }) == [.image])
            try? FileManager.default.removeItem(at: img)
            self.hide()
            self.show(near: (NSApp.delegate as? AppDelegate)?.statusButton)
            if let p = self.panel, let vis = (self.panel?.screen ?? NSScreen.main)?.visibleFrame {
                check("menü simgesiyle açınca da ortada", abs(p.frame.midX - vis.midX) < 2 && abs(p.frame.midY - vis.midY) < 2)
            }
            self.hide()
            check("tür tahmini (dosya→görsel, url→link)",
                  DropShelfController.guess([.fileURL]) == [.image] && DropShelfController.guess([.URL, .string]) == [.link])
            // Alt çubuktan temizleme
            self.show()
            self.model.clearPrompt = true
            _ = key(kVK_Escape, "\u{1b}")
            check("Esc temizleme satırını kapattı, panel açık", !self.model.clearPrompt && self.panel?.isVisible == true)
            self.model.filter = .link
            let links = self.store.count(.link), others = self.store.items.count - links
            self.model.clearPrompt = true
            self.model.clear(.link)
            check("Linkler grubu temizlendi, diğerleri duruyor", self.store.count(.link) == 0 && self.store.items.count == others)
            self.model.clear(.all)
            check("Tümü temizlendi", self.store.items.isEmpty && !self.model.clearPrompt)
            self.hide()
            print(ok ? "SONUÇ: hepsi geçti" : "SONUÇ: hata var")
            self.store.saveNow()
            exit(ok ? 0 : 1)
        }
    }

    /// Test: panelin içeriğini PNG olarak kaydeder.
    func snapshot(to path: String) {
        show()
        if let panel { Snapshot.write(panel, to: path) }
    }
    #endif
}

/// Panel kapandıktan sonra kısa bir "Kopyalandı" bildirimi.
@MainActor
final class HUD {
    private var window: NSPanel?
    private var work: DispatchWorkItem?

    func show(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 56, height: 36)

        let w = window ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            return p
        }()
        window = w

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemGreen
        icon.frame = NSRect(x: 16, y: 9, width: 18, height: 18)
        label.frame.origin = NSPoint(x: 40, y: (size.height - label.frame.height) / 2)
        effect.addSubview(icon)
        effect.addSubview(label)
        w.contentView = effect

        let mouse = NSEvent.mouseLocation
        let vis = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        w.setFrame(NSRect(x: vis.midX - size.width / 2, y: vis.minY + 90, width: size.width, height: size.height), display: true)
        w.alphaValue = 1
        w.orderFrontRegardless()

        work?.cancel()
        let job = DispatchWorkItem { [weak w] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w?.animator().alphaValue = 0 },
                                                 completionHandler: { w?.orderOut(nil) })
        }
        work = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: job)
    }
}

#if HEXTEST
/// Yalnızca test içindir (--snapshot): kendi penceremizi dosyaya çizer, ekran kaydı izni gerekmez.
enum Snapshot {
    @MainActor static func write(_ window: NSWindow, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let v = window.contentView?.superview ?? window.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

/// Ayarlar penceresi; kapatılınca bellekten tamamen bırakılır.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let store: ClipStore
    var openFolder: () -> Void = {}
    private var window: NSWindow?

    init(store: ClipStore) { self.store = store }

    func show() {
        if window == nil {
            let view = SettingsView(store: store, openFolder: { [weak self] in self?.openFolder() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "HexClipboard Ayarları"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Pencere kapanış işlemini bitirsin, sonra bırak.
        DispatchQueue.main.async { [weak self] in
            self?.window?.delegate = nil
            self?.window?.contentViewController = nil
            self?.window = nil
        }
    }

    func release() {
        guard let w = window, !w.isVisible else { return }
        w.delegate = nil
        w.contentViewController = nil
        window = nil
    }
}

// MARK: - Uygulama

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store: ClipStore
    let monitor: PasteboardMonitor
    let main: PanelController
    let settings: SettingsWindowController
    let shelf: DropShelfController
    private var statusItem: NSStatusItem!
    private var contextMenu: NSMenu!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    override init() {
        Prefs.registerDefaults()
        store = ClipStore()
        monitor = PasteboardMonitor(store: store)
        main = PanelController(store: store)
        settings = SettingsWindowController(store: store)
        shelf = DropShelfController(monitor: monitor)
        super.init()
        main.openSettings = { [weak self] in self?.settings.show() }
        settings.openFolder = { [weak self] in self?.main.openFolder() }
    }

    /// macOS "bellek azaldı" dediğinde kapalı arayüzleri ve önbellekleri hemen bırak.
    private var memoryPressure: DispatchSourceMemoryPressure?
    private func watchMemoryPressure() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                ThumbCache.cache.removeAllObjects()
                self?.main.releaseUI()
                self?.settings.release()
                self?.shelf.releaseUI()
            }
        }
        src.resume()
        memoryPressure = src
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        watchMemoryPressure()
        buildMainMenu()
        buildStatusItem()
        shelf.isOwnDrag = { [weak self] in self?.main.isVisible ?? false }
        startTicker()
        HotKeyCenter.shared.onPress = { [weak self] in
            guard let self else { return }
            if self.main.isVisible { self.main.hide() } else { self.main.show() }
        }
        HotKeyCenter.shared.register()
        LoginItem.refreshLocationIfNeeded()

        #if HEXTEST
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { main.snapshot(to: args[i + 1]) }
        if args.contains("--show") { main.show() }
        if args.contains("--selftest") { main.selfTest(shelf: shelf) }
        if args.contains("--stresstest") { StressTest.run() }
        if args.contains("--gen-data") { MemTest.generate(store: store) }
        if args.contains("--memtest") { MemTest.run(main: main, store: store) }
        if let i = args.firstIndex(of: "--snapshot-shelf"), i + 1 < args.count { shelf.snapshot(to: args[i + 1]) }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            settings.show()
            if let w = NSApp.windows.first(where: { $0.title == "HexClipboard Ayarları" }) { Snapshot.write(w, to: args[i + 1]) }
        }
        #endif
    }

    var statusButton: NSStatusBarButton? { statusItem?.button }

    /// Tek zamanlayıcı: sürükleme her 0,25 sn, pano her 0,5 sn kontrol edilir (yalnızca sayaçlar okunur).
    private var ticker: Timer?
    private var tick = 0
    private func startTicker() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick &+= 1
                self.shelf.poll()
                if self.tick % 2 == 0 { self.monitor.check() }
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func applicationWillTerminate(_ notification: Notification) { store.saveNow() }

    /// Uygulamaya Finder/Launchpad'den tekrar tıklanınca pencereyi aç.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main.show() // ekranın ortasında
        return false
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "HexClipboard'dan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Düzen")
        edit.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); menu.addItem(winItem)
        let win = NSMenu(title: "Pencere")
        win.addItem(withTitle: "Kapat", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = menu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "HexClipboard")
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let m = NSMenu()
        m.delegate = self
        m.addItem(menuItem("Geçmişi aç", #selector(openMain)))
        m.addItem(.separator())
        pauseItem = menuItem("Kaydı duraklat", #selector(togglePause))
        m.addItem(pauseItem)
        loginItem = menuItem("Girişte başlat", #selector(toggleLogin))
        m.addItem(loginItem)
        m.addItem(menuItem("Klasörü aç", #selector(openFolder)))
        m.addItem(menuItem("Ayarlar…", #selector(openSettings), key: ","))
        m.addItem(.separator())
        m.addItem(menuItem("HexClipboard'dan çık", #selector(quit), key: "q"))
        contextMenu = m
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.state = store.paused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func menuDidClose(_ menu: NSMenu) { statusItem.menu = nil }

    /// Sol tık: geçmiş penceresi. Sağ tık (veya ⌃ tık): menü.
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            statusItem.menu = contextMenu
            sender.performClick(nil)
        } else {
            main.toggle(near: sender)
        }
    }

    @objc private func openMain() { main.show(near: statusItem.button) }
    @objc private func togglePause() { store.paused.toggle() }
    @objc private func toggleLogin() { LoginItem.toggle() }
    @objc private func openFolder() { main.openFolder() }
    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
