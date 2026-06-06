# Vacuum-logic reliability investigation — what we learned

A headless-simulation study of why the 3D-printed pneumatic **4-bit bus register**
is unreliable, and what actually decides whether it works — done with
`vacuum-cli` instead of burning test prints. Also covers a double-inverter
resistor-length calibration board and two tooling changes that came out of it.

All numbers below are from the app's own solver (`PneumaticNetwork` /
`SimulationEngine`) run headlessly; pressures are `0 = vacuum, 1 = atmosphere`.

---

## TL;DR

- **The register works in sim at default parameters** (read-back margin ≈ 0.87).
- **It is leak-limited.** Of ~10 simulation parameters, only **four** can break
  it — leak, R/mm, pump depth, gate threshold — and they all govern the same
  battle: *holding a stored-1 node at vacuum, below the gate threshold, against
  the leak.* Six other parameters are irrelevant across their whole plausible
  range.
- **Sealing and vacuum depth are what matter on real hardware. The resistor
  size, pump flow rate, and transistor characteristics do not.** Don't tune the
  resistor — seal the print and pull a good vacuum.
- The **newer register design** doesn't move the hard limits but holds its bits
  with **~2× the noise margin** (stored-1 at 0.13 vs the old 0.21), so it's
  meaningfully more robust to the cell-to-cell variation that causes "flaky"
  behaviour — at the *same* sealing.

---

## 1. Methodology

Instead of printing calibration boards, drive the real engine from the shell:
store a pattern, hold, read back, and score the **read-back logic margin** =
`min(stored-0 readback) − max(stored-1 readback)`, worst-case over patterns
`1010` and `0101`. `> 0.3` = latches reliably; `≈ 0` = lost its bits. The
register's bus pins are bidirectional, so during read-back they must be
**floated** (`--phase "J1.B0=nan,…"`) or they override the register.

Store = `READ=vac, WRITE=atm` + drive bits; hold = `WRITE=vac, READ=vac`, bits
float; read = `READ=atm`, bits float (register drives the bus).

Scripts: `register_sweep/` (`full_sweep.py`, `analyze.py`, `compare_old_new.py`,
`bus_disturb.py`, `truth_table.py`, `leak_isolation.py`, `attribution.py`,
`disturb_*.py`, `validate_internalleak.py`), heatmaps `register_sweep/*.svg`,
data `register_sweep/*.csv`, raw tables `register_sweep/SWEEP_RESULTS.md`.

## 2. The four parameters that matter (1-D windows, others at default)

| Parameter | Works for | Default | Headroom |
|-----------|-----------|---------|----------|
| **leak** (sealing) | ≤ ~0.035 | 0.025 | ~1.4× — tightest |
| **gate threshold** | ≥ ~0.22 | 0.30 | ~1.4× above floor |
| **R/mm** (resistor) | ≤ ~0.24 *(at default leak)* | 0.15 | ~1.6× |
| **pump deadhead** | ≤ ~0.19 *(deeper = better)* | 0.10 | ~1.9× |

**Irrelevant** (work across their entire plausible range): pump flow, gate
hysteresis, transistor on-conductance, transistor off-leakage, bus drive, pump
droop.

Interactions (see `register_sweep/map_*.svg`):
- **leak × R/mm** is a clean hyperbola: `leak·(R/mm) ≲ 0.006`. Seal better and a
  much weaker resistor works.
- **leak dominates pump**: the leak cliff barely moves with pump depth until the
  pump is also bad.
- **gate threshold couples with leak/pump**: a leakier board or shallower pump
  needs a *higher* threshold to still read a stored 1.

Failure everywhere is **abrupt** — the NAND latch loses bistability and all four
bits collapse to the same pressure (no graceful degradation).

## 3. Old vs new register

Same 44 transistors; the old uses a D-Latch + AND-4 read gates (20 resistors),
the new a restructured "D-Latch with inverted" read path (16 resistors).

- **Identical hard cliffs** — both die at leak ≈ 0.04 and pump deadhead ≈ 0.2.
  Switching designs buys **no** extra tolerance to bad sealing/vacuum.
- **The new design holds deeper**: stored-1 reads **0.13** vs the old **0.21**
  (threshold 0.3), i.e. ~2× the margin to the flip point. Real boards flip bits
  from cell-to-cell variation nudging a marginal "1" over the line, so the new
  design's extra buffer makes the "works-but-flaky" zone much less flaky **at
  the same sealing**.
- **Neither has read-disturb** — both hold a value stable across repeated reads.

So: if the old print *flaked* (occasional wrong bits) → the redesign should
help. If it *hard-failed* (couldn't hold at all) → that's the cliff, and only
better sealing/vacuum fixes it.

## 4. Bus disturb & the READ polarity

Driving the bus while the register is **listening** to it (one of the two READ
states) overwrites storage; in the **driving/read** state the register defends
its value. In the *idle/read state*, the sim holds the data even against a 30×
over-strength bus pull — so we could **not** reproduce "driving the bus in idle
destroys data" in the model. The protection there is a contention won from the
vacuum rails, which the idealized sim never loses; on a weak/leaky board it
could. (The model's READ-pin sense may be inverted vs the physical board — the
behaviour, not the label, is what's robust: one state is bus-protected, the
other bus-exposed, identical in both designs.)

## 5. Internal (channel-to-channel) leak

The simulator's `leak` is net→**atmosphere** only; it has no concept of one
channel bleeding into an **adjacent** channel through a thin printed wall —
which is the most physically likely cause of the real failures. So we **added**
`internalLeakConductance` (net→net): a geometry pass pairs routed channels that
run close **within the same printed plate** (in-plane neighbours and T0↔T1
across the inter-layer wall — not across the silicone gap), weights each pair by
run-length ÷ wall gap, and stamps weak net↔net edges scaled by the knob
(max-normalized to a playable 0–1; CLI `--param internalLeak`, GUI "Int leak"
slider).

Findings on the register:
- `internalLeak=0` reproduces sealed behaviour exactly; margin erodes gently to
  ~0.2, then **scrambles at ~0.25** — modest tolerance.
- The corruption is **bus-independent** (idle == bus-driven): channel-to-channel
  leak scrambles **retention** because the packed internal storage channels
  bleed into each other — it does **not** reproduce a specifically "bus writes
  into storage" path. Same conclusion, stronger: **internal leak is the enemy.**

## 6. Double-inverter resistor-length calibration board

Side investigation into sweeping a resistor's length to find where Inv1 stops
driving Inv2. Key facts: a resistor's footprint is a **fixed 12×4 mm box**
regardless of size (S/M/L/XL = 0/3/10/15 zigzags → 12/20/34/44 mm of channel),
so swapping size needs **no re-route**; **XL won't print** (walls collide at the
0.5 mm bore) → **L is the printable ceiling per body**, chain L's in series for
more. Generator: `gen_cal_board.py` (a single board carrying many cells tests
every length under identical conditions in one print).

## 7. Tooling changes (shipped with this)

- **`--json` NaN fix**: `printJSON` now scrubs non-finite Doubles → `null`, so
  `simulate --json` no longer aborts at near-singular operating points (it used
  to crash sweeps).
- **`internalLeak` parameter** (model + CLI + GUI), as in §5.

## 8. Caveats / what still needs hardware

The sim idealizes things it can't see: **perfect bus↔storage isolation**
(so it under-shows bus-bleed failures), **uniform cells** (real boards fail at
their *worst* cell — consistency matters more than the mean), and the
`internalLeak` knob is **per-board normalized** (relative, not an absolute leak
rate). The sim locates *which* knobs matter and *roughly* where the edges are;
the absolute thresholds and the bus-vs-retention question are still a
bench measurement: pull a sealed board to vacuum and watch the rail hold, and
test whether data is lost only when driving the bus or also when idle.
