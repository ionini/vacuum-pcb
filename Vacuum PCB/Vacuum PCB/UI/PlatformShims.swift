import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#endif

/// Background colours used by the editor canvases. On macOS these resolve to
/// the standard window / control chrome colours; on iOS we pick the closest
/// system equivalent so the canvas reads as a recessed editing surface.
extension Color {
    static var canvasBackground: Color {
        #if canImport(AppKit)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }

    /// Renamed from `windowBackground` to avoid colliding with the new
    /// `ShapeStyle.windowBackground` built into SwiftUI 26 — the type
    /// inference falls over at call sites that expect `Color`.
    static var paneBackground: Color {
        #if canImport(AppKit)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }
}

/// Modifier-key probe used by gesture handlers that branch on Cmd/Option.
/// On macOS this peeks at the current `NSEvent.modifierFlags`; on iPad
/// touches don't carry modifiers, so every probe is `false`. The code paths
/// that depend on Cmd / Option simply degrade to their plain-tap behaviour.
enum ModifierKeys {
    static var commandHeld: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    static var optionHeld: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }
}
