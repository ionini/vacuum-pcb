# vacuum-cli — headless validation & layout tools

A command-line entry point into the app's own engine, for working with a
`.vpcb` design without launching the GUI. It compiles the app's source tree
directly (see `../Package.swift`) and drives the exact same model the app does,
so results match. Builds with plain `swift build` — no Xcode, independent of the
app's Xcode project. (It does link Euclid, consumed as a local SwiftPM package
from `../Euclid`.)

Commands:

- `inspect` / `simulate` — validate circuit *logic* automatically (scripts, CI,
  or an agent) instead of eyeballing the Simulate tab.
- `minimize` — compact a board's die headlessly, with as much compute (and as
  many parallel restarts) as you care to give it — no in-app main-thread cap.
- `reroute` — measure auto-router quality on a board (DRC from scratch).

It does **not** validate anything visual — layout and rendering still need a
human.

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
| `--phase "SETS[@CAP]"` | Run a **stateful sequence**, carrying latch/register state across phases. `SETS` is comma-separated `LABEL=VALUE` (sticky — unnamed inputs hold). Each phase runs until it settles or hits `CAP` steps (default 20000), then prints its probes. Repeatable; runs in order. Overrides `--set`. |
| `--epsilon N` | Settle threshold for `--phase` (default 1e-5). |
| `--param NAME=VALUE` | Override a `SimulationParameters` field. Repeatable. Names: `resistance`, `flow`, `pumpMax`, `onConductance`, `offConductance`, `gateThreshold`, `gateHysteresis`, `capacitance`, `busDrive`, `droop`, `dt`. |
| `--json` | Machine-readable output — parse this for exact assertions. |

### Sequential designs (`--phase`)

A plain `simulate` run always seeds from a blank, all-atmosphere state, so it
**cannot** show held memory — a latch/register reads back whatever its reset
state is, not what you "wrote". `--phase` fixes that: it keeps the net pressures
and transistor states from one phase as the starting point of the next, so a
value written early is still held when a later phase reads it back. Drives are
**sticky** (a phase only overrides the labels it names).

```sh
# Validate a 4-bit register: write 1111, release, read it back on the LEDs.
"$BIN" simulate reg.vpcb --param resistance=0.15 --param flow=30 \
  --phase "WRITE=atm,READ=vac,B0=vac,B1=vac,B2=vac,B3=vac" \
  --phase "READ=atm,B0=atm,B1=atm,B2=atm,B3=atm" \
  --phase "WRITE=vac"
```

A stored 1 reads back as deep vacuum and a stored 0 as atmosphere; bumping
`resistance` and `flow` above their defaults sharpens that separation on
bus/latch designs.

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
"$BIN" simulate "$EX" --steps 5000 --set IN=vac --probe OUT   # OUT ≈ 0.94 (high)
```

`IN` high (atmosphere) → `OUT` low (vacuum), and vice versa: it inverts. With a
weaker pump default the gate can't switch and both cases read the same — which
is itself a useful thing for the tool to reveal.

## Compacting a board (`minimize`)

`minimize` runs the app's `Minimizer` headlessly — the same simulated-annealing
placement search the Physical tab's **Minimize** button uses, but without the
in-app main-thread time cap, so you can throw real compute at it. It shrinks the
die (and tidies wiring) while keeping the board within its DRC baseline, then
writes the result with `--out`.

```sh
BIN=.build/release/vacuum-cli          # build -c release; the search is CPU-bound

# One search, 30 s, write the compacted board:
"$BIN" minimize design.vpcb --seconds 30 --out design.min.vpcb

# Overnight-grade: 16 independent restarts across all cores, 10 min each;
# the smallest DRC-clean die wins. Wall time ≈ --seconds, not 16×.
"$BIN" minimize design.vpcb --restarts 16 --seconds 600 --out design.min.vpcb
```

| Option | Meaning |
|--------|---------|
| `--out PATH` | Write the compacted `.vpcb`. Omit to just print the report. |
| `--seconds N` | Wall-clock budget **per restart** (default 10). |
| `--restarts N` | Independent restarts (distinct seeds), run in parallel across cores; best result wins. Wall ≈ `--seconds`. |
| `--seed N` | Base PRNG seed (restart *k* uses `seed+k`); runs are reproducible. |
| `--iters N` | Per-restart trial cap (default auto — usually leave it to `--seconds`). |

Boards with slack compact a lot (a loose layout routinely drops 40–50 % of its
die area); a board already hand-optimised to its routing limit will report
`0.0% area saved` and leave itself unchanged — that's the tool correctly
declining rather than breaking a good board.

## Router quality (`reroute`)

`reroute` strips every route and re-routes from scratch with the negotiated-
congestion router, printing the DRC breakdown before/after. It measures the
auto-router in isolation (independent of placement) — handy when judging whether
a dense board is routable at all.

```sh
"$BIN" reroute design.vpcb            # DRC histogram before vs. after
"$BIN" reroute design.vpcb --out design.rerouted.vpcb
```

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
