import SwiftUI

/// Shared colour ramp for the pneumatic simulator. Maps absolute pressure
/// `[0, 1]` (0 = vacuum, 1 = atm) to a perceptually distinct colour so the
/// "active" end (vacuum) stands out from the resting atmosphere baseline.
///
/// Vacuum is rendered as a saturated blue and atmosphere as a neutral grey —
/// matches the convention picked when the feature was scoped: this device's
/// active signal is vacuum, so the eye-catching end of the ramp goes there.
enum PressureColor {
    /// Continuous colour for net / route fills. `pressure` is clamped to 0…1.
    static func color(for pressure: Double) -> Color {
        let p = max(0, min(1, pressure))
        // Lerp from saturated blue (p=0) → neutral grey (p=1).
        let vacuum = (h: 0.60, s: 0.85, b: 0.95)         // bright blue
        let atm    = (h: 0.60, s: 0.05, b: 0.85)         // near-grey
        let s = vacuum.s + p * (atm.s - vacuum.s)
        let b = vacuum.b + p * (atm.b - vacuum.b)
        return Color(hue: vacuum.h, saturation: s, brightness: b)
    }

    /// Stroke variant — same hue, slightly darker so net lines read clearly
    /// against the matching pressure-tinted fills they pass through.
    static func strokeColor(for pressure: Double) -> Color {
        let p = max(0, min(1, pressure))
        let vacuum = (h: 0.60, s: 0.95, b: 0.80)
        let atm    = (h: 0.60, s: 0.10, b: 0.55)
        let s = vacuum.s + p * (atm.s - vacuum.s)
        let b = vacuum.b + p * (atm.b - vacuum.b)
        return Color(hue: vacuum.h, saturation: s, brightness: b)
    }

    /// Human-readable label for a pressure value, used in sidebar readouts
    /// and tooltips. Three significant figures; explicit "vac" / "atm"
    /// snaps when close to the rails so the user reads state at a glance.
    static func formatted(_ pressure: Double) -> String {
        if pressure <= 0.02 { return "vac" }
        if pressure >= 0.98 { return "atm" }
        return String(format: "%.2f", pressure)
    }
}
