// HexClipboard — bellek ve disk yazma ölçümü. Yalnızca test derlemesinde.
#if HEXTEST
import Cocoa

@MainActor
enum MemTest {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// --gen-data: test klasörüne 60 görsel + 1000 yazı/link üretir.
    static func generate(store: ClipStore) {
        let st = store.storage
        var items: [ClipItem] = []
        for i in 0..<60 {
            autoreleasepool {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1600, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                let p = rep.bitmapData!
                for j in 0..<(rep.bytesPerRow * 1600) { p[j] = UInt8((j / 4096 &+ i &* 37) & 0xFF) }
                let png = rep.representation(using: .png, properties: [:])!
                let name = "\(UUID().uuidString).png"
                try! st.writeImage(png, name: name)
                items.append(ClipItem(id: UUID(), kind: .image, text: nil, imageFile: name, width: 2400, height: 1600,
                                      date: Date().addingTimeInterval(Double(-i)), pinned: false, sourceApp: "Test",
                                      hash: Hashing.sha256(png)))
            }
        }
        for i in 0..<1000 {
            let t = i % 3 == 0 ? "https://example.com/sayfa/\(i)" : "Not \(i): " + String(repeating: "örnek metin ", count: 30)
            items.append(ClipItem(id: UUID(), kind: i % 3 == 0 ? .link : .text, text: t, imageFile: nil, width: nil,
                                  height: nil, date: Date().addingTimeInterval(Double(-i - 100)), pinned: false,
                                  sourceApp: "Test", hash: Hashing.sha256(t)))
        }
        st.saveNow(items)
        print("üretildi: \(items.count) öğe")
        exit(0)
    }

    static func run(main: PanelController, store: ClipStore) {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "OK   " : "FAIL ") + name); if !ok { failures += 1 } }
        let fm = FileManager.default
        let index = store.storage.indexURL
        func mtime() -> Date? { (try? fm.attributesOfItem(atPath: index.path))?[.modificationDate] as? Date }

        spin(2)
        let idle = footprintMB()
        print(String(format: "     boşta (%d öğe yüklü): %.1f MB", store.items.count, idle))
        let m0 = mtime()

        // Panel açık: tüm görselleri tek tek gez (büyük önizlemeler + küçük resimler)
        let t0 = CFAbsoluteTimeGetCurrent()
        autoreleasepool { main.show() }
        let firstOpen = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        // Gerçek kullanımdaki gibi her adım kendi olay döngüsü turunda (kendi bellek havuzuyla) çalışır.
        autoreleasepool { main.model.filter = .image }
        for _ in 0..<60 { autoreleasepool { main.model.move(1) }; spin(0.08) }
        autoreleasepool { main.model.filter = .all }
        for _ in 0..<80 { autoreleasepool { main.model.move(1) }; spin(0.02) }
        spin(1)
        let open = footprintMB()
        print(String(format: "     panel açık, 60 büyük görsel gezildikten sonra: %.1f MB", open))
        weak var panelRef = main.debugPanel
        autoreleasepool { main.hide() }
        spin(1)
        let justClosed = footprintMB()
        print(String(format: "     kapattıktan hemen sonra: %.1f MB", justClosed))
        print("     \(Int(PanelController.releaseDelay)) sn bekleniyor (arayüz bellekten bırakılsın)…")
        spin(PanelController.releaseDelay + 2)
        let released = footprintMB()
        print(String(format: "     kapattıktan %d sn sonra: %.1f MB", Int(PanelController.releaseDelay), released))
        check("panel penceresi bellekten silindi", panelRef == nil)
        check("kapanınca bellek açıkkenkinin altına indi", released < open)
        check("kapatınca açıkken kullanılanın en az %35'i geri verildi", released <= open * 0.65)
        if ProcessInfo.processInfo.environment["HEXHOLD"] != nil {
            print("BEKLİYOR \(getpid())"); fflush(stdout)
            spin(12)
            print(String(format: "     12 sn daha sonra: %.1f MB", footprintMB()))
        }

        // Sızıntı kontrolü: 5 tur aç → 60 görsel gez → kapat. Her turdan sonra bellek büyümemeli.
        var after: [Double] = []
        for _ in 0..<5 {
            autoreleasepool { main.show() }
            autoreleasepool { main.model.filter = .image }
            for _ in 0..<60 { autoreleasepool { main.model.move(1) }; spin(0.05) }
            autoreleasepool { main.model.filter = .all; main.hide() }
            spin(PanelController.releaseDelay + 1.5)
            after.append(footprintMB())
        }
        print("     5 tur aç-gez-kapat sonrası: " + after.map { String(format: "%.0f", $0) }.joined(separator: " → ") + " MB")
        check("tekrar tekrar açıp kapatınca bellek büyümüyor (sızıntı yok)", (after.last ?? 0) <= (after.first ?? 0) + 8)

        let t1 = CFAbsoluteTimeGetCurrent()
        main.show()
        let reopen = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        print(String(format: "     ilk açılış: %.0f ms, bırakıldıktan sonra yeniden açılış: %.0f ms", firstOpen, reopen))
        check("yeniden açılış hızlı (250 ms altında)", reopen < 250)
        check("yeniden açılınca liste dolu", main.model.visible.count == store.items.count)
        main.hide()
        main.releaseUI()

        // Disk: gezinme, açma-kapama ve bekleme hiçbir şey yazmamalı
        spin(3)
        check("açma/kapama/gezinme diske yazmadı", mtime() == m0)
        store.addText("yeni bir kopya", source: "Test")
        spin(1)
        check("yeni kopyada bir kez yazıldı", mtime() != m0)
        let m1 = mtime()
        spin(5)
        check("boşta 5 sn: hiç yazma yok", mtime() == m1)
        for i in 0..<20 { store.addText("hızlı \(i)", source: "Test") }
        spin(1)
        let m2 = mtime()
        spin(2)
        check("art arda 20 kopya tek yazmada toplandı", m2 != m1 && mtime() == m2)

        print(failures == 0 ? "SONUÇ: hepsi geçti" : "SONUÇ: \(failures) hata")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
