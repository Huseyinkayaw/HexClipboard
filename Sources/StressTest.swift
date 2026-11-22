// HexClipboard — hata, güvenlik ve performans testleri. Yalnızca test derlemesinde (./build.sh --test) bulunur.
#if HEXTEST
import Cocoa

@MainActor
enum StressTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        print((ok ? "OK   " : "FAIL ") + name)
        if !ok { failures += 1 }
    }

    private static func ms(_ block: () -> Void) -> Double {
        let t = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }

    private static func tempDir(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("hexclip-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("local.hexclipboard.stress.\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        return pb
    }

    private static func png(_ w: Int, _ h: Int, seed: Int) -> Data { autoreleasepool {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        if let p = rep.bitmapData {
            for i in 0..<(rep.bytesPerRow * h) { p[i] = UInt8((i &* 31 &+ seed &* 97) & 0xFF) }
        }
        return rep.representation(using: .png, properties: [:])!
    } }

    private static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    /// Bitene kadar ana döngüyü çalıştırır (arka plan görsel işleri için).
    private static func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return cond()
    }

    static func run() {
        // Kullanıcının gerçek ayarlarına dokunmamak için testler geçici bir ayar alanında çalışır.
        let d = UserDefaults.standard
        d.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        func setTemp(_ v: Any, _ k: String) {
            var dom = d.volatileDomain(forName: UserDefaults.argumentDomain)
            dom[k] = v
            d.setVolatileDomain(dom, forName: UserDefaults.argumentDomain)
        }
        let fm = FileManager.default

        print("== Hata dayanıklılığı")
        do {
            // Bozuk JSON: yedeklenmeli, görseller silinmemeli
            let dir = tempDir("corrupt")
            let st = Storage(root: dir)
            try? "{ bozuk json".data(using: .utf8)!.write(to: st.indexURL)
            try? png(4, 4, seed: 1).write(to: st.imageURL("ESKI.png"))
            let store = ClipStore(storage: st)
            let backups = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("gecmis.bozuk-") } ?? []
            check("bozuk geçmiş yedeklendi", backups.count == 1)
            check("bozuk geçmişte eski görseller silinmedi", fm.fileExists(atPath: st.imageURL("ESKI.png").path))
            check("bozuk geçmiş için uyarı gösteriliyor", store.problem != nil)
            store.addText("yeni", source: nil)
            store.saveNow()
            check("yedekten sonra yeni kayıt yazılabiliyor", ((try? Data(contentsOf: st.indexURL))?.count ?? 0) > 10)
            try? fm.removeItem(at: dir)
        }
        do {
            // Okunamayan geçmiş: üzerine yazılmamalı
            let dir = tempDir("unreadable")
            let st = Storage(root: dir)
            let original = Data("{\"version\":1,\"items\":[]}".utf8) + Data(repeating: 0x20, count: 64)
            try? original.write(to: st.indexURL)
            chmod(st.indexURL.path, 0o000)
            let store = ClipStore(storage: st)
            check("okunamayan geçmiş için uyarı gösteriliyor", store.problem?.contains("okunamadı") == true)
            store.addText("bunu yazmamalı", source: nil)
            store.saveNow()
            chmod(st.indexURL.path, 0o600)
            check("okunamayan geçmişin üzerine yazılmadı", (try? Data(contentsOf: st.indexURL)) == original)
            try? fm.removeItem(at: dir)
        }
        do {
            // Kayıp görsel dosyası listeden düşmeli
            let dir = tempDir("missing")
            let st = Storage(root: dir)
            let item = ClipItem(id: UUID(), kind: .image, text: nil, imageFile: "YOK.png", width: 1, height: 1,
                                date: Date(), pinned: false, sourceApp: nil, hash: "x")
            let txt = ClipItem(id: UUID(), kind: .text, text: "kalır", imageFile: nil, width: nil, height: nil,
                               date: Date(), pinned: false, sourceApp: nil, hash: "y")
            st.saveNow([item, txt])
            let store = ClipStore(storage: st)
            check("dosyası olmayan görsel listeden çıkarıldı", store.items.count == 1 && store.items[0].text == "kalır")
            try? fm.removeItem(at: dir)
        }
        do {
            // Yol oyunu: silme yalnızca kendi klasöründe
            let dir = tempDir("path")
            let st = Storage(root: dir)
            let outside = dir.deletingLastPathComponent().appendingPathComponent("hexclip-dokunma-\(UUID().uuidString).txt")
            try? Data("x".utf8).write(to: outside)
            st.deleteImage("../\(outside.lastPathComponent)")
            check("klasör dışına silme engellendi", fm.fileExists(atPath: outside.path))
            try? fm.removeItem(at: outside)
            try? fm.removeItem(at: dir)
        }

        print("== Güvenlik ve gizlilik")
        do {
            let dir = tempDir("privacy")
            let st = Storage(root: dir)
            st.saveNow([])
            let perms = { (p: String) in ((try? fm.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
            check("klasör izni 700", perms(dir.path) == 0o700 && perms(st.imagesDir.path) == 0o700)
            check("geçmiş dosyası izni 600", perms(st.indexURL.path) == 0o600)
            check("Spotlight dizinlemesi kapalı (.metadata_never_index)",
                  fm.fileExists(atPath: dir.appendingPathComponent(".metadata_never_index").path))
            var v: UInt8 = 0
            let n = getxattr(dir.path, "com.apple.fileprovider.ignore#P", &v, 1, 0, 0)
            check("iCloud Drive eşitlemesi dışında (fileprovider.ignore)", n == 1 && v == 1)
            try? fm.removeItem(at: dir)
        }
        check("file:// link açılmaz", Fmt.safeOpenURL("file:///Applications/Calculator.app") == nil)
        check("javascript: link açılmaz", Fmt.safeOpenURL("javascript:alert(1)") == nil)
        check("uygulama şeması açılmaz", Fmt.safeOpenURL("x-apple.systempreferences:com.apple.preference") == nil)
        check("https link açılır", Fmt.safeOpenURL("https://example.com/a?b=1") != nil)
        check("www. link https ile açılır", Fmt.safeOpenURL("www.example.com")?.scheme == "https")
        check("file:// link olarak sınıflanmaz", !Classifier.isLink("file:///etc/passwd"))
        check("boşluklu metin link sayılmaz", !Classifier.isLink("https://a.com ve b"))
        check("yapıştırma tuşu klavye düzenine göre bulundu (\(Paster.keyCodeForV()))", Paster.keyCodeForV() < 128)
        do {
            let dir = tempDir("concealed")
            let store = ClipStore(storage: Storage(root: dir))
            let mon = PasteboardMonitor(store: store)
            let pb = board {
                $0.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
                $0.setString("parola", forType: .string)
            }
            // check() yalnızca genel panoyu okur; gizli tür kontrolünü taklit et
            let raw = Set((pb.types ?? []).map(\.rawValue))
            check("gizli tür tanınıyor", !raw.isDisjoint(with: PasteboardMonitor.skipTypes))
            _ = mon
            try? fm.removeItem(at: dir)
        }

        print("== Performans")
        setTemp(true, Prefs.unlimitedKey)
        let dir = tempDir("perf")
        let st = Storage(root: dir)
        var many: [ClipItem] = []
        let base = String(repeating: "Lorem ipsum dolor sit amet, çğıöşü İĞÜ. ", count: 5)
        for i in 0..<10_000 {
            let t = "\(i) \(base)"
            many.append(ClipItem(id: UUID(), kind: i % 4 == 0 ? .link : .text,
                                 text: i % 4 == 0 ? "https://example.com/\(i)" : t, imageFile: nil, width: nil, height: nil,
                                 date: Date().addingTimeInterval(Double(-i)), pinned: i % 500 == 0, sourceApp: "Test",
                                 hash: Hashing.sha256(t)))
        }
        for i in 0..<50 {
            let big = String(repeating: "uzun metin \(i) ", count: 15_000) // ~200 KB
            many.append(ClipItem(id: UUID(), kind: .text, text: big, imageFile: nil, width: nil, height: nil,
                                 date: Date(), pinned: false, sourceApp: "Test", hash: Hashing.sha256(big)))
        }
        let huge = String(repeating: "a", count: 999_000) + "\nson"
        many.append(ClipItem(id: UUID(), kind: .text, text: huge, imageFile: nil, width: nil, height: nil,
                             date: Date(), pinned: false, sourceApp: "Test", hash: Hashing.sha256(huge)))
        let tSave = ms { st.saveNow(many) }
        let size = ((try? fm.attributesOfItem(atPath: st.indexURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "     10.051 öğe kaydı: %.0f ms (%.1f MB, arka planda yapılır)", tSave, Double(size) / 1_048_576))
        var store: ClipStore!
        let tLoad = ms { store = ClipStore(storage: st) }
        print(String(format: "     açılışta yükleme: %.0f ms", tLoad))
        check("10.051 öğe yüklendi", store.items.count == 10_051)
        check("yükleme 1,5 sn altında", tLoad < 1500)
        let model = PanelModel(store: store)
        print(String(format: "     bellek, 10.051 öğe yüklüyken: %.0f MB", rssMB()))
        let tList = ms { _ = model.visible }
        print(String(format: "     liste (sıralama): %.1f ms", tList))
        check("liste hazırlama 100 ms altında", tList < 100)
        let tSearch = ms { model.search = "9999"; _ = model.visible }
        let tSearch2 = ms { _ = model.visible }
        print(String(format: "     aynı arama tekrar (önbellek): %.2f ms", tSearch2))
        check("arama önbelleği çalışıyor (1 ms altında)", tSearch2 < 1)
        model.search = "CGIOSU" // Türkçe harfleri aksansız yazınca da bulunmalı
        check("aksansız arama Türkçe harfleri buluyor", model.visible.count > 1000)
        model.search = "9999"
        print(String(format: "     arama: %.1f ms", tSearch))
        check("arama 150 ms altında", tSearch < 150)
        model.search = ""
        let tTitles = ms { for it in store.items { _ = Fmt.title(it) } }
        print(String(format: "     10.051 satır başlığı: %.1f ms", tTitles))
        check("satır başlıkları 200 ms altında (1 MB metin dahil)", tTitles < 200)
        let hugeItem = store.items.first { $0.text?.count ?? 0 > 900_000 }!
        let tHuge = ms { _ = Fmt.title(hugeItem); _ = Fmt.stats(hugeItem.text!) }
        print(String(format: "     1 MB metin başlık+istatistik: %.1f ms", tHuge))
        check("1 MB metin hızlı (20 ms altında)", tHuge < 20)
        let tBump = ms { for i in 0..<200 { store.addText("yeni \(i)", source: nil) } }
        print(String(format: "     200 yeni kopya (ana iş parçacığı): %.1f ms", tBump))
        check("kopya başına 2 ms altında", tBump / 200 < 2)
        store.saveNow()

        // Görseller: ana iş parçacığı bloklanmamalı, tekrarlar tek kayıt olmalı
        let mon = PasteboardMonitor(store: store)
        var imgs = (0..<30).map { png(1600, 1200, seed: $0) }
        let before = store.count(.image)
        let tImgMain = ms { for data in imgs { autoreleasepool { mon.ingest(board { $0.setData(data, forType: .png) }, source: "Test") } } }
        print(String(format: "     30 büyük görsel (1600×1200) ana iş parçacığı süresi: %.0f ms", tImgMain))
        check("görsel işleme arka planda (ana iş parçacığı < 15 ms/görsel)", tImgMain / 30 < 15)
        check("30 görselin hepsi kaydedildi", waitUntil(20) { store.count(.image) == before + 30 })
        mon.ingest(board { $0.setData(imgs[0], forType: .png) }, source: "Test")
        mon.ingest(board { $0.setData(imgs[0], forType: .png) }, source: "Test")
        _ = waitUntil(3) { false }
        check("aynı görsel tekrar kopyalanınca çoğalmadı", store.count(.image) == before + 30)
        let files = (try? fm.contentsOfDirectory(atPath: st.imagesDir.path))?.count ?? -1
        check("fazladan görsel dosyası kalmadı (\(files))", files == store.count(.image))
        imgs = []
        print(String(format: "     bellek, 30 görsel işlendikten sonra: %.0f MB", rssMB()))
        let tiff = board {
            let rep = NSBitmapImageRep(data: png(300, 200, seed: 99))!
            $0.setData(rep.tiffRepresentation!, forType: .tiff)
        }
        mon.ingest(tiff, source: "Test")
        check("TIFF görsel PNG'ye çevrilip kaydedildi",
              waitUntil(5) { store.items.contains { $0.kind == .image && $0.width == 300 } })

        // Sınır: 10.000+ öğede 100'e indirme
        setTemp(false, Prefs.unlimitedKey)
        setTemp(100, Prefs.limitKey)
        let pinned = store.items.filter(\.pinned).count
        let tLimit = ms { store.enforceLimits() }
        print(String(format: "     sınırı 100'e indirme: %.0f ms", tLimit))
        check("her grupta en fazla 100 + sabitlenenler", Kind.allCases.allSatisfy { kind in
            store.items.filter { !$0.pinned && $0.kind == kind }.count <= 100 } && store.items.filter(\.pinned).count == pinned)
        store.saveNow()
        let filesAfter = (try? fm.contentsOfDirectory(atPath: st.imagesDir.path))?.count ?? -1
        check("sınırla silinen görsellerin dosyaları da silindi", filesAfter == store.count(.image))
        store.clear(nil, keepPinned: false)
        store.saveNow()
        let left = (try? fm.contentsOfDirectory(atPath: st.imagesDir.path))?.count ?? -1
        check("tümünü temizle: liste ve görsel klasörü boş", store.items.isEmpty && left == 0)
        print(String(format: "     bellek (RSS): %.0f MB", rssMB()))
        try? fm.removeItem(at: dir)

        print(failures == 0 ? "SONUÇ: hepsi geçti" : "SONUÇ: \(failures) hata")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
