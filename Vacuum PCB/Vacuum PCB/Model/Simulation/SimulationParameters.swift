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

    /// Deepest scaled pressure a pump can reach at zero flow (deadhead). A
    /// real diaphragm pump can't reach absolute vacuum — it stalls somewhere
    /// short of it. 0 = perfect pump; 0.2 = pump asymptotes to 20% of atm.
    var pumpMaxVacuum: Double

    /// Pump conductance at the free-flow point (net at atmosphere). Replaces
    /// the previous "infinite" hard-anchor behaviour. Higher = pump moves
    /// more air per unit pressure differential, so the source net is dragged
    /// closer to `pumpMaxVacuum` even under heavy leakage from atm.
    var pumpFlowCapacity: Double

    /// Conductance of a bidirectional connector pin's *soft* drive (a bus
    /// terminal the user has asserted to Vac/Atm during standalone sim). Sized
    /// to match `transistorOnConductance` so a poked bus pin behaves like one
    /// on-board pass transistor tied to a rail — strong enough to move an
    /// otherwise-idle bus, weak enough that a real on-board driver pulling the
    /// other way still contends rather than being clamped out.
    var busDriveConductance: Double

    /// Shape of the pump's Q-vs-P curve. Exponent on the normalised remaining
    /// differential; effective flow follows `Q/Q_max = P_norm^(droop + 1)`.
    ///   0  = linear — flow drops in proportion to the remaining differential.
    ///   >0 = concave — pump struggles near deadhead (flow falls below the
    ///        linear line). Some diaphragm pumps behave this way.
    ///   <0 = convex — pump holds flow well in the middle range and then
    ///        knees down sharply near deadhead. Typical of pumps whose
    ///        measured curve drops 0.2 L/min near atmosphere but 0.35 L/min
    ///        near max vacuum (the per-step loss accelerates).
    /// Must stay > −1 so flow still reaches 0 at deadhead.
    var pumpDroopExponent: Double

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
        resistorResistancePerMm: 0.05,
        transistorOnConductance: 5.0,
        transistorOffConductance: 0.0005,
        gateThreshold: 0.3,
        gateHysteresis: 0.08,
        nodeBaseCapacitance: 0.10,
        channelCapacitancePerMm: 0.04,
        dtSeconds: 0.01,
        timeScale: 1.0,
        // Pump defaults are tuned for clean digital-style swings rather than
        // a specific weak bench pump: a strong deadhead near full vacuum
        // (P_scaled ≈ 0.1, ~−91 kPa) so a Vac-driven net clears the 0.3 gate
        // threshold and actually switches a transistor, and a generous free
        // flow so rails hold their vacuum under load. The user can dial these
        // back toward a measured curve from the sidebar sliders.
        pumpMaxVacuum: 0.1,
        pumpFlowCapacity: 10.0,
        busDriveConductance: 5.0,
        pumpDroopExponent: -0.14
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

    /// 0…1 "open fraction" of the gate ramp at a given net pressure, using
    /// the same threshold and hysteresis the transistor solver uses. 1 = the
    /// silicone is sucked fully into the dimple (transistor on, LED lit);
    /// 0 = the silicone is at rest against atmosphere (transistor closed,
    /// LED dark). LEDs share this with transistors because they're the same
    /// dimple — the user tunes one threshold and both surfaces follow.
    func gateOpenness(forPressure p: Double) -> Double {
        let lo = gateThreshold - gateHysteresis
        let hi = gateThreshold + gateHysteresis
        if p <= lo { return 1 }
        if p >= hi { return 0 }
        return 1 - (p - lo) / (hi - lo)
    }

    /// Effective pump conductance at the given source-net pressure. Treats
    /// the pump as a resistive edge from the net to a virtual anchor held at
    /// `pumpMaxVacuum`; the conductance is `pumpFlowCapacity` at atmosphere
    /// and falls off according to `pumpDroopExponent` as the net approaches
    /// max vacuum. Returns 0 once the net is at or below max vacuum, so the
    /// pump never *injects* pressure into the channel.
    func pumpConductance(forNetPressure p: Double) -> Double {
        let pMin = pumpMaxVacuum
        let diff = p - pMin
        guard diff > 0 else { return 0 }
        let span = max(1e-6, 1.0 - pMin)
        let diffNorm = min(1.0, diff / span)
        // Allow negative droop for convex curves. Clamp above −1 so flow
        // still reaches zero at deadhead, and cap the shape so an
        // aggressively convex curve at tiny `diffNorm` doesn't blow up the
        // matrix conditioning.
        let droop = max(-0.99, pumpDroopExponent)
        let shape = droop == 0 ? 1.0 : min(100.0, pow(diffNorm, droop))
        return pumpFlowCapacity * shape
    }
}
