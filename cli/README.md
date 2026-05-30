# vacuum-cli — headless simulation validation

A command-line entry point into the app's own simulation engine, for validating
circuit behavior without launching the GUI. It compiles the app's source tree
directly (see `../Package.swift`) and drives the exact same
`PneumaticNetwork` / `SimulationEngine` the Simulate tab uses, so results match
the app. Builds with plain `swift build` — no Xcode, independent of the app's
Xcode project. (It does link Euclid, consumed as a local SwiftPM package from
`../Euclid`.)

This exists so circuit *logic* can be validated automatically (in scripts, CI,
or by an agent) rather than by eyeballing the Simulate tab. It does **not**
validate anything visual — layout and rendering still need a human.

## Build

```sh
swift build            # from the repo root
```

The binary lands at `.build/debug/vacuum-cli`. Rebuild after any change to the
model/simulation code.

## Usage

```sh
BIN=.build/debug/vacuum-cli

# List the simulatable inputs / probes / nets of a design:
"$BIN" inspect path/to/design.vpcb

# Run the solver and read out probe pressures (0 = vacuum, 1 = atmosphere):
"$BIN" simulate path/to/design.vpcb --steps 5000

# Drive inputs by label, filter probes, dump every net, or emit JSON:
"$BIN" simulate path/to/design.vpcb --set IN=vac --probe OUT --all-nets --json
```

### Options (`simulate`)

| Option | Meaning |
|--------|---------|
| `--steps N` | Fixed solver steps (default 500). Raise until readings stop changing — that's convergence. |
| `--set LABEL=VALUE` | Drive an input. `VALUE` is `vac`/`atm` or a number in `0…1`. Repeatable. |
| `--probe LABEL` | Only report this probe. Repeatable. |
| `--all-nets` | Also print every net's pressure. |
| `--json` | Machine-readable output — parse this for exact assertions. |

## What you can validate

- **Truth tables / logic** — drive each input combination with `--set` and check
  the probe pressures invert/gate as expected.
- **Switching thresholds** — confirm a gate net actually crosses `gateThreshold`
  and toggles its transistor, or find that it doesn't.
- **Rail behavior** — `--all-nets` shows whether a VAC rail holds vacuum under
  load or sags, and where a pressure breaks down.
- **Convergence / stability** — compare a reading at e.g. 5k vs 20k steps; if it
  drifts, the circuit hasn't settled.
- **Regressions** — diff `--json` output before/after a model change.

## Worked example — the inverter

```sh
BIN=.build/debug/vacuum-cli
EX="Vacuum PCB/Vacuum PCB/Examples/inverter.vpcb"

"$BIN" simulate "$EX" --steps 5000 --set IN=atm --probe OUT   # OUT ≈ 0.10 (low)
"$BIN" simulate "$EX" --steps 5000 --set IN=vac --probe OUT   # OUT ≈ 0.86 (high)
```

`IN` high (atmosphere) → `OUT` low (vacuum), and vice versa: it inverts. With a
weaker pump default the gate can't switch and both cases read the same — which
is itself a useful thing for the tool to reveal.

## Gotchas

- A **hard** input toggled to `vac` joins the shared pump manifold and only
  reaches `pumpMaxVacuum` (default 0.1), not full vacuum — matching the app. If
  a gate needs deeper vacuum than the rail delivers, it won't switch, and the
  readout will show it.
- Identical probe readings across different `--set` values usually mean the
  drive isn't reaching the gate, or the input can't pull it past
  `gateThreshold` (default 0.3) — not necessarily a bug. Check topology with
  `inspect`.
- Build: SwiftPM treats any non-Swift file inside a listed source dir as an
  error, so docs/assets under `cli/` must be added to `exclude` in
  `../Package.swift` (that's why this README is listed there).

## Agent use

There's a project skill at `.claude/skills/simulate/SKILL.md` that teaches the
agent this workflow; it auto-triggers on requests to validate/simulate/check a
circuit, or runs explicitly via `/simulate`.
