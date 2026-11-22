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

## Build & install
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

**Kurulum:** macOS 14+, Apple Silicon ve Xcode Command Line Tools gerekir. `./build.sh` derler ve `/Applications`'a kurar; `--no-install` yalnızca derler, `--dmg` kurulum dosyası üretir. İlk açılışta doğrudan yapıştırma için **Erişilebilirlik** izni istenir.
