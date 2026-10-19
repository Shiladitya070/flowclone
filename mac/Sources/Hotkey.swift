import AppKit

/// Global keyboard monitor on an ACTIVE event tap (.defaultTap), so it can swallow the keys it owns
/// (Esc while dictating, ⌃⌥V). Needs Accessibility. The tap source lives on the main run loop, so every
/// callback runs on main. The caller must keep a strong reference to the monitor while it is running,
/// because the tap holds it unretained.
final class InputMonitor {
    /// Dictation key pressed (true) / released (false). Delivered async so the tap returns instantly.
    /// The modifier event itself is never swallowed.
    var onTrigger: ((Bool) -> Void)?
    /// Esc pressed. Called synchronously; return true to swallow the key (and its autorepeats).
    var onEscape: (() -> Bool)?
    /// ⌃⌥V pressed. Called async on main. The key is always swallowed.
    var onPasteLast: (() -> Void)?

    private static let escKeyCode: Int64 = 53
    private static let vKeyCode: Int64 = 9

    private var keyCode: Int64 = 63
    private var flag: CGEventFlags = .maskSecondaryFn
    private var tap: CFMachPort?
    private var isDown = false
    private var escSwallowed = false

    /// "fn" (default), "right_option", "right_command" or "right_control". Works while running.
    func setHotkey(_ name: String) {
        switch name {
        case "right_option": keyCode = 61; flag = .maskAlternate
        case "right_command": keyCode = 54; flag = .maskCommand
        case "right_control": keyCode = 62; flag = .maskControl
        default: keyCode = 63; flag = .maskSecondaryFn // fn / globe
        }
        isDown = false
    }

    /// Idempotent. Returns false if the tap cannot be created (usually: Accessibility not granted yet).
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
            | CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Returns nil to swallow the event, or the event to pass it through.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged:
            guard code == keyCode else { return pass }
            let down = event.flags.contains(flag)
            guard down != isDown else { return pass } // edge-detect only
            isDown = down
            DispatchQueue.main.async { [weak self] in self?.onTrigger?(down) }
            return pass

        case .keyDown:
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if code == Self.escKeyCode {
                if repeated { return escSwallowed ? nil : pass }
                escSwallowed = onEscape?() ?? false
                return escSwallowed ? nil : pass
            }
            let flags = event.flags
            if code == Self.vKeyCode, flags.contains(.maskControl), flags.contains(.maskAlternate),
               !flags.contains(.maskCommand) {
                if !repeated { DispatchQueue.main.async { [weak self] in self?.onPasteLast?() } }
                return nil
            }
            return pass

        default:
            return pass
        }
    }
}
