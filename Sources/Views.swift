// HexClipboard — arayüz: hızlı panel (arama + gruplar + liste + önizleme) ve ayarlar.

import SwiftUI
import ImageIO
import ServiceManagement

/// Komut satırı araçlarında SwiftUI makro eklentisi yok; @State makrosu yerine
/// klasik property wrapper doğrudan kullanılır (davranış aynıdır).
typealias ViewState<T> = SwiftUI.State<T>

// MARK: - Yardımcılar

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.unitsStyle = .short
        return f
    }()

    static func when(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 10 { return "şimdi" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Listede görünen tek satırlık başlık.
    static func title(_ item: ClipItem) -> String {
        switch item.kind {
        case .image:
            if let w = item.width, let h = item.height { return "Görsel  \(w)×\(h)" }
            return "Görsel"
        case .link:
            return host(item.text ?? "") ?? (item.text ?? "")
        case .text:
            // Çok uzun metinlerin tamamını taramamak için yalnızca başına bakılır.
            let s = String((item.text ?? "").prefix(2000))
            let line = s.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let one = String(line ?? "").trimmingCharacters(in: .whitespaces)
            return one.count > 200 ? String(one.prefix(200)) : one
        }
    }

    static func subtitle(_ item: ClipItem) -> String {
        if item.kind == .link, let t = item.text {
            return t.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        }
        var parts = [when(item.date)]
        if let s = item.sourceApp, !s.isEmpty { parts.append(s) }
        return parts.joined(separator: " · ")
    }

    static func linkURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: t.lowercased().hasPrefix("www.") ? "https://" + t : t)
    }

    /// Yalnızca web ve e-posta adresleri açılır; file://, uygulama şemaları vb. asla.
    static func safeOpenURL(_ s: String) -> URL? {
        guard let u = linkURL(s), let scheme = u.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme != "mailto" && (u.host ?? "").isEmpty { return nil }
        return u
    }

    static func host(_ s: String) -> String? {
        if s.lowercased().hasPrefix("mailto:") { return String(s.dropFirst(7)) }
        guard let h = linkURL(s)?.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// "#1E90FF" gibi renk kodlarını tanır ve rengini gösterir.
    static func hexColor(_ s: String?) -> Color? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), t.hasPrefix("#") else { return nil }
        t.removeFirst()
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6 || t.count == 8, let v = UInt64(t, radix: 16) else { return nil }
        let rgb = t.count == 8 ? v >> 8 : v
        let a = t.count == 8 ? Double(v & 0xFF) / 255 : 1
        return Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255, opacity: a)
    }

    static func stats(_ s: String) -> String {
        // Çok uzun metinlerde her tuş vuruşunda kelime saymak yavaşlatır.
        if s.utf16.count > 200_000 { return "\(s.count) karakter" }
        let words = s.split { $0.isWhitespace || $0.isNewline }.count
        let lines = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return "\(s.count) karakter · \(words) kelime · \(lines) satır"
    }
}

/// Küçük resim önbelleği: kaydırırken ve panel her açıldığında yeniden çözülmesin.
enum ThumbCache {
    nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // Kesin üst sınır: en fazla 200 küçük resim / 24 MB. Panel kapanınca tamamen boşaltılır.
        c.countLimit = 200
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()
}

/// Görselleri arka planda, küçültülmüş olarak yükler.
struct Thumbnail: View {
    let url: URL
    let revision: Int
    var maxPixel: Int = 120
    var fill = false
    @ViewState private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Color.secondary.opacity(0.08)
            }
        }
        .task(id: "\(url.path)#\(revision)#\(maxPixel)") {
            let key = "\(url.lastPathComponent)#\(revision)#\(maxPixel)" as NSString
            if let hit = ThumbCache.cache.object(forKey: key) { image = hit; return }
            let u = url, px = maxPixel
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(u as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: px,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
            if let cg {
                let img = NSImage(cgImage: cg, size: .zero)
                ThumbCache.cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
                image = img
            }
        }
    }
}

/// Paneldeki tüm düğmeler için tek stil: hepsi 28 pt yükseklikte, simgeler 13 pt.
struct HexButtonStyle: ButtonStyle {
    enum Tone { case normal, primary, danger, subtle }
    var tone: Tone = .normal
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        HexButtonBody(configuration: configuration, tone: tone, iconOnly: iconOnly)
    }
}

private struct HexButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: HexButtonStyle.Tone
    let iconOnly: Bool
    @ViewState private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .labelStyle(HexLabelStyle())
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, iconOnly ? 0 : 11)
            .frame(width: iconOnly ? 28 : nil, height: 28)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hover = $0 }
    }

    private var foreground: Color {
        switch tone {
        case .primary: .white
        case .danger: hover ? .white : .red
        case .subtle: hover ? .primary : .secondary
        case .normal: .primary
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch tone {
        case .primary: return Color.accentColor.opacity(pressed ? 0.75 : (hover ? 0.9 : 1))
        case .danger: return hover ? Color.red.opacity(pressed ? 0.75 : 0.9) : Color.red.opacity(0.12)
        case .subtle: return Color.primary.opacity(pressed ? 0.14 : (hover ? 0.08 : 0))
        case .normal: return Color.primary.opacity(pressed ? 0.16 : (hover ? 0.12 : 0.07))
        }
    }
}

struct HexLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 13, weight: .medium)).frame(width: 16, height: 16)
            configuration.title
        }
    }
}

/// Yalnızca simgeli düğme; tüm simge düğmeleri aynı ölçüdedir.
struct IconButton: View {
    let symbol: String
    let help: String
    var tone: HexButtonStyle.Tone = .normal
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 16, height: 16)
        }
        .buttonStyle(HexButtonStyle(tone: tone, iconOnly: true))
        .help(help)
    }
}

struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Panel modeli

enum Filter: String, CaseIterable, Identifiable {
    case all, text, link, image
    var id: String { rawValue }
    var kind: Kind? {
        switch self {
        case .all: nil
        case .text: .text
        case .link: .link
        case .image: .image
        }
    }
    var title: String {
        switch self {
        case .all: "Tümü"
        case .text: "Yazılar"
        case .link: "Linkler"
        case .image: "Görseller"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        }
    }
}

enum FocusField: Hashable { case search, editor }

@MainActor @Observable
final class PanelModel {
    let store: ClipStore
    var filter: Filter = .all {
        didSet { if filter != oldValue { commitDraft(); selectFirst() } }
    }
    var search = "" {
        didSet { if search != oldValue { selectFirst() } }
    }
    private(set) var selectedID: UUID?
    var draft = ""
    @ObservationIgnored private var draftFor: UUID?
    var focus: FocusField = .search
    var focusToken = 0
    var toast: String?
    /// Alt çubukta "neyi temizleyelim?" satırı açık mı?
    var clearPrompt = false

    // Denetleyicinin bağladığı işlemler
    @ObservationIgnored var onChoose: (ClipItem, _ copyOnly: Bool) -> Void = { _, _ in }
    @ObservationIgnored var onOpenSettings: () -> Void = {}
    @ObservationIgnored var onOpenFolder: () -> Void = {}
    @ObservationIgnored var onEnablePaste: () -> Void = {}

    init(store: ClipStore) {
        self.store = store
        #if HEXTEST
        let a = CommandLine.arguments // test: --tab all|text|link|image
        if let i = a.firstIndex(of: "--tab"), i + 1 < a.count, let f = Filter(rawValue: a[i + 1]) { filter = f }
        #endif
    }

    @ObservationIgnored private var cacheKey = ""
    @ObservationIgnored private var cacheValue: [ClipItem] = []

    /// Süzülmüş liste. Liste, grup ve arama değişmedikçe yeniden hesaplanmaz.
    var visible: [ClipItem] {
        let key = "\(store.version)|\(filter.rawValue)|\(search)"
        if key == cacheKey { return cacheValue }
        let all = store.items(filter.kind)
        let q = search.trimmingCharacters(in: .whitespaces)
        let result: [ClipItem]
        if q.isEmpty {
            result = all
        } else {
            let tr = Locale(identifier: "tr_TR")
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            func has(_ t: String?) -> Bool {
                guard let t else { return false }
                // Çok uzun metinlerde yalnızca ilk 50.000 karakterde aranır.
                let head = t.utf16.count > 50_000 ? String(t.prefix(50_000)) : t
                return head.range(of: q, options: opts, range: nil, locale: tr) != nil
            }
            result = all.filter {
                has($0.text) || has($0.sourceApp) || ($0.kind == .image && has("görsel resim image"))
            }
        }
        cacheKey = key
        cacheValue = result
        return result
    }

    var selected: ClipItem? {
        guard let id = selectedID else { return nil }
        return store.items.first { $0.id == id }
    }

    var draftChanged: Bool {
        guard let s = selected, s.kind != .image, draftFor == s.id else { return false }
        return draft != (s.text ?? "")
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        commitDraft()
        selectedID = id
        loadDraft()
    }

    func selectFirst() { select(visible.first?.id) }

    func ensureSelection() {
        let v = visible
        if let id = selectedID, v.contains(where: { $0.id == id }) { return }
        select(v.first?.id)
    }

    func move(_ delta: Int) {
        let v = visible
        guard !v.isEmpty else { return }
        let i = v.firstIndex { $0.id == selectedID } ?? -1
        select(v[min(max(i + delta, 0), v.count - 1)].id)
    }

    func cycleFilter(_ delta: Int) {
        let all = Filter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + delta + all.count) % all.count]
    }

    func requestFocus(_ f: FocusField) {
        focus = f
        focusToken += 1
    }

    private func loadDraft() {
        draft = selected?.text ?? ""
        draftFor = selectedID
    }

    /// Yazı/link düzenlemesi otomatik kaydedilir (seçim değişince, panel kapanınca).
    func commitDraft() {
        guard let id = draftFor, let item = store.items.first(where: { $0.id == id }), item.kind != .image else { return }
        if draft != (item.text ?? ""), !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.updateText(item, to: draft)
            flash("Kaydedildi")
        }
    }

    func revertDraft() { loadDraft() }

    func delete(_ item: ClipItem) {
        let before = visible
        let i = before.firstIndex { $0.id == item.id }
        if draftFor == item.id { draftFor = nil }
        store.delete(item)
        let after = visible
        selectedID = nil
        if after.isEmpty { loadDraft(); return }
        select(after[min(i ?? 0, after.count - 1)].id)
    }

    func togglePin(_ item: ClipItem) {
        store.togglePin(item)
        flash(store.items.first { $0.id == item.id }?.pinned == true ? "Sabitlendi" : "Sabitleme kaldırıldı")
    }

    func flash(_ s: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.toast == s else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
        }
    }

    /// Alt çubuktan temizleme. Ayarlardaki "sabitlenenleri koru" tercihine uyar.
    func clear(_ f: Filter) {
        let keep = UserDefaults.standard.bool(forKey: Prefs.keepPinnedKey)
        draftFor = nil
        store.clear(f.kind, keepPinned: keep)
        clearPrompt = false
        selectedID = nil
        selectFirst()
        loadDraft()
        flash(f == .all ? "Tümü temizlendi" : "\(f.title) temizlendi")
    }

    func onShow() {
        clearPrompt = false
        search = ""
        selectedID = nil
        selectFirst()
        requestFocus(.search)
    }
}

// MARK: - Panel

struct PanelView: View {
    @Bindable var model: PanelModel
    @FocusState private var focused: FocusField?
    @AppStorage(Prefs.autoPasteKey) private var autoPaste = false
    @AppStorage(Prefs.pasteTipDismissedKey) private var tipDismissed = false

    var body: some View {
        let items = model.visible
        VStack(spacing: 0) {
            searchBar
            if let p = model.store.problem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(p).font(.system(size: 11.5)).lineLimit(2)
                    Spacer()
                    IconButton(symbol: "xmark", help: "Kapat", tone: .subtle) { model.store.problem = nil }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
            }
            chips
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                list(items).frame(width: 380)
                Divider().opacity(0.6)
                PreviewPane(model: model, focused: $focused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 920, height: 600)
        .overlay(alignment: .top) {
            if let t = model.toast {
                Label(t, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thickMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.top, 64)
                    .transition(.opacity)
            }
        }
        .onChange(of: model.focusToken) { focused = model.focus }
        .onChange(of: focused) { if let f = focused { model.focus = f } }
        .onAppear { focused = .search }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Panoda ara…", text: $model.search)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused, equals: .search)
            if model.store.paused {
                Button { model.store.paused = false } label: {
                    Label("Duraklatıldı", systemImage: "pause.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Kayıt duraklatıldı — tıklayınca devam eder")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { f in
                let on = model.filter == f
                let n = f.kind.map(model.store.count) ?? model.store.items.count
                Button { model.filter = f } label: {
                    HStack(spacing: 5) {
                        Image(systemName: f.symbol).font(.system(size: 11, weight: .semibold))
                        Text(f.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        Text("\(n)").font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            KeyHint(key: "⇥", label: "grup değiştir")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func list(_ items: [ClipItem]) -> some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.search.isEmpty ? model.filter.symbol : "magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.search.isEmpty ? "Henüz bir şey yok" : "Sonuç bulunamadı").foregroundStyle(.secondary)
                    if model.search.isEmpty {
                        Text("Herhangi bir yerde ⌘C yapın, burada görünür.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                Row(item: item, index: i, selected: item.id == model.selectedID,
                                    revision: model.store.imageRevision, store: model.store)
                                    .id(item.id)
                                    .onTapGesture(count: 2) { model.onChoose(item, false) }
                                    .simultaneousGesture(TapGesture().onEnded { model.select(item.id) })
                                    .onDrag { dragProvider(item) }
                                    .contextMenu { rowMenu(item) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selectedID) {
                        if let id = model.selectedID { proxy.scrollTo(id) }
                    }
                }
            }
            if !autoPaste && !tipDismissed { pasteTip }
        }
    }

    private var pasteTip: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
            Text("Seçince doğrudan yapıştırsın mı?").font(.system(size: 11))
            Spacer()
            Button("Aç") { model.onEnablePaste() }.buttonStyle(HexButtonStyle(tone: .primary))
            IconButton(symbol: "xmark", help: "Gösterme", tone: .subtle) { tipDismissed = true }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private func rowMenu(_ item: ClipItem) -> some View {
        Button(autoPaste ? "Yapıştır" : "Kopyala") { model.onChoose(item, false) }
        if autoPaste { Button("Yalnızca kopyala") { model.onChoose(item, true) } }
        Button(item.pinned ? "Sabitlemeyi kaldır" : "Sabitle") { model.togglePin(item) }
        Divider()
        Button("Sil", role: .destructive) { model.delete(item) }
    }

    private func dragProvider(_ item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .image:
            if let u = model.store.imageURL(item), let p = NSItemProvider(contentsOf: u) { return p }
            return NSItemProvider()
        case .link:
            if let s = item.text, let u = Fmt.safeOpenURL(s) { return NSItemProvider(object: u as NSURL) }
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.clearPrompt { clearBar } else { hintsBar }
    }

    private var clearBar: some View {
        let keep = UserDefaults.standard.bool(forKey: Prefs.keepPinnedKey)
        let groupCount = model.filter.kind.map(model.store.count) ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "trash").font(.system(size: 13, weight: .medium)).foregroundStyle(.red)
            Text(keep ? "Neyi temizleyelim? Sabitlenenler korunur, geri alınamaz."
                      : "Neyi temizleyelim? Geri alınamaz.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Vazgeç") { model.clearPrompt = false }
                .buttonStyle(HexButtonStyle(tone: .normal))
            if model.filter != .all {
                Button("\(model.filter.title) (\(groupCount))") { model.clear(model.filter) }
                    .buttonStyle(HexButtonStyle(tone: .danger))
                    .disabled(groupCount == 0)
            }
            Button("Tümünü temizle (\(model.store.items.count))") { model.clear(.all) }
                .buttonStyle(HexButtonStyle(tone: .danger))
                .disabled(model.store.items.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.red.opacity(0.06))
    }

    private var hintsBar: some View {
        HStack(spacing: 14) {
            KeyHint(key: "↑↓", label: "seç")
            KeyHint(key: "↩", label: autoPaste ? "yapıştır" : "kopyala")
            if autoPaste { KeyHint(key: "⌘↩", label: "kopyala") }
            KeyHint(key: "⌘1–9", label: "hızlı seç")
            KeyHint(key: "⌘E", label: "düzenle")
            KeyHint(key: "⌘⌫", label: "sil")
            Spacer()
            HStack(spacing: 2) {
                IconButton(symbol: "trash", help: "Temizle…", tone: .subtle) { model.clearPrompt = true }
                IconButton(symbol: "folder", help: "Klasörü aç", tone: .subtle) { model.onOpenFolder() }
                IconButton(symbol: "gearshape", help: "Ayarlar (⌘,)", tone: .subtle) { model.onOpenSettings() }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 44)
    }
}

struct Row: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let revision: Int
    let store: ClipStore

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.title(item))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                Text(Fmt.subtitle(item))
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white : Color.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        if item.kind == .image, let u = store.imageURL(item) {
            Thumbnail(url: u, revision: revision, maxPixel: 96, fill: true)
                .frame(width: 30, height: 30).clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        } else if let c = Fmt.hexColor(item.text) {
            shape.fill(c).frame(width: 30, height: 30)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.15)))
        } else {
            let tint: Color = item.kind == .link ? .blue : .gray
            Image(systemName: item.kind == .link ? "globe" : "text.alignleft")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : tint)
                .frame(width: 30, height: 30)
                .background(shape.fill(selected ? Color.white.opacity(0.2) : tint.opacity(0.14)))
        }
    }
}

// MARK: - Önizleme / düzenleme

struct PreviewPane: View {
    @Bindable var model: PanelModel
    var focused: FocusState<FocusField?>.Binding
    @AppStorage(Prefs.autoPasteKey) private var autoPaste = false

    var body: some View {
        if let item = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.6)
                info(item)
                actions(item)
            }
        } else {
            Text("Bir öğe seçin").foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            if let u = model.store.imageURL(item) {
                // Küçük görseller gerçek boyutundan büyük gösterilmez (bulanıklaşmasın).
                Thumbnail(url: u, revision: model.store.imageRevision, maxPixel: 1200)
                    .frame(maxWidth: CGFloat(item.width ?? 2000), maxHeight: CGFloat(item.height ?? 2000))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .onDrag { NSItemProvider(contentsOf: u) ?? NSItemProvider() }
            }
        case .link, .text:
            let editing = focused.wrappedValue == .editor
            VStack(alignment: .leading, spacing: 8) {
                if item.kind == .link, let host = Fmt.host(item.text ?? "") {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").foregroundStyle(.blue)
                        Text(host).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                }
                if let c = Fmt.hexColor(model.draft) {
                    RoundedRectangle(cornerRadius: 10).fill(c).frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
                }
                TextEditor(text: $model.draft)
                    .font(item.kind == .link ? .system(size: 13, design: .monospaced) : .system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused(focused, equals: .editor)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(editing ? 0.06 : 0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(editing ? Color.accentColor.opacity(0.6) : Color.clear))
                HStack(spacing: 8) {
                    if model.draftChanged {
                        Text("Değişiklik otomatik kaydedilir").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Geri al") { model.revertDraft() }.buttonStyle(HexButtonStyle())
                        Button("Kaydet") { model.commitDraft() }.buttonStyle(HexButtonStyle(tone: .primary))
                    } else {
                        Text(editing ? "Esc ile listeye dön" : "Düzenlemek için metne tıklayın (⌘E)")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 28)
            }
            .padding(14)
        }
    }

    private func info(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: item.kind.symbol)
                if let s = item.sourceApp { Text(s); Text("·") }
                Text(Fmt.full.string(from: item.date))
            }
            Text(item.kind == .image ? imageInfo(item) : Fmt.stats(model.draft))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.top, 10)
    }

    private func imageInfo(_ item: ClipItem) -> String {
        var s = ""
        if let w = item.width, let h = item.height { s = "\(w)×\(h) piksel" }
        if let u = model.store.imageURL(item),
           let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            s += " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return s
    }

    private func actions(_ item: ClipItem) -> some View {
        HStack(spacing: 8) {
            Button { model.onChoose(item, false) } label: {
                Label(autoPaste ? "Yapıştır" : "Kopyala", systemImage: autoPaste ? "arrow.down.doc" : "doc.on.doc")
            }
            .buttonStyle(HexButtonStyle(tone: .primary))
            if item.kind == .image {
                Button { editImage(item) } label: { Label("Düzenle", systemImage: "pencil") }
                    .buttonStyle(HexButtonStyle())
                IconButton(symbol: "folder", help: "Finder'da göster") {
                    if let u = model.store.imageURL(item) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
            } else if item.kind == .link, let u = Fmt.safeOpenURL(item.text ?? "") {
                Button { NSWorkspace.shared.open(u) } label: { Label("Tarayıcıda aç", systemImage: "safari") }
                    .buttonStyle(HexButtonStyle())
            }
            Spacer()
            IconButton(symbol: item.pinned ? "pin.slash" : "pin",
                       help: item.pinned ? "Sabitlemeyi kaldır (⌘P)" : "Sabitle — sınırdan etkilenmez (⌘P)") {
                model.togglePin(item)
            }
            IconButton(symbol: "trash", help: "Sil (⌘⌫)", tone: .danger) { model.delete(item) }
        }
        .padding(14)
    }

    /// Görsel Önizleme'de açılır; orada kaydedilen değişiklikler aynı dosyaya yazılır.
    private func editImage(_ item: ClipItem) {
        guard let url = model.store.imageURL(item) else { return }
        ImageEditWatcher.shared.watch(item: item, url: url, store: model.store)
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        if FileManager.default.fileExists(atPath: preview.path) {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Önizleme'de düzenlenen görselin değiştiğini fark edip küçük resmi tazeler.
@MainActor
final class ImageEditWatcher {
    static let shared = ImageEditWatcher()
    private var watched: [UUID: (url: URL, date: Date?, store: ClipStore, item: ClipItem)] = [:]
    private var timer: Timer?

    func watch(item: ClipItem, url: URL, store: ClipStore) {
        watched[item.id] = (url, modDate(url), store, item)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func tick() {
        for (id, w) in watched {
            guard FileManager.default.fileExists(atPath: w.url.path) else { watched[id] = nil; continue }
            let d = modDate(w.url)
            if d != w.date {
                watched[id]?.date = d
                w.store.refreshImage(w.item)
            }
        }
        // Çok sayıda izleme birikirse hepsini bırak (bellek sınırı).
        if watched.count > 20 { watched.removeAll() }
        if watched.isEmpty { timer?.invalidate(); timer = nil }
    }
}

// MARK: - Ayarlar

struct SettingsView: View {
    @Bindable var store: ClipStore
    var openFolder: () -> Void

    @AppStorage(Prefs.unlimitedKey) private var unlimited = false
    @AppStorage(Prefs.limitKey) private var savedLimit = Prefs.defaultLimit
    @AppStorage(Prefs.autoPasteKey) private var autoPaste = false
    @AppStorage(Prefs.dragShelfKey) private var dragShelf = true
    @AppStorage(Prefs.keepPinnedKey) private var keepPinned = true

    @ViewState private var limitDraft = Prefs.defaultLimit
    @ViewState private var unlimitedDraft = false
    @ViewState private var loginOn = SMAppService.mainApp.status == .enabled
    @ViewState private var trusted = Paster.trusted
    @ViewState private var pendingClear: Kind?? = nil
    @ViewState private var applied = false
    @ViewState private var shortcutToken = 0

    private var draftLimit: Int? { unlimitedDraft ? nil : max(1, limitDraft) }
    private var limitChanged: Bool { unlimitedDraft != unlimited || (!unlimitedDraft && limitDraft != savedLimit) }

    var body: some View {
        Form {
            Section("Kullanım") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Açma kısayolu")
                        Text("Basınca HexClipboard ekranın ortasında açılır. Kutuya tıklayıp yeni kısayola basın; ⌫ kaldırır, Esc vazgeçer.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    ShortcutRecorder(token: shortcutToken, onChange: { shortcutToken += 1 }).frame(width: 160, height: 26)
                    Button("Varsayılan") { HotKeyCenter.shared.set(Shortcut.fallback); shortcutToken += 1 }
                        .help("⌃⌘V")
                }
                if HotKeyCenter.shared.registrationFailed && shortcutToken >= 0 {
                    Label("Bu kısayol başka bir uygulama tarafından kullanılıyor; farklı bir kısayol seçin.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Toggle(isOn: Binding(get: { autoPaste }, set: { on in
                    autoPaste = on
                    if on && !Paster.trusted { Paster.requestTrust() }
                    trusted = Paster.trusted
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Seçince doğrudan yapıştır")
                        Text("↩ ile seçtiğiniz öğe, çalıştığınız uygulamaya yapıştırılır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if autoPaste && !trusted {
                    HStack {
                        Label("Erişilebilirlik izni gerekiyor; o zamana kadar yalnızca kopyalanır.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("İzin ver…") { Paster.openSettings() }
                    }
                }
                Toggle(isOn: $dragShelf) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sürükleyince bırakma panelini göster")
                        Text("Bir yazı, link ya da görsel sürüklerken ekranın üstünde belirir; üstüne bırakınca kaydedilir.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Girişte başlat", isOn: Binding(get: { loginOn }, set: { _ in
                    LoginItem.toggle()
                    loginOn = SMAppService.mainApp.status == .enabled
                }))
                Toggle("Kaydı duraklat", isOn: $store.paused)
            }

            Section("Saklama") {
                Toggle("Sınırsız tut", isOn: $unlimitedDraft)
                HStack {
                    Text("Her grupta en fazla")
                    TextField("", value: $limitDraft, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $limitDraft, in: 1...100_000, step: 10).labelsHidden()
                    Text("öğe")
                }
                .disabled(unlimitedDraft)
                .foregroundStyle(unlimitedDraft ? .secondary : .primary)

                let overflow = store.overflow(limit: draftLimit)
                HStack {
                    if overflow > 0 && limitChanged {
                        Label("Uygulanınca en eski \(overflow) öğe silinecek.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    } else if applied && !limitChanged {
                        Label("Kaydedildi", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
                    } else {
                        Text("Yazılar, linkler ve görseller için ayrı ayrı uygulanır. Sabitlenenler sayılmaz.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uygula") {
                        unlimited = unlimitedDraft
                        if !unlimitedDraft { savedLimit = max(1, limitDraft); limitDraft = savedLimit }
                        store.enforceLimits()
                        applied = true
                    }
                    .disabled(!limitChanged)
                }
                HStack {
                    Text(store.storage.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Klasörü aç", action: openFolder)
                }
            }

            Section("Temizle") {
                Toggle("Temizlerken sabitlenenleri koru", isOn: $keepPinned)
                HStack(spacing: 8) {
                    ForEach(Kind.allCases) { k in
                        Button("\(k.title) (\(store.count(k)))") { pendingClear = .some(k) }
                            .disabled(store.count(k) == 0)
                    }
                    Spacer()
                    Button("Tümünü temizle", role: .destructive) { pendingClear = .some(nil) }
                        .disabled(store.items.isEmpty)
                }
            }

            Section("Gizlilik") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("İnternete bağlanmaz; hiçbir veri dışarı gönderilmez.", systemImage: "lock.shield")
                    Label("Parola yöneticilerinin “gizli” olarak işaretlediği kopyalar kaydedilmez.", systemImage: "key")
                    Label("Klasör ve dosyalar yalnızca sizin kullanıcınız tarafından okunabilir.", systemImage: "person.badge.key")
                    Label("Erişilebilirlik izni yalnızca ⌘V göndermek için kullanılır; tuş vuruşları okunmaz.",
                          systemImage: "keyboard")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            limitDraft = savedLimit
            unlimitedDraft = unlimited
            loginOn = SMAppService.mainApp.status == .enabled
            trusted = Paster.trusted
            applied = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = Paster.trusted
        }
        .onChange(of: limitDraft) { applied = false }
        .onChange(of: unlimitedDraft) { applied = false }
        .confirmationDialog(clearTitle, isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })) {
            Button("Temizle", role: .destructive) {
                if case .some(let k) = pendingClear { store.clear(k, keepPinned: keepPinned) }
                pendingClear = nil
            }
            Button("Vazgeç", role: .cancel) { pendingClear = nil }
        } message: {
            Text(keepPinned ? "Sabitlenen öğeler korunur. Bu işlem geri alınamaz."
                            : "Sabitlenenler dahil silinir. Bu işlem geri alınamaz.")
        }
    }

    private var clearTitle: String {
        switch pendingClear {
        case .some(.some(let k)): "\(k.title) temizlensin mi?"
        case .some(.none): "Tüm geçmiş temizlensin mi?"
        case .none: ""
        }
    }
}
