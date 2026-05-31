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
swift build
```

The binary lands at `.build/debug/vacuum-cli`. Rebuild after any change to the
model or simulation code. `swift build` is independent of the Xcode project and
of `xcodebuild` — it links Euclid as a local SwiftPM package.

## Commands

```sh
BIN=.build/debug/vacuum-cli

# What can be driven/observed in a design (input/probe labels, counts):
"$BIN" inspect <file.vpcb>

# Run the solver and read out probe pressures:
"$BIN" simulate <file.vpcb> [options]
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
  (or hits `CAP` steps, default 20000) and prints its probes. Repeatable; phases
  run in order. Overrides `--set`. A plain `--steps` run always re-seeds from a
  blank all-atm state, so it *cannot* show held memory — use `--phase` for that.
- `--param NAME=VALUE`  Override a `SimulationParameters` field. Repeatable.
  Names: `resistance`, `flow`, `pumpMax`, `onConductance`, `offConductance`,
  `gateThreshold`, `gateHysteresis`, `capacitance`, `busDrive`, `droop`, `dt`.
  Higher `resistance` (e.g. 0.15) + `flow` (e.g. 30) sharpen logic levels on
  bus/latch designs.
- `--epsilon N`  Settle threshold for `--phase` (default 1e-5).
- `--json`      Machine-readable output — parse this when asserting exact values.

Example — validate a 4-bit register stores and reads back:

```sh
"$BIN" simulate reg.vpcb --param resistance=0.15 --param flow=30 \
  --phase "WRITE=atm,READ=vac,B0=vac,B1=vac,B2=vac,B3=vac" \  # write 1111
  --phase "READ=atm,B0=atm,B1=atm,B2=atm,B3=atm" \            # release/hold
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
  reaches `pumpMaxVacuum` (default 0.1), not full vacuum — matching the app. If
  a gate needs deeper vacuum than the rail delivers, it won't switch.
- A transistor opens only when its gate net drops below `gateThreshold`
  (default 0.3); a net partially pulled but still above that won't toggle it.
- Identical probe readings across different `--set` values usually mean either
  the drive isn't reaching the gate (verify with `inspect`/topology) or the
  input can't pull the gate past threshold — not necessarily a bug.

See `cli/README.md` for the full reference and build internals.
