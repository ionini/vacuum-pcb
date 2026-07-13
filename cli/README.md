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
- `continuity` — export a per-net "buzz-out" checklist for physically probing a
  printed board with a vacuum tube (catches print-vs-design faults sim can't).

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

# Supply budget: settle, then rank every path drawing air into the rail:
"$BIN" flows path/to/design.vpcb --set IN=atm
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
| `--param NAME=VALUE` | Override a `SimulationParameters` field. Repeatable. Names: `resistance`, `flow`, `pumpMax`, `onConductance`, `offConductance`, `gateThreshold`, `gateHysteresis`, `capacitance`, `busDrive`, `droop`, `leak`, `dt`. |
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

`--param leak=N` models the silicone/PCB sandwich never sealing perfectly:
every net bleeds toward atmosphere through a faint conductance `N`, so any
segment holding vacuum decays back to atm at a rate set by `N` (0 = perfectly
sealed). It's most visible on stored state — a register cell whose data drive
has been released loses its bit faster the higher the leak, and a refresh
(re-asserting WRITE) restores it.

```sh
# Watch a leak drain a written register over a few seconds, then refresh it.
"$BIN" simulate reg.vpcb --param leak=0.025 \
  --phase "WRITE=vac,READ=vac,B0=vac,B1=vac,B2=vac,B3=vac" \
  --phase "WRITE=atm,B0=atm,B1=atm,B2=atm,B3=atm" \
  --phase "WRITE=vac,B0=vac,B1=vac,B2=vac,B3=vac"
```

A stored 1 reads back as deep vacuum and a stored 0 as atmosphere; bumping
`resistance` and `flow` above their defaults sharpens that separation on
bus/latch designs.

### Supply budget (`flows`)

The engine never stores flow, but every edge is attributable, so `flows`
reconstructs Q = G·ΔP from a settled state (shared `FlowAnalysis`, the same
compute behind the Simulate tab's flow overlay and Supply panel) and prints
the supply-side story:

- **pump line** — throughput vs the pump's free-flow ceiling
  (`flow × (1 − pumpMax)`), plus the rail's settled pressure;
- **external rail feed** — asserted soft drives sitting on rail nets (a bench
  line on the connector's VAC pin) counted into the supply total;
- **draw into rail, ranked** — every resistor/transistor edge crossing into a
  rail net, plus the rail plumbing's own leak: a pull-up fighting an open vent
  path is continuous static draw (the NMOS-style rail-sag mechanism); one
  holding an isolated node is just the leak floor. Σ draw ≈ supply at settle
  — a big gap means it hasn't settled;
- with `--all-nets`, every resistor's and transistor's signed through-flow
  (spot shoot-through paths and off-band residual leaks through "closed"
  valves).

Takes the same `--set` / `--phase` / `--param` / `--steps` / `--epsilon`
options as `simulate`; with `--phase` the budget describes the final phase's
settled state (e.g. a register in hold).

```sh
# Which pull-up is eating the pump while the latch holds a 1?
"$BIN" flows latch.vpcb \
  --phase "J1.VAC=vac,J1.WRITE=vac,J1.D0=vac" \
  --phase "J1.WRITE=atm,J1.D0=nan" --all-nets
```

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

## Physical continuity (`continuity`)

When a board sims fine but fails on the bench, the fault is almost always
*physical* — a channel that didn't print through, two channels that fused into
one, or a via that didn't actually connect its layers. None of these are
visible to the simulator (which works from the logical netlist). `continuity`
exports the checklist for proving the printed board against the design by hand:
for each net, every physical opening you can press a vacuum tube against —
transistor gate & source/drain, port/vent/source edge bores, resistor ends,
connector tubes, and vias — with its layer (`T0`/`B0`…) and board-mm position.

The test is the pneumatic equivalent of buzzing out a circuit with a multimeter:
apply vacuum at any one point on a net; **every** other point on that net should
pull a hard vacuum, and **nothing** on any other net should move. Because the
list is exhaustive, the negative check is implicit — anything not listed under a
net should be dead when you probe that net.

```sh
"$BIN" continuity design.vpcb              # top-level routes only
"$BIN" continuity design.vpcb --flatten    # whole printed board (expands subparts)
"$BIN" continuity design.vpcb --probe n12  # just one net (repeatable)
"$BIN" continuity design.vpcb --json       # structured, for tooling
```

**Embedded subparts.** By default the checklist covers only the open file's own
routes (same scope as `check`). A board that places a subpart prints that
subpart's channels into its *own* plates, so those internal holes are part of
the physical board too — pass `--flatten` to expand every subpart into board
coordinates (labels become prefixed, e.g. `U6.Q1.gate`, `U6.U3.U1.Q2.gate`).
Without it, the summary warns when unexpanded subparts are present so you don't
mistake a partial list for a complete one. (For socket-mated *assemblies* —
separate plate stacks joined at a connector — don't flatten; probe each half's
file on its own, since they're physically distinct boards.)

Vias are split three ways: a **through-hole** (spans both plates, e.g. `T0↔B0`)
is probeable from either face; an **internal via** (same plate, e.g. `B0,B1`) is
buried and not surface-accessible; an **orphan** (touches one layer only) is a
broken via that won't connect at all — flagged with `⚠`, and the same fault DRC
reports as `orphanVia`.

Coordinates are board millimetres, matching the GUI's physical view; the header
prints the board outline so you can measure relative to a corner if you prefer.
Top-level only: subpart internals and post-mating net merges aren't descended
into (open each subpart's own `.vpcb` and probe it separately) — same scope as
`check`.

### Physical volumes (`--volumes`)

`continuity --volumes` lists not nets but **physical volumes**: one sealed air
cavity in a *single* plate, the way it exists before the two plates are bonded.
This is the unit you actually bench-test a freshly printed plate against — plug
every hole but one, pull vacuum on the last, and a perfect vacuum proves that
cavity is fully connected and leak-free. Output is grouped TOP / BOTTOM plate,
each volume `T1`/`B2`… with its holes (and `via → … plate` bridges, the
openings you mate through later). Implies `--flatten` (a volume is a physical
thing, so subparts are always expanded).

It differs from the net list in two physically-grounded ways:

- **Plates are independent.** A net that crosses the silicone is *two* volumes,
  one per plate, joined only at the through-holes (which aren't bonded yet). So
  a dead through-hole shows up as a net whose two plate-halves never pull
  together — invisible to sim, caught here.
- **Resistors merge cavities; transistors don't.** A resistor is an always-open
  serpentine channel joining its two pins, so vacuum bleeds through it — its two
  (same-plate) cavities are one volume for testing. A transistor's source/drain
  are gated by the silicone membrane, not an open channel, so they stay
  separate. (Consequence: a VAC rail plus everything it feeds through pull-up
  resistors reads as one large volume — that *is* one connected air space.)

Same engine powers the **3D preview's Volumes inspector**, where selecting a
volume glows that cavity in the scene.

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
  reaches `pumpMaxVacuum` (default 0.4, the bench pump's measured −0.6 atm
  baseline), not full vacuum — matching the app. If a gate needs deeper
  vacuum than the rail delivers, it won't switch, and the readout will show
  it.
- Identical probe readings across different `--set` values usually mean the
  drive isn't reaching the gate, or the input can't pull it past
  `gateThreshold` (default 0.9 ≈ −0.1 atm, bench-calibrated) — not
  necessarily a bug. Check topology with `inspect`.
- `channelR` (default 0.006/mm, coupon-measured: 40/80 mm dividers with
  exact R ∝ length scaling) subdivides routed nets so channels drop
  pressure under flow — supply-run starvation, bus-leg sag and mid-channel
  test-point readings are visible by default. The external pump tube is
  modelled by `flow` (default 0.09, board-fitted; a bare-tube divider
  measures ≈ 0.13 — open gap), not `channelR` (it isn't a route).
  `onConductance` (default 0.42, bench-fitted from the readback ladder)
  makes open transistors realistically restrictive. For the old idealised
  solve:
  `--param flow=30 --param channelR=0 --param onConductance=5
  --param resistance=0.3`.
- Build: SwiftPM treats any non-Swift file inside a listed source dir as an
  error, so docs/assets under `cli/` must be added to `exclude` in
  `../Package.swift` (that's why this README is listed there).

## Agent use

There's a project skill at `.claude/skills/simulate/SKILL.md` that teaches the
agent this workflow; it auto-triggers on requests to validate/simulate/check a
circuit, or runs explicitly via `/simulate`.
