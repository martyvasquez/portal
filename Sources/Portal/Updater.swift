import AppKit
import Sparkle

/// Keeps Portal up to date from GitHub Releases (martyvasquez/portal). Portal runs for weeks
/// without quitting, so a check at launch isn't enough: Sparkle also checks every few hours
/// (SUScheduledCheckInterval) and after the Mac wakes. Updates download in the background and
/// install once Portal is idle, so a relaunch never lands mid-search or mid-paste.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    /// Whether Portal is in use (a panel or Settings open). Set by the app delegate.
    var isBusy: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var idleTimer: Timer?
    private var lastBusy = Date()

    /// Starts the updater and checks right away. Only for builds that know where to look,
    /// so `swift run` and tests never replace themselves.
    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        c.updater.checkForUpdatesInBackground()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.checkAfterWake() }
        }
    }

    var canCheck: Bool { controller != nil }

    /// "Check for Updates…": shows Sparkle's window, so Portal comes forward first.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// A Mac that slept through the scheduled checks catches up when it wakes.
    private func checkAfterWake() {
        guard let updater = controller?.updater else { return }
        if let last = updater.lastUpdateCheckDate, Date().timeIntervalSince(last) < 3600 { return }
        updater.checkForUpdatesInBackground()
    }

    // MARK: Install when idle

    // Sparkle would otherwise wait for Portal to quit, which may be weeks away.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            pendingInstall = immediateInstallHandler
            lastBusy = Date()
            idleTimer?.invalidate()
            idleTimer = .scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                MainActor.assumeIsolated { AppUpdater.shared.installIfIdle() }
            }
        }
        return true
    }

    /// Installs (and relaunches) once Portal has gone unused for a minute.
    private func installIfIdle() {
        if isBusy() { lastBusy = Date(); return }
        guard Date().timeIntervalSince(lastBusy) >= 60, let install = pendingInstall else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        pendingInstall = nil
        install()
    }

    // Portal is a menu bar app; this keeps Sparkle from warning about background update alerts.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
