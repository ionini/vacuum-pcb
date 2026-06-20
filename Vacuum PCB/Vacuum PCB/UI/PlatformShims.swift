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

extension View {
    /// Checkbox toggle style for dense, leading-aligned check lists. `.checkbox`
    /// is macOS-only; on iPad it's unavailable, so fall back to the standard
    /// switch (the closest "on/off per row" affordance touch users expect).
    @ViewBuilder
    func checklistToggleStyle() -> some View {
        #if canImport(AppKit)
        self.toggleStyle(.checkbox)
        #else
        self.toggleStyle(.switch)
        #endif
    }
}

/// True when the platform's primary input is a finger rather than a
/// cursor. Used by views that need to grow hit targets, drop hover-only
/// affordances, or raise drag thresholds on iPad.
enum InputPlatform {
    #if canImport(AppKit)
    static let isTouch = false
    /// System double-click speed, so hand-rolled double-tap detection matches
    /// what the user set in System Settings.
    static var doubleTapInterval: TimeInterval { NSEvent.doubleClickInterval }
    #else
    static let isTouch = true
    /// iPadOS exposes no public double-tap interval; ~300 ms matches the
    /// platform default closely enough.
    static var doubleTapInterval: TimeInterval { 0.35 }
    #endif
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
