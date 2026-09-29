# Portal

A small personal quicklinks launcher + clipboard manager for macOS (replacing Raycast).

- **Quicklinks** (managed in Settings): a name, a folder or URL, and the app it opens in
  (Finder, Ghostty, Chrome, anything). Optional global hotkey per quicklink. Put `{query}`
  in a link to be asked for text when you open it.
- **Snippets**: the launcher shows text to paste for where you are: the current folder's
  snippets first (from `.portal.json`, found by walking up from the folder open in Finder,
  Ghostty, or Terminal), then the front app's, then global ones (Settings → Snippets).
  **Build / Update Commands** in the launcher seeds `.portal.json` from the repo's
  `package.json` scripts, Makefile/justfile targets, `scripts/*.sh`, and toolchain files;
  after that it's your file to edit. Updates only add new commands, never re-add deleted ones.
- **Open With** (Settings → Open With): with Finder in front, the launcher offers apps for
  the selection: one ordered list for folders (e.g. Ghostty → Terminal → Sublime Text), one
  for files. The first app is the default. Excluded file types (images, PDFs, archives, …)
  open their folder instead. Optional hotkey opens the selection with the defaults.
- **⌘Space**: pick a quicklink or app. `↩` opens, `⌘↩` opens with the default app instead
  (Finder / default browser), `⌥↩` copies the link, `⌘1`–`⌘9` open the top results.
- **⇧⌘V**: clipboard history with search, filters (This Mac / Other Macs / Secrets / Pinned), pins, and paste-into-app.
- **Sync**: settings and clipboard history sync through a folder in iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/Portal`).
  Clips are encrypted (AES-256-GCM, passphrase-derived key) before they're written there, and expire after 7 days by default.

## Build

```sh
scripts/build.sh --install   # build, sign, copy to /Applications, relaunch
swift test                   # unit tests
scripts/show.sh launcher     # open a surface from the terminal: launcher | clipboard | new | settings
```

## One-time setup on each Mac

1. Quit Raycast, or change its hotkey. Make sure Spotlight isn't on ⌘Space (Settings → General shows a warning if anything conflicts).
2. Grant **Accessibility** (Settings → General) so clips can be pasted straight into the app you were using.
3. If macOS asks whether Portal can paste from other apps, choose **Always Allow**.
4. Settings → Sync → set the same passphrase on both Macs.

## How sync works

Each Mac writes only its own files, `Clipboard/<machine-id>/<time>_<id>_<flags>.clip`, so two Macs never write the same file.
Expiry, pinned, and secret flags are in the filename, so any Mac can prune expired clips without decrypting them.
`keycheck.json` holds the salt and an encrypted check value so a wrong passphrase is caught immediately. The passphrase itself never leaves the Mac's Keychain.
