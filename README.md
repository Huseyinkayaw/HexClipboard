# HexClipboard

A fully local **clipboard history** app for the macOS menu bar. It keeps the text, links and images you copy and brings them back with a single shortcut.

![HexClipboard](docs/screenshot.png)

## Features
- History for text, links and images — copy anywhere with ⌘C and it shows up here
- Open shortcut (default **⌃⌘V**, configurable in Settings)
- Paste the selected item straight into the app you're working in with `↩`; quick pick with `⌘1…9`
- Pin items, keep pinned items when clearing, pause recording
- Drag-and-drop shelf
- Ignores content copied from password managers
- Data is stored only in `~/Documents/HexClipboard`

## Privacy & security
- Makes no network connections.
- History is stored only on this Mac in `~/Documents/HexClipboard` (readable only by your user account), excluded from Spotlight and iCloud sync. It is not encrypted, so pause recording before copying sensitive text if needed.
- Skips anything copied from password managers (concealed/transient clipboard types).
- Opens only `http`, `https` and `mailto` links.

## Download
**[⬇ Download HexClipboard.dmg](https://github.com/Huseyinkayaw/HexClipboard/raw/main/release/HexClipboard.dmg)** — open it and drag **HexClipboard** into **Applications**.

Requires macOS 14+ on Apple Silicon (M1 or later). The app is not notarized by Apple, so macOS blocks the first launch ("Apple could not verify…"). Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to HexClipboard. Or run this once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/HexClipboard.app
```

SHA-256: `99f4ca746146563219d11d50ffb008c328c821733758eaec07a454c74854e35e`

## Build from source
Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools.

```bash
./build.sh               # build and install to /Applications
./build.sh --no-install  # build only (build/)
./build.sh --dmg         # create dist/HexClipboard.dmg
```
On first launch it asks for **Accessibility** permission (needed for direct paste).

---

## Türkçe

macOS menü çubuğunda çalışan, tamamen yerel bir **pano geçmişi** uygulaması. Kopyaladığınız yazıları, linkleri ve görselleri saklar; tek kısayolla geri getirip yapıştırmanızı sağlar.

**Özellikler**
- Yazı, link ve görsel geçmişi — herhangi bir yerde ⌘C yapın, burada görünür
- Açma kısayolu (varsayılan **⌃⌘V**, ayarlardan değiştirilebilir)
- `↩` ile seçilen öğeyi çalıştığınız uygulamaya doğrudan yapıştırma, `⌘1…9` ile hızlı seçim
- Öğeleri sabitleme, temizlerken sabitlenenleri koruma, kaydı duraklatma
- Sürükle-bırak paneli
- Parola yöneticilerinden kopyalananları kaydetmez
- Veriler yalnızca `~/Documents/HexClipboard` klasöründe durur

**Gizlilik ve güvenlik**
- İnternete bağlanmaz.
- Geçmiş yalnızca bu Mac'te, `~/Documents/HexClipboard` klasöründe durur (yalnızca sizin kullanıcınız okuyabilir); Spotlight ve iCloud eşitlemesi dışında tutulur. Şifrelenmez; hassas bir şey kopyalayacaksanız kaydı duraklatabilirsiniz.
- Parola yöneticilerinden kopyalananları kaydetmez.
- Yalnızca `http`, `https` ve `mailto` linklerini açar.

**İndir:** **[⬇ HexClipboard.dmg](https://github.com/Huseyinkayaw/HexClipboard/raw/main/release/HexClipboard.dmg)** — açın ve **HexClipboard**'i **Uygulamalar** klasörüne sürükleyin. macOS 14+ ve Apple Silicon (M1 veya üstü) gerekir. Uygulama Apple tarafından onaylanmadığı (notarize edilmediği) için macOS ilk açılışı engeller ("Apple … doğrulayamadı"). **Bitti**'ye basın, sonra **Sistem Ayarları → Gizlilik ve Güvenlik**'te aşağı inip HexClipboard için **Yine de Aç**'a tıklayın. Ya da Terminal'de bir kez şunu çalıştırın: `xattr -dr com.apple.quarantine /Applications/HexClipboard.app` SHA-256: `99f4ca746146563219d11d50ffb008c328c821733758eaec07a454c74854e35e`

**Kaynaktan derleme:** macOS 14+, Apple Silicon ve Xcode Command Line Tools gerekir. `./build.sh` derler ve `/Applications`'a kurar; `--no-install` yalnızca derler, `--dmg` kurulum dosyası üretir. İlk açılışta doğrudan yapıştırma için **Erişilebilirlik** izni istenir.
