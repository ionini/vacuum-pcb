import SwiftUI

/// Shared colour ramp for the pneumatic simulator. Maps pressure
/// (0 = hard vacuum, 1 = atm) to a perceptually distinct colour so the
/// "active" end (vacuum) stands out from the resting atmosphere baseline.
///
/// Vacuum is rendered as a saturated blue and atmosphere as a neutral grey —
/// matches the convention picked when the feature was scoped: this device's
/// active signal is vacuum, so the eye-catching end of the ramp goes there.
///
/// The ramp spans the *reachable* pressure range, not the absolute 0…1 scale:
/// `maxVacuum` is the pump's deadhead (`SimulationParameters.pumpMaxVacuum`,
/// the "Max vac" slider) — the deepest pressure the current setup can produce —
/// and it maps to full blue. With the bench-calibrated deadhead at 0.4, an
/// absolute ramp would confine every net to its washed-out top 60% and the
/// whole view reads grey.
enum PressureColor {
    /// Continuous colour for net / route fills.
    static func color(for pressure: Double, maxVacuum: Double) -> Color {
        let t = depth(of: pressure, maxVacuum: maxVacuum)
        let vacuum = (h: 0.60, s: 0.85, b: 0.95)         // bright blue
        let atm    = (h: 0.60, s: 0.05, b: 0.85)         // near-grey
        let s = vacuum.s + t * (atm.s - vacuum.s)
        let b = vacuum.b + t * (atm.b - vacuum.b)
        return Color(hue: vacuum.h, saturation: s, brightness: b)
    }

    /// Stroke variant — same hue, slightly darker so net lines read clearly
    /// against the matching pressure-tinted fills they pass through.
    static func strokeColor(for pressure: Double, maxVacuum: Double) -> Color {
        let t = depth(of: pressure, maxVacuum: maxVacuum)
        let vacuum = (h: 0.60, s: 0.95, b: 0.80)
        let atm    = (h: 0.60, s: 0.10, b: 0.55)
        let s = vacuum.s + t * (atm.s - vacuum.s)
        let b = vacuum.b + t * (atm.b - vacuum.b)
        return Color(hue: vacuum.h, saturation: s, brightness: b)
    }

    /// Human-readable label for a pressure value, used in sidebar readouts
    /// and tooltips. Three significant figures; explicit "vac" / "atm"
    /// snaps when close to the rails so the user reads state at a glance.
    /// Deliberately absolute (no `maxVacuum` rescale): the numbers must stay
    /// comparable with bench readings and CLI output.
    static func formatted(_ pressure: Double) -> String {
        if pressure <= 0.02 { return "vac" }
        if pressure >= 0.98 { return "atm" }
        return String(format: "%.2f", pressure)
    }

    /// Position of `pressure` within the reachable range `[maxVacuum, 1]`,
    /// clamped to 0…1. Anything at or below the deadhead saturates to full
    /// blue (inputs driven to 0.0 and ideal sources land here); a degenerate
    /// deadhead near atm (CLI can set any value) keeps the ramp finite.
    private static func depth(of pressure: Double, maxVacuum: Double) -> Double {
        let floor = min(max(maxVacuum, 0), 0.99)
        return max(0, min(1, (pressure - floor) / (1 - floor)))
    }
}
