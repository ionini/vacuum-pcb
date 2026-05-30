# vacuum-cli — headless simulation validation

A command-line entry point into the app's own simulation engine, for validating
circuit behavior without launching the GUI. It compiles the app's source tree
directly (see `../Package.swift`) and drives the exact same
`PneumaticNetwork` / `SimulationEngine` the Simulate tab uses, so results match
the app. Builds with plain `swift build` — no Xcode, independent of the app's
Xcode project. (It does link Euclid, consumed as a local SwiftPM package from
`../Euclid`.)

## Build

```sh
swift build            # from the repo root
```

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

`--set LABEL=VALUE` accepts `vac`/`atm` or a number in `0…1`. `--steps` defaults
to 500; raise it until the readings stop changing to confirm convergence.

> Note: a *hard* input toggled to `vac` joins the shared pump manifold and only
> reaches `pumpMaxVacuum` (default 0.54), not full vacuum — matching the app. If
> a gate needs deeper vacuum than that to switch, it won't, and the readout will
> show it.
