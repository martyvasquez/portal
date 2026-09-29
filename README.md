# Portal

A personal launcher and clipboard manager for macOS, replacing Raycast. It's a native Swift/SwiftUI
menu bar app with a proper Settings window, and it syncs between Macs through iCloud Drive.

- **⌘Space** opens the launcher: snippets for where you are, quicklinks, and apps.
- **⇧⌘V** opens clipboard history, encrypted and shared between your Macs.

## Features

### Launcher (⌘Space)

With nothing typed, the launcher shows, in order:

1. **Finder Selection**: when Finder is in front, rows to open the selection with your Open With apps.
2. **Snippets** for this folder, this site, and this app, then global snippets.
3. **Quicklinks**, in the order you arranged them.
4. **Recent Apps**.

Type to filter everything. Results you open often and recently rank higher.

| Key | Action |
|---|---|
| `↩` | Open, paste, or run the selected row |
| `⌘↩` | Alternate: a quicklink with the default app (Finder or default browser), when that's a different app; an app shown in Finder |
| `⌥↩` | Copy the link, path, or snippet text |
| `⌘1`–`⌘9` | Pick one of the first nine rows |
| `⇥` | Fill in a `{query}` quicklink |
| `⎋` | Clear the search, then close |

Type "settings", "clipboard", "new quicklink", or "quit" to run Portal's own commands.

### Quicklinks (Settings → Quicklinks)

A name, a folder or URL, and the app it opens in (Finder, Ghostty, Chrome, any app), shown
with that app's icon. Each can
have its own **global hotkey**. Put `{query}` in a link (`https://github.com/search?q={query}`)
and the launcher asks for text before opening it. Settings groups them by the app they
open in; drag within a group to reorder (the launcher lists them in that order).

### Snippets

Text the launcher pastes into the app you were in. `↩` pastes and restores your clipboard
afterwards; in Finder it copies instead. Snippets have one of four scopes:

| Scope | Where it's defined | Shows when |
|---|---|---|
| **Folder** | `.portal.json` in the repo (travels with git) | a terminal is in front and in that folder or below it |
| **Site** | Settings → Snippets → Only These Sites | Chrome, Safari, Arc, Brave, or Edge is on a matching page |
| **App** | Settings → Snippets → Only These Apps | that app is in front |
| **Global** | Settings → Snippets → Every App | always |

**How Portal knows the folder** (terminals only; Finder gets Open With instead):
- **Ghostty**: the focused terminal's working directory, from Ghostty's scripting interface.
- **Terminal**: the front tab's shell directory, found through the tab's tty.

**Site patterns:**
- `github.com` matches the site and its subdomains.
- `*.atlassian.net` matches any subdomain.
- `github.com/martyvasquez` also limits the match to that path.

**`.portal.json`** lives at the repo root. Portal finds it by walking up from the current folder:

```json
{
  "snippets": [
    { "name": "Update Portal", "text": "git pull && scripts/build.sh --install" }
  ],
  "seeded": ["scripts/build.sh", "swift build"]
}
```

**Build / Update Commands** is a launcher row whenever a terminal is in a folder:
- It reads `package.json` scripts, using pnpm, yarn, or bun when that lockfile is present.
- It also reads `Makefile`/`justfile` targets, `scripts/*.sh`, `bin/*`, and `Package.swift`, `Cargo.toml`, `project.yml`, and docker compose files.
- It adds the new commands to `.portal.json`, and after that the file is yours to edit.
- `seeded` records what was added before, so a later update never re-adds a command you deleted, and never changes your edits.
- If the file isn't valid JSON, it's left alone and the launcher offers **Fix .portal.json**.

**Edit Snippets** opens the file in your first Files app.

### Open With (Settings → Open With)

With Finder in front, the launcher offers apps for what's selected:
- **Folders and files** each have their own ordered app list, for example Ghostty → Terminal → Sublime Text for folders and Sublime Text → TextEdit for files. The first app is the default.
- **Treat as Folder**: selected files of these types (images, PDFs, archives, `.app`, …) open their folder instead.
- **Hotkey** (optional): opens the selection with the default apps and skips the launcher. Portal only holds this hotkey while Finder is in front, so the same keys (e.g. `⇧⌘O`) keep working in other apps.

### Clipboard history (⇧⌘V)

- **History**: 7 days by default. It covers text, links, images, and files, and each clip shows which app and which Mac it came from.
- **Sidebar filters**: All, This Mac, Other Macs, Secrets, and Pinned.
- **Secrets**: copies from password managers, plus anything that looks like an API key, token, or private key. They're masked in the list, can expire sooner, and are marked so other clipboard tools skip them.
- **Terminal cleanup**: text copied from Ghostty, Terminal, iTerm, and other terminals is cleaned as you copy it. Trailing spaces, shared indentation, box borders, and Claude Code's `⏺` marker are removed, and wrapped prose is rejoined. Commands and code keep their line breaks. A plain `⌘V` pastes the cleaned text, and `⇧↩` in history pastes the original.
- **Plain text only**: clips keep their text, not their formatting.

| Key | Action |
|---|---|
| `↩` / `⌘↩` | Paste into the app you were in / copy only (swappable in Settings) |
| `⇧↩` | Paste the original of a cleaned-up terminal copy |
| `⌘P` | Pin (never expires) |
| `⌘R` | Reveal a masked secret |
| `⌘⌫` | Delete (on every Mac) |
| `↑` `↓` | Move through clips |
| `⇧⌘↑` `⇧⌘↓` | Move through the sidebar filters |
| `⇥` | Next filter |
| `⌘1`–`⌘9` | Paste one of the first nine clips |

### Settings

The Settings window has these pages:
- **General**: launcher and clipboard hotkeys, show apps in the launcher, **show Portal in the menu bar**, open at login, and permissions.
- **Quicklinks**
- **Snippets**
- **Open With**
- **Clipboard**: retention, secrets, terminal cleanup, and apps to ignore.
- **Sync**

While Settings is open, Portal gets a Dock icon and appears in ⌘Tab. If the menu bar icon is hidden, open Settings from the launcher ("settings") or by opening Portal again.

## Sync

Turn on Settings → Sync on each Mac and use the same folder:
`~/Library/Mobile Documents/com~apple~CloudDocs/Portal`.

| What | How |
|---|---|
| Quicklinks, snippets, Open With, clipboard settings, hotkeys | `settings.json` in the sync folder. Polled every few seconds; the last save wins |
| Clipboard history | One AES-256-GCM encrypted file per clip, per Mac. Needs the same passphrase on each Mac |
| Folder snippets | `.portal.json`, committed to each repo, so they sync through git |
| Stays on each Mac | Whether sync is on, open at login, permissions, the passphrase (in the Keychain), and launcher ranking |

**How the clipboard files work:**
- Each Mac writes only its own files, `Clipboard/<machine-id>/<ms>_<uuid>_<flags>.clip`, so two Macs never write the same file.
- The pinned and secret flags are part of the filename, so any Mac can delete expired clips without decrypting them.
- `keycheck.json` holds the salt and an encrypted check value, so a wrong passphrase is caught immediately. The passphrase never leaves the Mac.

## Install

Requirements:
- **macOS 26** or later.
- **Full Xcode.** The Command Line Tools alone can't build it, because on the macOS 27 SDK SwiftUI's `@State` is a macro whose plugin only ships with Xcode.
- An **Apple Development** signing certificate. Signing in to Xcode → Settings → Accounts creates one. Without it, the app is signed ad hoc and macOS forgets Portal's permissions on every rebuild.

```sh
git clone https://github.com/martyvasquez/portal.git ~/Development/app-launcher
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # if Command Line Tools are selected
cd ~/Development/app-launcher && scripts/build.sh --install
```

**To update** (the repo's `.portal.json` also has this as the **Update Portal** snippet):

```sh
cd ~/Development/app-launcher && git pull && scripts/build.sh --install
```

### First run on each Mac

1. Quit Raycast, or free ⌘Space some other way. Settings → General warns you if macOS or another app still holds it.
2. Settings → General → **Accessibility** → Allow. This lets Portal paste into other apps.
3. If macOS asks whether Portal may paste from other apps, choose **Always Allow**.
4. Settings → Sync → enter the **same passphrase** on every Mac.
5. Allow Portal to control **Finder, Ghostty, Terminal, and your browser** when macOS asks. It reads only the current folder or page. If you clicked Don't Allow, you can change it in System Settings → Privacy & Security → Automation.

## Development

```sh
scripts/build.sh --install          # build (release), sign, install to /Applications, relaunch
swift test                          # unit tests
scripts/show.sh launcher            # open a surface: launcher | clipboard | new | settings
scripts/show.sh page:snippets       # open Settings on a page: general | quicklinks | snippets | openWith | clipboard | sync
swift scripts/make-icon.swift .     # rebuild Resources/AppIcon.icns from Resources/icon-source.png
```

To change the app icon, replace `Resources/icon-source.png` (any size, on a transparent or
black background) and run the icon script, then `scripts/build.sh --install`. The script
trims the background (ignoring stray specks), fits the art to Apple's icon grid, and fills
the whole icon shape so macOS 26 doesn't put it on a gray plate.

| File | What's in it |
|---|---|
| `PortalApp.swift` | App delegate, hotkeys, menu bar, Settings window |
| `Launcher.swift`, `LauncherView.swift` | Launcher model (ranking, actions, snippet context) and view |
| `Snippets.swift` | Snippet model, folder and browser detection, `.portal.json`, command detection, pasting |
| `FinderSelection.swift` | Finder selection and Open With |
| `ClipStore.swift`, `ClipboardMonitor.swift`, `ClipboardView.swift` | Clipboard storage and sync, capture, and window |
| `TerminalText.swift` | Terminal copy cleanup |
| `Crypto.swift` | Key derivation, AES-GCM, Keychain, and the passphrase check |
| `Settings.swift`, `SettingsView.swift` | Synced settings and the Settings window |
| `Theme.swift` | Colors and components (shared design with Managed / Things 3) |
| `Panel.swift`, `System.swift` | Floating panels, Carbon hotkeys, conflict checks, login item, permissions |
