---
description: >-
  Validate Vacuum PCB pneumatic circuits headlessly with the `vacuum-cli` tool.
  It runs the app's real simulation engine from the shell, so you can check
  net/probe pressures, confirm a .vpcb design behaves correctly (e.g. an
  inverter inverts), or debug why a gate won't toggle — without opening the GUI
  or asking the user to eyeball the Simulate tab. Use whenever asked to
  validate, simulate, or check the logical behavior of a circuit or .vpcb file,
  or to verify a simulation-related code change.
argument-hint: "[path/to/design.vpcb]"
---

# Simulate & validate circuits headlessly

`vacuum-cli` drives the app's own `PneumaticNetwork` / `SimulationEngine`, so its
numbers match the Simulate tab — but it runs from the shell, which lets you
validate circuit logic yourself instead of handing UI validation back to the
user. (It cannot validate *visual* things — layout/rendering still need eyes.)

## Build (once per change)

From the repo root:

```sh
swift build -c release
```

The binary lands at `.build/release/vacuum-cli`. Rebuild after any change to
the model or simulation code. `swift build` is independent of the Xcode project
and of `xcodebuild` — it links Euclid as a local SwiftPM package. Release
matters now: the default `channelR` subdivides routed nets, which grows the
solve enough that a debug binary is ~20× slower on settle runs (a debug build
at `.build/debug/vacuum-cli` still works for quick checks).

## Commands

```sh
BIN=.build/debug/vacuum-cli

# What can be driven/observed in a design (input/probe labels, counts):
"$BIN" inspect <file.vpcb>

# Run the solver and read out probe pressures:
"$BIN" simulate <file.vpcb> [options]

# Supply budget: settle, then rank every path drawing air into the rail —
# pump throughput vs ceiling, rail depth, per-consumer draw (a pull-up
# fighting an open vent path = continuous static draw; the rail-sag
# mechanism). Same --set/--phase/--param options as simulate; with --phase
# the budget is the final phase's settled state (e.g. a register in hold).
# --all-nets adds every resistor's/transistor's signed through-flow —
# spot shoot-through paths and off-band residual through "closed" valves.
# Σ draw ≈ supply at settle; a big gap = not settled yet.
"$BIN" flows <file.vpcb> [options]
```

### `simulate` options

- `--steps N`   Fixed solver steps (default 500). Raise until readings stop
  changing — that's convergence.
- `--set L=V`   Drive the input labelled `L`. `V` is `vac` / `atm` or a number
  in `0…1`. Repeatable, one per input.
- `--probe L`   Only report probe `L`. Repeatable.
- `--all-nets`  Also print every net's pressure (use to see where a result
  breaks down).
- `--phase "SETS[@CAP]"`  Run a **stateful sequence** that carries latch/register
  state across phases — the only way to validate sequential designs (memory,
  registers, latches): write a value in one phase, release, then read it back in
  a later phase. `SETS` is comma-separated `LABEL=VALUE`; drives are **sticky**
  (unnamed inputs hold their previous value). Each phase runs until it settles
  (or hits `CAP` steps, default 100000) and prints its probes. Repeatable; phases
  run in order. Overrides `--set`. A plain `--steps` run always re-seeds from a
  blank all-atm state, so it *cannot* show held memory — use `--phase` for that.
  Settled `--phase` values are the authoritative readings (settling = largest
  per-net movement over a 100-step window under `--epsilon`; fixed `--steps` is
  for step-budgeted regression diffs). **Bound hold phases explicitly**
  (`…,B0=nan@10000` = hold 100 sim-seconds): with the default leak an
  unrefreshed cell's only settled state is "forgotten", so an uncapped hold
  phase runs to the cap and the read-back comes up empty — a leaky register's
  real guarantee is "readable after N seconds", and `@CAP` is how you say N. A
  hold phase reporting `did NOT settle` is expected (it's a timed wait).
- `--param NAME=VALUE`  Override a `SimulationParameters` field. Repeatable.
  Names: `resistance`, `flow`, `pumpMax`, `onConductance`, `offConductance`,
  `gateThreshold`, `gateHysteresis`, `capacitance`, `channelCapacitancePerMm`,
  `busDrive`, `droop`, `leak`, `channelR`, `internalLeak`, `dt`.
  Defaults are bench-calibrated (Jul 2026): `gateThreshold` 0.9 (membranes
  actuate at ≈ −0.1 atm), `gateHysteresis` 0.03, `onConductance` 1.0 (the
  deep-gate value, measured 2026-07-14 on the single-transistor divider
  rig — real membrane conductance rises with gate depth; the earlier 0.42
  was a shallow-gate fit from the bus-readback ladder, and `busDrive`
  deliberately keeps that 0.42: an external drive arrives through socket
  + tube, which has no deep-gated membrane), `resistance` 1.5 (the standard resistor at the
  current 0.35 mm bore, board-calibrated Jul 17–18 2026; boards printed
  at the older ~0.5 mm bore match their bench at ≈ 0.45), `pumpMax` 0.307
  (the NEW stronger bench pump: deadhead −0.693 atm, measured 2026-08-27;
  the Jul-era pump was 0.4 / −0.6, the weak one 0.7 / −0.3), `flow` 1.32
  paired with `droop` +0.467 (fitted together 2026-08-27: droop from the
  550 ml jar drawdown's deep region, flow bisected on the Test-rig 0.35 mm
  L-coupon anchor at that droop — the pair is degenerate at a single
  divider point, so never change one without the other; the old pump's
  pair was 0.13 / −0.14. The pump edge doubles as the *external supply
  line* — the bench tube; it isn't a route, so `channelR` can't see it.
  The Jul 13 2026 lesson stands: clamp-dependent interface restriction
  belongs in `leak`, so lower `flow` only to model a loose build),
  `channelR` 0.006
  (coupon-measured: 40/80 mm dividers, exact R ∝ length; routed nets
  subdivide into channel nodes: supply
  runs, bus legs and vent runs drop pressure under flow, and probes/test
  points read their actual tap position), `leak` 0.013 (fitted to the
  well-clamped single-cell inverter board's −0.32 atm hold anchor; raise
  toward 0.025+ for a poorly-clamped board that bleeds its rails). So a
  default run
  reproduces the bench: rails sag under static pull-up draw, recover as the
  draw changes, and logic margins are as thin as the printed board's.
  For the old idealised digital behaviour use
  `--param flow=30 --param channelR=0 --param onConductance=5
  --param resistance=0.3` (ideal manifold, lossless channels, perfect
  valves); `--param leak=0` seals the board perfectly.
- `--epsilon N`  Settle threshold for `--phase` (default 1e-5): largest
  per-net movement across a 100-step window (one sim-second), not per-step —
  per-step deltas under-report slow leak↔pump tails.
- `--json`      Machine-readable output — parse this when asserting exact values.

Example — validate a 4-bit register stores and reads back:

```sh
"$BIN" simulate reg.vpcb \
  --phase "WRITE=atm,READ=vac,B0=vac,B1=vac,B2=vac,B3=vac" \  # write 1111
  --phase "READ=atm,B0=atm,B1=atm,B2=atm,B3=atm@10000" \      # release/hold 100 s
  --phase "WRITE=vac"                                          # read back -> LEDs
```

## Pressure convention

`0 = full vacuum, 1 = atmosphere`. Which rail counts as a logic "1" depends on
the design — read the topology, don't assume.

## Validation workflow

1. `inspect` the file to learn the input and probe labels.
2. For each input combination, run
   `simulate <file> --set <in>=<vac|atm> --probe <out> --steps 5000`.
3. Compare the probe pressure to what you expect. For precise checks, add
   `--json` and parse the `pressure` field rather than eyeballing.
4. If something looks off, re-run with `--all-nets` to find where the pressure
   diverges, and bump `--steps` to rule out non-convergence before calling it a
   bug.

## Gotchas

- A **hard** input toggled to `vac` joins the shared pump manifold and only
  reaches `pumpMaxVacuum` (default 0.307, the measured bench pump), not full
  vacuum — matching the app. If a gate needs deeper vacuum than the rail
  delivers, it won't switch.
- A transistor opens only when its gate net drops below `gateThreshold`
  (default 0.9, i.e. −0.1 atm); fully closed needs the net back above
  threshold + hysteresis (0.93), so a logic-0 that sags below that leaves
  the gate partially conducting.
- Identical probe readings across different `--set` values usually mean either
  the drive isn't reaching the gate (verify with `inspect`/topology) or the
  input can't pull the gate past threshold — not necessarily a bug.

See `cli/README.md` for the full reference and build internals.
