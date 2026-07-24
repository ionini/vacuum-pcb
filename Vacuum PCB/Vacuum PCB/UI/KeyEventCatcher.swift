import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Window-level keyboard handler that doesn't depend on SwiftUI focus.
///
/// On macOS this installs an `NSEvent.addLocalMonitorForEvents` while it's
/// attached to a window and consumes matching key presses regardless of
/// focus, except when a text field is the first responder (in which case
/// the event passes through). On iOS / iPad there's no equivalent global
/// hardware-keyboard monitor route from SwiftUI without UIKit
/// gymnastics, so this becomes a no-op — keyboard shortcuts only fire
/// when the user attaches an external keyboard via the system's own
/// focus path, which isn't wired up in v1 of the iPad build.
struct KeyEventCatcher: View {
    let handlers: [UInt16: () -> Void]
    let commandHandlers: [UInt16: () -> Void]

    init(handlers: [UInt16: () -> Void], commandHandlers: [UInt16: () -> Void] = [:]) {
        self.handlers = handlers
        self.commandHandlers = commandHandlers
    }

    var body: some View {
        #if canImport(AppKit)
        KeyEventCatcherRepresentable(handlers: handlers, commandHandlers: commandHandlers)
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }
}

#if canImport(AppKit)

private struct KeyEventCatcherRepresentable: NSViewRepresentable {
    let handlers: [UInt16: () -> Void]
    let commandHandlers: [UInt16: () -> Void]

    func makeNSView(context: Context) -> KeyEventCatcherView {
        let v = KeyEventCatcherView()
        v.handlers = handlers
        v.commandHandlers = commandHandlers
        return v
    }

    func updateNSView(_ nsView: KeyEventCatcherView, context: Context) {
        nsView.handlers = handlers
        nsView.commandHandlers = commandHandlers
    }
}

final class KeyEventCatcherView: NSView {
    var handlers: [UInt16: () -> Void] = [:]
    var commandHandlers: [UInt16: () -> Void] = [:]
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let win = self.window,
                  event.window === win
            else { return event }
            if let responder = win.firstResponder,
               responder is NSText || responder is NSTextView {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdOnly = flags == .command
            let isPlain   = flags.subtracting([.shift, .capsLock, .function, .numericPad]).isEmpty
            if isCmdOnly, let handler = self.commandHandlers[event.keyCode] {
                handler()
                return nil
            }
            if isPlain, let handler = self.handlers[event.keyCode] {
                handler()
                return nil
            }
            return event
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

#endif

/// Common AppKit virtual key codes used by this app. Kept available on iOS
/// so the `commandHandlers` / `handlers` dictionaries that reference them
/// continue to compile — the values are simply never matched against an
/// event when running on iPad.
enum KeyCodes {
    static let delete: UInt16        = 51
    static let space: UInt16         = 49
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16        = 53
    static let r: UInt16             = 15
    static let f: UInt16             = 3
    static let c: UInt16             = 8
    static let v: UInt16             = 9
    static let x: UInt16             = 7
    static let equals: UInt16        = 24
    static let minus: UInt16         = 27
    static let zero: UInt16          = 29

    static let digit: [UInt16] = [
        29, 18, 19, 20, 21, 23, 22, 26, 28, 25
    ]
}
