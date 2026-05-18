import Foundation

/// Tunable constants for the in-app pneumatic simulator. Lives in-memory only
/// (not persisted into the .vpcb); the Simulate tab surfaces a few of these as
/// sliders so the user can calibrate against real silicone/dimple behaviour
/// without recompiling. Values are unitless — we work in a scaled pressure
/// (0 = vacuum, 1 = atm), a scaled conductance, and a scaled volume.
struct SimulationParameters: Equatable {
    /// Conductance of the channel inside a resistor body, per millimetre of
    /// serpentine path. Smaller diameter than transport channels, so each mm
    /// restricts flow more.
    var resistorResistancePerMm: Double

    /// Conductance of a transistor's source-drain path when the gate is fully
    /// asserted (gate net at vacuum). Higher = the channel passes vacuum to
    /// the drain faster.
    var transistorOnConductance: Double

    /// Conductance when the transistor is "closed". Set above zero so the
    /// solver stays well-conditioned even with isolated subgraphs.
    var transistorOffConductance: Double

    /// Pressure at which the source-drain path is half open. Gate at vacuum
    /// opens the valve (silicone sucked into the dimple); gate at atmosphere
    /// closes it.
    var gateThreshold: Double

    /// Half-width of the linear ramp around `gateThreshold` between off and
    /// on. Smoothing keeps the integrator from chattering between states.
    var gateHysteresis: Double

    /// Per-net baseline capacitance contribution per fluid pin. Encodes the
    /// "dead volume" at each pin (drop bore, dimple cavity) so that even an
    /// unrouted net has some inertia and can't change pressure instantly.
    var nodeBaseCapacitance: Double

    /// Volume contribution of route channels, per millimetre of polyline.
    /// Added on top of `nodeBaseCapacitance` whenever a net has routes.
    var channelCapacitancePerMm: Double

    /// Fixed simulator time step, in seconds. Backward Euler is stable for
    /// any step but accuracy degrades for very large steps relative to the
    /// fastest RC.
    var dtSeconds: Double

    /// Real seconds per simulated second. 1.0 = realtime; higher = faster.
    var timeScale: Double

    // Defaults are sized for crisp digital-style swings on the canonical
    // NMOS inverter while still letting an unloaded net equalize back to
    // atmosphere in a couple of seconds. We want G_off ≪ G_resistor ≪
    // G_on. Capacitances are kept low so the visible time constant for a
    // small resistor (S, 12 mm) is around 1 s; large resistors lag
    // noticeably more without dragging into uncomfortable territory.
    //
    // Gate threshold defaults to 0.3 — the transistor only opens when the
    // gate is reasonably close to vacuum, so a partially-pulled gate net
    // doesn't accidentally trigger the switch. Bumping it back up toward
    // 0.5 from the sidebar slider widens the activation band.
    static let defaults = SimulationParameters(
        resistorResistancePerMm: 0.5,
        transistorOnConductance: 5.0,
        transistorOffConductance: 0.0005,
        gateThreshold: 0.3,
        gateHysteresis: 0.08,
        nodeBaseCapacitance: 0.10,
        channelCapacitancePerMm: 0.04,
        dtSeconds: 0.01,
        timeScale: 1.0
    )

    /// Smooth-step blend between `transistorOffConductance` (gate at atm) and
    /// `transistorOnConductance` (gate at vacuum). NMOS-equivalent: a low
    /// gate pressure (closer to 0) means open; a high gate pressure (closer
    /// to 1) means closed.
    func conductance(forGatePressure p: Double) -> Double {
        let lo = gateThreshold - gateHysteresis
        let hi = gateThreshold + gateHysteresis
        let t: Double
        if p <= lo { t = 0 }
        else if p >= hi { t = 1 }
        else { t = (p - lo) / (hi - lo) }
        // p=0 → t=0 → on; p=1 → t=1 → off.
        return transistorOnConductance + t * (transistorOffConductance - transistorOnConductance)
    }
}
