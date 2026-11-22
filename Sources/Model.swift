// HexClipboard — veri katmanı.
// Ağ kodu yoktur. Her şey ~/Belgeler/HexClipboard klasöründe, yalnızca sizin kullanıcınızın
// okuyabileceği izinlerle (klasör 700, dosyalar 600) saklanır.

import Cocoa
import CryptoKit
import UniformTypeIdentifiers
import Observation
import ImageIO

// MARK: - Model

enum Kind: String, Codable, CaseIterable, Identifiable {
    case text, link, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Yazılar"
        case .link: "Linkler"
        case .image: "Görseller"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        }
    }
}

struct ClipItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: Kind
    /// Yazı ve link içeriği.
    var text: String?
    /// Görsel dosyasının adı (Görseller klasöründe).
    var imageFile: String?
    var width: Int?
    var height: Int?
    var date: Date
    var pinned: Bool
    var sourceApp: String?
    /// Aynı içeriği iki kez saklamamak için içerik özeti (yalnızca yerelde kullanılır).
    var hash: String
}

private struct IndexFile: Codable {
    var version: Int
    var items: [ClipItem]
}

enum Hashing {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func sha256(_ s: String) -> String { sha256(Data(s.utf8)) }
}

enum Classifier {
    /// Tek parça bir web/e-posta adresi mi?
    static func isLink(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 4096, !t.contains(where: { $0.isWhitespace }) else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("www."), t.dropFirst(4).contains(".") { return true }
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "ftp", "sftp": return (u.host?.isEmpty == false)
        case "mailto": return t.count > 7 && t.contains("@")
        default: return false
        }
    }
}

// MARK: - Settings

enum Prefs {
    static let unlimitedKey = "limitUnlimited"
    static let limitKey = "limitPerGroup"
    static let autoPasteKey = "autoPaste"
    static let dragShelfKey = "dragShelf"
    static let pasteTipDismissedKey = "pasteTipDismissed"
    static let pausedKey = "paused"
    static let keepPinnedKey = "clearKeepsPinned"
    static let defaultLimit = 200

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            unlimitedKey: false,
            limitKey: defaultLimit,
            autoPasteKey: false,
            dragShelfKey: true,
            pasteTipDismissedKey: false,
            pausedKey: false,
            keepPinnedKey: true,
        ])
    }

    /// nil = sınırsız
    static var limit: Int? {
        let d = UserDefaults.standard
        if d.bool(forKey: unlimitedKey) { return nil }
        return max(1, d.integer(forKey: limitKey))
    }
}

// MARK: - Storage

/// Diske okuma/yazma. Dizin yapısı:
///   HexClipboard/
///     gecmis.json      → yazılar, linkler ve görsellerin listesi
///     Görseller/       → PNG dosyaları
final class Storage: @unchecked Sendable {
    let root: URL
    let imagesDir: URL
    let indexURL: URL
    private let queue = DispatchQueue(label: "local.hexclipboard.storage")
    /// Geçmiş okunamadıysa (izin/kilit vb.) eski verinin üzerine yazmamak için yazma kapatılır.
    private var writesBlocked = false
    /// Yazma hatalarını arayüze bildirmek için (ana iş parçacığında çağrılır).
    var onError: (@Sendable (String) -> Void)?

    enum LoadResult {
        case ok([ClipItem])
        case missing
        case corrupt(backup: String)
        case unreadable(String)
    }

    static var defaultRoot: URL {
        #if HEXTEST
        // Yalnızca test derlemesinde: --data-dir <klasör>
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("HexClipboard", isDirectory: true)
    }

    init(root: URL = Storage.defaultRoot) {
        self.root = root
        imagesDir = root.appendingPathComponent("Görseller", isDirectory: true)
        indexURL = root.appendingPathComponent("gecmis.json")
        ensureDirs()
    }

    func ensureDirs() {
        let fm = FileManager.default
        for dir in [root, imagesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        applyPrivacyMarkers()
    }

    /// Spotlight'ın pano içeriğini dizinlemesini ve iCloud Drive'ın ("Masaüstü ve Belgeler"
    /// açılırsa) klasörü buluta eşitlemesini engeller. Veri bu Mac'ten çıkmaz.
    private func applyPrivacyMarkers() {
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        var one: UInt8 = 1
        _ = root.withUnsafeFileSystemRepresentation { path in
            setxattr(path, "com.apple.fileprovider.ignore#P", &one, 1, 0, 0)
        }
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return .missing }
        let data: Data
        do { data = try Data(contentsOf: indexURL) } catch {
            // Dosya var ama okunamıyor: üzerine yazıp geçmişi kaybetmeyelim.
            writesBlocked = true
            return .unreadable(error.localizedDescription)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let file = try? dec.decode(IndexFile.self, from: data) { return .ok(file.items) }
        // Bozuk dosyanın üzerine yazmayalım: kenara al, boş başla.
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = root.appendingPathComponent("gecmis.bozuk-\(f.string(from: Date())).json")
        do { try FileManager.default.moveItem(at: indexURL, to: backup) } catch {
            writesBlocked = true
            return .unreadable(error.localizedDescription)
        }
        return .corrupt(backup: backup.lastPathComponent)
    }

    private static func encode(_ items: [ClipItem]) -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(IndexFile(version: 1, items: items))
    }

    private func write(_ items: [ClipItem]) {
        guard !writesBlocked else { return }
        guard let data = Self.encode(items) else { return }
        ensureDirs()
        do {
            try data.write(to: indexURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            report("Geçmiş kaydedilemedi: \(error.localizedDescription)")
        }
    }

    func report(_ message: String) {
        NSLog("HexClipboard: \(message)")
        let cb = onError
        DispatchQueue.main.async { cb?(message) }
    }

    /// Kodlama ve yazma arka planda yapılır; arayüz takılmaz.
    func saveAsync(_ items: [ClipItem]) {
        queue.async { self.write(items) }
    }

    func saveNow(_ items: [ClipItem]) {
        queue.sync { self.write(items) }
    }

    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    func writeImage(_ png: Data, name: String) throws {
        ensureDirs()
        let url = imageURL(name)
        try png.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func deleteImage(_ name: String) {
        // Yalnızca kendi klasörümüzdeki düz dosya adlarını sil (yol oyunlarına karşı).
        guard !name.contains("/"), !name.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: imageURL(name))
    }

    /// Listede olmayan görsel dosyalarını siler.
    func removeOrphanImages(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path) else { return }
        for f in files where f.hasSuffix(".png") && !names.contains(f) { deleteImage(f) }
    }
}

// MARK: - Store

@MainActor @Observable
final class ClipStore {
    private(set) var items: [ClipItem] = [] {
        didSet { version &+= 1 }
    }
    /// Liste her değiştiğinde artar; panel süzme sonucunu buna göre önbelleğe alır.
    private(set) var version = 0
    var paused: Bool = UserDefaults.standard.bool(forKey: Prefs.pausedKey) {
        didSet { UserDefaults.standard.set(paused, forKey: Prefs.pausedKey) }
    }
    /// Görsel Önizleme'de düzenlenince küçük resimleri tazelemek için artırılır.
    var imageRevision = 0
    /// Kayıt sorunu varsa panelde gösterilir.
    var problem: String?

    @ObservationIgnored let storage: Storage
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// Kendi yazdığımız pano değişikliğini tekrar kaydetmemek için.
    @ObservationIgnored var onOwnWrite: ((Int) -> Void)?

    static let markerType = NSPasteboard.PasteboardType("local.hexclipboard.marker")

    init(storage: Storage = Storage()) {
        self.storage = storage
        var loaded: [ClipItem] = []
        var clean = false
        switch storage.load() {
        case .ok(let list): loaded = list; clean = true
        case .missing: clean = true
        case .corrupt(let backup):
            problem = "Geçmiş dosyası bozuktu; \(backup) olarak yedeklendi ve yeniden başlandı."
        case .unreadable(let why):
            problem = "Geçmiş okunamadı (\(why)). Verinizi korumak için kayıt durduruldu; uygulamayı yeniden başlatın."
        }
        // Dosyası kaybolmuş görselleri listeden çıkar.
        loaded.removeAll { item in
            guard item.kind == .image else { return item.text?.isEmpty ?? true }
            guard let f = item.imageFile else { return true }
            return !FileManager.default.fileExists(atPath: storage.imageURL(f).path)
        }
        items = loaded
        // Sahipsiz görselleri yalnızca geçmiş sorunsuz okunduysa temizle (yedekteki görseller silinmesin).
        if clean { storage.removeOrphanImages(keeping: Set(loaded.compactMap(\.imageFile))) }
        enforceLimits()
        storage.onError = { [weak self] msg in
            MainActor.assumeIsolated { self?.problem = msg }
        }
    }

    // MARK: Okuma

    /// kind nil → tüm gruplar birlikte. Sabitlenenler üstte, sonra en yeni.
    func items(_ kind: Kind?) -> [ClipItem] {
        items.filter { kind == nil || $0.kind == kind }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.date > $1.date
        }
    }

    func count(_ kind: Kind) -> Int { items.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }

    func imageURL(_ item: ClipItem) -> URL? { item.imageFile.map(storage.imageURL) }

    // MARK: Ekleme

    @discardableResult
    func addText(_ s: String, source: String?) -> Kind? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let kind: Kind = Classifier.isLink(trimmed) ? .link : .text
        let value = kind == .link ? trimmed : s
        insert(ClipItem(id: UUID(), kind: kind, text: value, imageFile: nil, width: nil, height: nil,
                        date: Date(), pinned: false, sourceApp: source, hash: Hashing.sha256(value)))
        return kind
    }

    /// Görsel arka planda hazırlanıp diske yazıldıktan sonra listeye eklenir.
    func addPreparedImage(file name: String, hash: String, width: Int, height: Int, source: String?) {
        if bumpExisting(kind: .image, hash: hash) { storage.deleteImage(name); return }
        insert(ClipItem(id: UUID(), kind: .image, text: nil, imageFile: name, width: width,
                        height: height, date: Date(), pinned: false, sourceApp: source, hash: hash))
    }

    /// Aynı içerik zaten varsa en üste taşır.
    private func bumpExisting(kind: Kind, hash: String) -> Bool {
        guard let i = items.firstIndex(where: { $0.kind == kind && $0.hash == hash }) else { return false }
        items[i].date = Date()
        scheduleSave()
        return true
    }

    private func insert(_ item: ClipItem) {
        if bumpExisting(kind: item.kind, hash: item.hash) { return }
        items.append(item)
        enforceLimits(kind: item.kind)
        scheduleSave()
    }

    // MARK: Düzenleme

    func updateText(_ item: ClipItem, to newValue: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let v = item.kind == .link ? newValue.trimmingCharacters(in: .whitespacesAndNewlines) : newValue
        guard !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items[i].text = v
        items[i].hash = Hashing.sha256(v)
        scheduleSave()
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        if !items[i].pinned { enforceLimits(kind: item.kind) }
        scheduleSave()
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        if let f = item.imageFile { storage.deleteImage(f) }
        scheduleSave()
    }

    /// kind nil → tüm gruplar.
    func clear(_ kind: Kind?, keepPinned: Bool) {
        let removed = items.filter { (kind == nil || $0.kind == kind) && !(keepPinned && $0.pinned) }
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        removed.compactMap(\.imageFile).forEach(storage.deleteImage)
        scheduleSave()
    }

    /// Sınır uygulanırsa kaç öğe silineceği (sabitlenenler sayılmaz).
    func overflow(limit: Int?) -> Int {
        guard let limit else { return 0 }
        return Kind.allCases.reduce(0) { sum, k in
            sum + max(0, items.filter { $0.kind == k && !$0.pinned }.count - limit)
        }
    }

    /// Her grupta en yeni N sabitlenmemiş öğeyi tutar.
    func enforceLimits(kind: Kind? = nil) {
        guard let limit = Prefs.limit else { return }
        var removed: [ClipItem] = []
        for k in Kind.allCases where kind == nil || kind == k {
            let unpinned = items.filter { $0.kind == k && !$0.pinned }.sorted { $0.date > $1.date }
            if unpinned.count > limit { removed += unpinned[limit...] }
        }
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        removed.compactMap(\.imageFile).forEach(storage.deleteImage)
        scheduleSave()
    }

    // MARK: Panoya kopyalama

    @discardableResult
    func copyToPasteboard(_ item: ClipItem) -> Bool {
        let pb = NSPasteboard.general
        switch item.kind {
        case .text, .link:
            guard let s = item.text else { return false }
            pb.clearContents()
            var types: [NSPasteboard.PasteboardType] = [.string, Self.markerType]
            if item.kind == .link, URL(string: s) != nil { types.insert(.URL, at: 1) }
            pb.declareTypes(types, owner: nil)
            pb.setString(s, forType: .string)
            if types.contains(.URL) { pb.setString(s, forType: .URL) }
        case .image:
            guard let url = imageURL(item), let data = try? Data(contentsOf: url) else { return false }
            pb.clearContents()
            // TIFF sıkıştırılmamıştır (8K görselde ~250 MB); yalnızca makul boyutlarda eklenir.
            let pixels = (item.width ?? 0) * (item.height ?? 0)
            let addTiff = pixels > 0 && pixels <= 16_000_000
            pb.declareTypes(addTiff ? [.png, .tiff, Self.markerType] : [.png, Self.markerType], owner: nil)
            pb.setData(data, forType: .png)
            if addTiff, let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        }
        pb.setData(Data(), forType: Self.markerType)
        onOwnWrite?(pb.changeCount)
        // Kopyalanan öğe en üste gelsin.
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].date = Date()
            scheduleSave()
        }
        return true
    }

    /// Görsel Önizleme'de düzenlendiyse özeti ve boyutu tazele.
    func refreshImage(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), let url = imageURL(item),
              let data = try? Data(contentsOf: url) else { return }
        items[i].hash = Hashing.sha256(data)
        if let rep = NSBitmapImageRep(data: data) {
            items[i].width = rep.pixelsWide
            items[i].height = rep.pixelsHigh
        }
        imageRevision += 1
        scheduleSave()
    }

    // MARK: Kayıt

    func scheduleSave() {
        #if HEXTEST
        if ProcessInfo.processInfo.environment["HEXDEBUG"] != nil {
            print("     [kayıt istendi] " + Thread.callStackSymbols.dropFirst().prefix(3)
                .map { $0.split(separator: " ").dropFirst(3).first.map(String.init) ?? "" }.joined(separator: " ← "))
        }
        #endif
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.storage.saveAsync(self.items)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        storage.saveNow(items)
    }
}

// MARK: - Pasteboard monitor

/// macOS'ta pano değişikliği için bildirim yoktur; sayaç yarım saniyede bir yerel olarak kontrol edilir.
@MainActor
final class PasteboardMonitor {
    private let store: ClipStore
    private var lastChange: Int

    static let maxImageBytes = 50 * 1024 * 1024
    nonisolated static let imageQueue = DispatchQueue(label: "local.hexclipboard.images", qos: .utility)
    static let maxTextChars = 1_000_000

    /// Parola yöneticileri vb. bu türlerle "kaydetme" der (nspasteboard.org kuralları).
    static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]

    init(store: ClipStore) {
        self.store = store
        lastChange = NSPasteboard.general.changeCount
        store.onOwnWrite = { [weak self] c in self?.lastChange = c }
    }

    func check() {
        let pb = NSPasteboard.general
        let c = pb.changeCount
        guard c != lastChange else { return }
        lastChange = c
        guard !store.paused else { return }

        let types = pb.types ?? []
        let raw = Set(types.map(\.rawValue))
        if raw.contains(ClipStore.markerType.rawValue) { return }
        if !raw.isDisjoint(with: Self.skipTypes) { return }

        ingest(pb, source: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    /// Bir panodaki içeriği (kopyalama ya da sürükle-bırak) gruplara ayırıp kaydeder.
    /// Kaydedilen grupları döndürür; boşsa uygun içerik yoktur.
    @discardableResult
    func ingest(_ pb: NSPasteboard, source: String?) -> [Kind] {
        let types = pb.types ?? []
        var saved: [Kind] = []

        // Dosyalar: yalnızca görsel dosyalarını al, diğerlerini (ve simgelerini) yok say.
        if types.contains(.fileURL) {
            let urls = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            for url in urls {
                guard let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image),
                      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      size <= Self.maxImageBytes,
                      let data = try? Data(contentsOf: url) else { continue }
                if addImageData(data, source: source) { saved.append(.image) }
            }
            return saved
        }

        var string = pb.string(forType: .string)
        if string == nil, let u = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, !u.isFileURL {
            string = u.absoluteString // yalnızca adres taşıyan sürüklemeler
        }
        let hasImage = types.contains(where: { [.png, .tiff].contains($0) || $0.rawValue == "public.jpeg"
            || $0.rawValue == "public.heic" })
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Görsel + (boş metin veya yalnızca adres) → görsel.
        // Görsel + gerçek metin (ör. Word/Excel metnin resmini de koyar) → yazı.
        if hasImage && (trimmed.isEmpty || Classifier.isLink(trimmed)) {
            if let data = imageData(pb), addImageData(data, source: source) { return [.image] }
        }
        let trimmedAll = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let string, !trimmedAll.isEmpty, string.count <= Self.maxTextChars,
           let k = store.addText(string, source: source) {
            saved.append(k)
        }
        return saved
    }

    private func imageData(_ pb: NSPasteboard) -> Data? {
        let order: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic")]
        for t in order {
            if let d = pb.data(forType: t), d.count <= Self.maxImageBytes { return d }
        }
        return nil
    }

    /// Hızlı doğrulama ana iş parçacığında; PNG'ye dönüştürme, özet ve diske yazma arka planda.
    @discardableResult
    private func addImageData(_ data: Data, source: String?) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              CGImageSourceGetType(src) != nil else { return false }
        let store = store
        let storage = store.storage
        // Sırayla işlenir: aynı anda çok görsel kopyalanınca bellek şişmesin.
        Self.imageQueue.async { autoreleasepool {
            guard let p = Self.preparePNG(data) else { return }
            let name = "\(UUID().uuidString).png"
            do { try storage.writeImage(p.png, name: name) } catch {
                storage.report("Görsel kaydedilemedi: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store.addPreparedImage(file: name, hash: p.hash, width: p.width, height: p.height, source: source)
                }
            }
        } }
        return true
    }

    nonisolated static func preparePNG(_ data: Data) -> (png: Data, hash: String, width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let png: Data
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            png = data
        } else if let p = rep.representation(using: .png, properties: [:]) {
            png = p
        } else { return nil }
        return (png, Hashing.sha256(png), rep.pixelsWide, rep.pixelsHigh)
    }
}
