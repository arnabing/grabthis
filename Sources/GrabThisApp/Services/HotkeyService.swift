import AppKit
import Foundation

@MainActor
final class HotkeyService {
    enum TriggerSource {
        case fn
        case fallback
    }

    struct FallbackShortcut: Equatable {
        var keyCode: UInt16
        var requiresOption: Bool
        var requiresCommand: Bool
        var requiresControl: Bool
        var requiresShift: Bool

        static let optionSpace = FallbackShortcut(
            keyCode: 49, // space
            requiresOption: true,
            requiresCommand: false,
            requiresControl: false,
            requiresShift: false
        )
    }

    enum State: Equatable {
        case idle
        case listening(source: TriggerSource)
        case processing
    }

    private let appState: AppState
    private let onStateChange: (State) -> Void

    private var state: State = .idle {
        didSet { onStateChange(state) }
    }

    private var fallbackShortcut: FallbackShortcut = .optionSpace

    private var flagsMonitorGlobal: Any?
    private var flagsMonitorLocal: Any?
    private var keyDownMonitorGlobal: Any?
    private var keyUpMonitorGlobal: Any?
    private var keyDownMonitorLocal: Any?
    private var keyUpMonitorLocal: Any?

    private var fnIsDown: Bool = false
    private var fallbackIsDown: Bool = false
    private var beginTimestamp: Date?

    init(appState: AppState, onStateChange: @escaping (State) -> Void) {
        self.appState = appState
        self.onStateChange = onStateChange
    }

    func start() {
        stop()
        Log.hotkey.info("hotkey monitors starting")

        flagsMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }
        flagsMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        keyDownMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyDown(event)
            }
        }
        keyUpMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyUp(event)
            }
        }

        keyDownMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyDown(event)
            }
            return event
        }
        keyUpMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyUp(event)
            }
            return event
        }
    }

    func stop() {
        for monitor in [flagsMonitorGlobal, flagsMonitorLocal, keyDownMonitorGlobal, keyUpMonitorGlobal, keyDownMonitorLocal, keyUpMonitorLocal] {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        flagsMonitorGlobal = nil
        flagsMonitorLocal = nil
        keyDownMonitorGlobal = nil
        keyUpMonitorGlobal = nil
        keyDownMonitorLocal = nil
        keyUpMonitorLocal = nil

        fnIsDown = false
        fallbackIsDown = false
        beginTimestamp = nil
        state = .idle
    }
}

private extension HotkeyService {
    func handleFlagsChanged(_ event: NSEvent) {
        guard appState.isEnabled else { return }

        let isFnNowDown = event.modifierFlags.contains(.function)
        if isFnNowDown != fnIsDown {
            fnIsDown = isFnNowDown
            if fnIsDown {
                beginListening(source: .fn)
            } else {
                endListeningIfNeeded(source: .fn)
            }
        }
    }

    func handleKeyDown(_ event: NSEvent) {
        guard appState.isEnabled else { return }
        guard !event.isARepeat else { return }

        if matchesFallbackDown(event) {
            fallbackIsDown = true
            beginListening(source: .fallback)
        }
    }

    func handleKeyUp(_ event: NSEvent) {
        guard appState.isEnabled else { return }

        if matchesFallbackUp(event) {
            fallbackIsDown = false
            endListeningIfNeeded(source: .fallback)
        }
    }

    func beginListening(source: TriggerSource) {
        switch state {
        case .idle:
            beginTimestamp = Date()
            Log.hotkey.info("beginListening source=\(String(describing: source), privacy: .public)")
            state = .listening(source: source)
        case .listening, .processing:
            break
        }
    }

    func endListeningIfNeeded(source: TriggerSource) {
        switch state {
        case .listening(let currentSource):
            guard currentSource == source else { return }
            if let beginTimestamp {
                let ms = Int(Date().timeIntervalSince(beginTimestamp) * 1000.0)
                Log.hotkey.info("endListening source=\(String(describing: source), privacy: .public) heldMs=\(ms, privacy: .public)")
            } else {
                Log.hotkey.info("endListening source=\(String(describing: source), privacy: .public)")
            }
            state = .processing
            // Placeholder: later we’ll kick off capture+audio+STT+LLM.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.state = .idle
            }
        case .idle, .processing:
            break
        }
    }

    func matchesFallbackDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == fallbackShortcut.keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if fallbackShortcut.requiresOption, !flags.contains(.option) { return false }
        if fallbackShortcut.requiresCommand, !flags.contains(.command) { return false }
        if fallbackShortcut.requiresControl, !flags.contains(.control) { return false }
        if fallbackShortcut.requiresShift, !flags.contains(.shift) { return false }
        return true
    }

    func matchesFallbackUp(_ event: NSEvent) -> Bool {
        // KeyUp may not include full flags; treat keyCode match as release for MVP.
        event.keyCode == fallbackShortcut.keyCode
    }
}


