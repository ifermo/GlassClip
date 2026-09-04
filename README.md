# GlassClip

[简体中文](README.zh.md) | English

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

A private, local-first clipboard history manager for macOS. Built with native Swift — Liquid Glass on macOS 26, standard vibrancy on macOS 14+.

All data stays on your machine. No cloud, no account, no telemetry.

## Features

- **Full-type capture** — text, rich text (RTF), HTML, images, file URLs, colors
- **Liquid Glass panel** — a single floating panel, summoned anywhere (macOS 26 Liquid Glass; standard vibrancy material on macOS 14/15)
- **Instant search** — just start typing, no need to click the search field
- **Favorites** — pin items to a dedicated section that survives limits and clears
- **Smart dedup** — re-copying the same content moves it back to the top; plain-text and rich variants of the same content merge into one item
- **In-panel preview** — press `Space` to split the panel and preview images, rendered HTML/RTF, colors, and file lists
- **Keyboard first** — everything reachable without the mouse
- **Sensitive-app filter** — clips copied inside 1Password, Bitwarden, KeePassXC, or Keychain Access are never recorded (list is editable)
- **Fast storage** — SQLite with large payloads on disk; thousands of items stay snappy
- **100% offline**

## Requirements

- **Run:** macOS 14.0 or later — Apple Silicon or Intel Mac
- **Build:** Xcode 26 or newer (macOS 26 SDK, Swift 6.2 toolchain)

## Build from source

```bash
make app        # universal .app (arm64 + x86_64), ad-hoc signed
make dmg        # .app → dist/GlassClip.dmg
make install    # → /Applications
make test       # unit tests
make run        # debug run from the CLI
```

See [BUILD_AND_USAGE.md](BUILD_AND_USAGE.md) for detailed build options, icon replacement, and troubleshooting.

## Usage

| Action | Shortcut |
|---|---|
| Open / close panel | Menu bar icon, or `⌥⌘V` (recordable in Settings) |
| Navigate | `↑` `↓` |
| Paste selected item | `Enter` |
| Preview selected item | `Space` |
| Paste as plain text | `⌘⇧V` (or right-click menu) |
| Search | Type any character |
| Switch All ↔ Favorites | `Tab` |
| Delete selected item | `⌫` |
| Close preview / search / panel | `Esc` (layered) |

### Auto Paste

By default, selecting an item only writes it to the clipboard — you paste with `⌘V` yourself.

To paste automatically on `Enter`, enable **Settings → Paste → Auto Paste** and grant the
**Accessibility** permission when prompted. GlassClip then synthesizes `⌘V` into the app you were using.

## License

[MIT](LICENSE)
