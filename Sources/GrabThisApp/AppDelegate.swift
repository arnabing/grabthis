import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var onboardingWindowController: NSWindowController?
    private var historyWindowController: NSWindowController?
    private let overlay = OverlayPanelController()
    private lazy var sessionController = SessionController(overlay: overlay)
    private lazy var hotkeyService = HotkeyService(appState: AppState.shared) { [weak self] state in
        self?.handleHotkeyState(state)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.app.info("launched bundleId=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public) exe=\(Bundle.main.executableURL?.path ?? "nil", privacy: .public)")
        Log.app.info("versions short=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "nil", privacy: .public) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "nil", privacy: .public)")
        let cs = CodeSigningInfo.current()
        Log.app.info("codesign status=\(cs.statusDescription, privacy: .public) signed=\(cs.isSigned, privacy: .public) teamId=\(cs.teamID ?? "nil", privacy: .public) signingId=\(cs.signingIdentifier ?? "nil", privacy: .public)")
        if !cs.isSigned {
            Log.app.error("TCC will not persist across rebuilds while app is unsigned. Run scripts/build_app_bundle.sh with a stable GRABTHIS_CODESIGN_IDENTITY.")
        }
        setupStatusItem()
        maybeShowOnboarding()
        hotkeyService.start()

        // Force SessionController initialization to show idle chip on startup
        _ = sessionController
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private extension AppDelegate {
    func handleHotkeyState(_ state: HotkeyService.State) {
        switch state {
        case .idle:
            // no-op; idle transitions are driven by key up from listening.
            break
        case .listening:
            overlay.model.onClose = { [weak self] in self?.sessionController.cancel() }
            overlay.model.onSend = { [weak self] in self?.sessionController.sendToAI() }
            overlay.model.onCopy = { [weak self] in self?.sessionController.copyTranscript() }
            overlay.model.onInsert = { [weak self] in self?.sessionController.insertTranscript() }
            sessionController.begin()
        case .processing:
            sessionController.end()
        }
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "grabthis"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Onboarding", action: #selector(openOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Screen Recording Settings", action: #selector(openScreenRecordingSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Test Overlay", action: #selector(testOverlay), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Test Capture (Display)", action: #selector(testCapture), keyEquivalent: "c"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit grabthis", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu

        self.statusItem = item
    }

    func maybeShowOnboarding() {
        let needsOnboarding = !UserDefaults.standard.bool(forKey: AppState.Keys.onboardingCompleted)
        if needsOnboarding {
            openOnboarding()
        }
    }

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    @objc func openOnboarding() {
        if onboardingWindowController != nil {
            onboardingWindowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to grabthis"
        window.setContentSize(NSSize(width: 520, height: 420))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false

        let wc = NSWindowController(window: window)
        self.onboardingWindowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openHistory() {
        if historyWindowController != nil {
            historyWindowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HistoryView()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "grabthis History"
        window.setContentSize(NSSize(width: 860, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        let wc = NSWindowController(window: window)
        self.historyWindowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() {
        hotkeyService.stop()
        NSApp.terminate(nil)
    }

    @objc func testOverlay() {
        overlay.model.onClose = { [weak self] in self?.overlay.hide() }
        overlay.presentListening(appName: "grabthis", screenshot: nil, transcript: "Say something…")
    }

    @objc func openScreenRecordingSettings() {
        SystemSettingsDeepLinks.openScreenRecording()
    }

    @objc func openInputMonitoringSettings() {
        SystemSettingsDeepLinks.openInputMonitoring()
    }

    @objc func testCapture() {
        Task { @MainActor in
            guard let ctx = ActiveAppContextProvider.current() else { return }
            do {
                let result = try await CaptureService.captureActiveWindow()
                NSLog("grabthis capture test app=%@ bundle=%@ pid=%d result=%dx%d scale=%@",
                      ctx.appName,
                      ctx.bundleIdentifier ?? "nil",
                      ctx.pid,
                      result.pixelWidth,
                      result.pixelHeight,
                      "\(result.scale)")
            } catch {
                NSLog("grabthis capture test failed: %@", String(describing: error))
            }
        }
    }
}


