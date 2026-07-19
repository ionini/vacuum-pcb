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

    /// Global leak conductance. Models the silicone/PCB sandwich never being
    /// perfectly sealed: every net gets a faint conductive edge to atmosphere,
    /// so any segment holding vacuum bleeds back toward atm at a rate
    /// proportional to how deep its vacuum is (flow = g · (1 − P)). 0 = a
    /// perfectly sealed system (the historical behaviour); higher = a leakier
    /// board where the pump has to keep working to hold a rail down. Sized to
    /// be comparable to a resistor edge so a few tenths visibly fights the
    /// pump without overwhelming it.
    var leakConductance: Double

    /// Flow resistance of routed transport channels, per millimetre of
    /// polyline. At 0 the historical model applies — a net is one
    /// zero-resistance node and a channel is pure volume. Positive values
    /// subdivide each routed net into its `ChannelGraph` and every span
    /// conducts at `1/(length × this)`, so long supply runs, bus legs,
    /// connector hops and vent runs drop pressure under flow — the bench
    /// reality a lumped net can't show. Transport bores (≈1.5 mm) are far
    /// wider than resistor serpentines (≈0.7 mm), so calibrated values sit
    /// well below `resistorResistancePerMm`. Costs solver size; big boards
    /// can set 0 for the fast idealised solve.
    var channelResistancePerMm: Double

    /// Channel-to-channel leak scale (net→net, vs `leakConductance` which is
    /// net→atmosphere). Models an imperfectly-printed plate where neighbouring
    /// channels bleed into each other through the thin wall between them — same
    /// plate, any depth (T0↔T1 through the inter-layer wall), not across the
    /// silicone gap. Per-net-pair conductance = this × a geometric weight
    /// (parallel run ÷ wall gap) from the routed layout, so a tightly-packed
    /// board leaks more than a loose one at the same setting. 0 = sealed.
    var internalLeakConductance: Double

    // Defaults are calibrated against bench measurements of printed boards
    // (Jul 2026: D-latch bus-test board, two diaphragm pumps, pressure
    // sensor on test points and the VAC inlet) rather than idealised digital
    // swings. We still want G_off ≪ G_resistor ≪ G_on, but the device
    // numbers follow the hardware:
    //
    // - Gate threshold 0.9: real membranes actuate at ≈ −0.1 atm of gate
    //   vacuum — far more sensitive than the old 0.3 guess. The ramp
    //   (hysteresis 0.03) is tight because the silicone snaps rather than
    //   ramps. Critically, threshold + hysteresis (the fully-closed point,
    //   0.93) must stay below a NAND's logic-0 output (≈ 0.95 at these
    //   defaults) or "off" transistors keep conducting and cross-coupled
    //   pairs collapse — threshold, ramp, R/mm and on-conductance moved
    //   together for that reason.
    // - On-conductance 1.0: measured 2026-07-14 on the single-transistor
    //   divider rig (Transistor test.vpcb). At full-on the source node sits
    //   ~0.02 below atm across an L reference (drop 0.40 vs 0.02 ⇒
    //   G_on ≈ 20·G_L), which the model reproduces at onConductance ≈ 1.0–1.5;
    //   1.0 sits inside the ±near-atm-noise band. The earlier 0.42 was the
    //   SHALLOW-gate bus-readback leg-drop (gate ~−0.25); the deep-gate value
    //   is higher because real membrane conductance rises with gate vacuum. A
    //   single number can't capture that gate-depth dependence — a
    //   differential/gate-depth model can (branch claude/differential-valve-
    //   proto) — but 1.0 is the deep-gate value that lets cross-coupled
    //   latches hold state (the register now latches both ways) while keeping
    //   the inverter board matching the bench.
    // - R/mm 1.5: the effective resistance of the standard resistor printed
    //   at the current 0.35 mm bore, board-calibrated Jul 17–18 2026 on the
    //   D-latch bus board (fit range 1.5–2; at 1.5 the R1-limited bus
    //   readback lands within 0.02 atm of the bench and the 4-bit register's
    //   readback separation improves vs 0.45). Poiseuille corroborates: the
    //   0.5 mm-bore-era value 0.45 × (0.5/0.35)⁴ ≈ 1.9. The resistor model
    //   is bore-blind (length only), so boards printed at the older ~0.5 mm
    //   bore need resistance ≈ 0.45 to match their bench — e.g. the
    //   "Inverter tests" calibration board, whose INV1 −0.32 anchor still
    //   reproduces at 0.45 but reads −0.26 at this default. The pull-up/vent
    //   balance that motivated 0.45 stays safe: higher R/mm weakens pull-ups
    //   against vents, so vented logic-0s sit even clearer of the 0.93
    //   off-point.
    static let defaults = SimulationParameters(
        resistorResistancePerMm: 1.5,
        transistorOnConductance: 1.0,
        transistorOffConductance: 0.0005,
        gateThreshold: 0.9,
        gateHysteresis: 0.03,
        nodeBaseCapacitance: 0.10,
        channelCapacitancePerMm: 0.04,
        dtSeconds: 0.01,
        // GUI transport default: run 10× wall-clock. Boards settle over tens
        // of sim-seconds, so realtime playback reads as stalled; ×10 lands on
        // the settled state promptly while the slider still reaches back down
        // to 0.1× for watching transients. Sim *results* are unaffected —
        // headless paths (CLI, validators, DSL sim-time waits) step the
        // engine in sim-time and never read this.
        timeScale: 10.0,
        // Bench baseline (Jul 13 2026 convention): pump measured directly
        // with the working plumbing reads −0.6 atm. (An earlier −0.7 reading
        // likely came from a more direct hookup.) The weaker bench pump only
        // manages −0.3 (pumpMaxVacuum 0.7).
        pumpMaxVacuum: 0.4,
        // The pump edge's conductance doubles as the *external supply line*
        // (it isn't a route, so `channelResistancePerMm` can't see it). 0.13
        // is the supply path measured *directly* — the bare-tube divider —
        // and now stands as the default. The earlier 0.09 board-fit sat ~2×
        // more restrictive than that direct measurement (the old "supply
        // gap"); the Jul 13 2026 inverter-board experiment resolved it: the
        // extra restriction was clamp-dependent *interface leak*, not the
        // supply path. Evidence — the inlet tee and the on-board rail read
        // equal (no board-side entry restriction), and pressing the plates
        // harder lifted the whole rail ~0.1 atm back toward the bare-tube
        // level. So the supply is modelled at its true (bare-tube) stiffness
        // and the seal quality lives in `leakConductance`, where it belongs.
        // A looser/worse-clamped build is modelled by lowering this toward
        // 0.09 and/or raising `leakConductance`; crank toward 30 for an
        // ideal manifold right at the barb.
        pumpFlowCapacity: 0.13,
        // Matches `transistorOnConductance` by design (see its doc): an
        // externally-driven bus pin behaves like one more membrane valve
        // to a rail, and the bench drive arrives through the same kind of
        // socket + tube.
        busDriveConductance: 0.42,
        pumpDroopExponent: -0.14,
        // Fitted (Jul 13 2026) to the pre-registered pinning reading on the
        // well-clamped single-cell inverter board: INV1 (the inter-stage
        // node) held at logic-1 measured −0.32 atm, which this value
        // reproduces (−0.323) at the bare-tube `pumpFlowCapacity` above. The
        // earlier 0.025 came from the leakier D-latch board and smeared into
        // the supply fit; separating supply (bare-tube stiffness) from seal
        // (this) is what let both land on the bench. Raise back toward 0.025+
        // to model a poorly-clamped board that bleeds its rails.
        leakConductance: 0.013,
        // Measured directly (Jul 13 2026): 40 mm and 80 mm straight-channel
        // divider coupons independently give 0.0067 and 0.0069/mm with exact
        // R ∝ length scaling — same order as the Poiseuille estimate
        // (resistor R/mm × (0.7/1.5)⁴ ≈ 0.014) and as the earlier 0.004
        // board-behaviour fit. Set to 0 for the fast idealised solve (one
        // node per net, channels = pure volume).
        channelResistancePerMm: 0.006,
        internalLeakConductance: 0.0
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
