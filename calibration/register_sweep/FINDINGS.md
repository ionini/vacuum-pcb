# 4-bit bus register — simulated working sweet-spot

**Board:** `4bit register with bus 2.vpcb` (44 transistors, 16 resistors, R1=L; 4 NAND-latch bits on a bidirectional bus). Inputs/probes: `J1.VAC, J1.B0..B3, J1.READ, J1.WRITE`.

**Test (per memory protocol, GUI-validated):** Store `VAC=vac, READ=vac, WRITE=atm` + drive bits → Hold `WRITE=vac, READ=vac`, bits float (`nan`) → Read `READ=atm`, bits float (register drives the bus). Logic 1 = vac (low P), 0 = atm (high P), non-inverting.

**Metric — logic margin** = (lowest stored-0 read-back) − (highest stored-1 read-back), worst case over both patterns `1010` and `0101` and all 4 bits. >0.3 = robust; ≈0 = latch lost its state.

## Baseline (default params): WORKS

Store `1010`, hold, read back → `B0=0.13  B1=1.00  B2=0.13  B3=1.00`. Margin **0.87**. Non-inverting, holds through the float phase, clean. ✓

## Sweep: read-back margin over R/mm × leak

```
  R/mm \ leak   0.005  0.0125  0.025   0.05    0.10    0.20
  0.05          0.86   0.86    0.85    0.83    0.00    0.00
  0.075         0.87   0.87    0.86    0.84    0.00    0.00
  0.10          0.88   0.87    0.86    0.84    0.00    0.00
  0.15 (def)    0.88   0.88    0.87    0.00    0.00    0.00
  0.20          0.89   0.88    0.87    0.00    0.00    0.00
  0.30          0.89   0.88    0.00    0.00    0.00    0.00
  0.40          0.89   0.89    0.00    0.00    0.00    0.00
```
(green/working = margin ~0.85+; 0.00 = broken. See `register_sweetspot.svg`.)

## The three cliffs

1. **Leak is the primary killer.** At default R/mm=0.15 the margin is rock-solid (~0.86) up to **leak 0.035**, then collapses to ~0 at **0.040** — a hard cliff, no gentle roll-off. Default leak 0.025 → ~**1.5× headroom**.
2. **Leak tolerance scales inversely with R/mm.** The boundary is ≈ **`leak × (R/mm) ≲ 0.006`** (resistor pull-to-vac must dominate leak pull-to-atm). So weaker resistors (higher R/mm) tolerate less leak: R/mm 0.05 holds to leak ~0.07; R/mm 0.4 only to ~0.018.
3. **Pump depth matters too.** Holding R/mm=0.15, leak=0.025: works for pump deadhead ≤ 0.15, collapses at **0.20**. The rail must reach below ~0.17 vacuum. Default 0.1 → ~**1.7× headroom**.
4. **Resistor size is NOT the limiter.** Across the entire tested R/mm 0.05–0.40 the register works (given low-enough leak); margin barely moves (0.85→0.89). R1=L is fine; a wide range would.

## Failure mode

Abrupt loss of bistability: a broken cell reads **all four bits at the same pressure** (e.g. 0.17) — the NAND latch can no longer hold a node at vacuum against the leak, so every stored bit decays to the same level and the bus reads garbage. There is no marginal middle band — you are either comfortably latched or fully broken.

## Bottom line (what to control on the physical build)

The register is **robust and the resistor is not critical** — don't tune R1. The two things that decide whether it latches are **sealing (leak)** and **pump vacuum depth**, and the default operating point sits comfortably inside the working region with ~1.5–1.7× margin on both. Concretely: keep **leak below ~0.035** (≈ `0.006 / (R/mm)`) and ensure the **pump pulls below ~0.17**. If your real board seals reasonably and the pump is healthy, this design works — no calibration print needed to confirm the resistor.

## Files
- `register_sweep.py` — R/mm × leak grid → `register_margin.csv`
- `analyze.py` — failure-mode dump, fine leak cliff, pump sweep
- `svg_heatmap.py` → `register_sweetspot.svg`

## Tooling note
`vacuum-cli simulate --json` **aborts** (`NSInvalidArgumentException: Invalid number value (NaN) in JSON write`) whenever a probe/net pressure is NaN — which the solver emits at near-singular corners (very low leak + low R/mm). Worked around here by parsing text output. The text path is fine. (Flagged for a fix: sanitize NaN/Inf → null in the JSON writer.)

---

# internalLeak sweep (2026-06-12, on "4bit register with bus 2.vpcb" current rev)

Channel-to-channel leak through the printed plastic walls (`--param internalLeak`),
geometry-derived per net pair and max-normalized: the value IS the conductance of
the single worst (longest-parallel/closest) channel pair on this board; a printed
resistor edge ≈ 0.2 in the same units, global leak default is 0.025.

Two hold modes between store and read (worst margin over 1010/0101):

| internalLeak | hold, bus floating | isolated hold, bus driven to OPPOSITE word |
|---|---|---|
| 0–0.2 | 0.87→0.82 works | 0.87→0.82 works |
| 0.24 | 0.80 works | works |
| **0.26** | **−0.01 DATA LOST** | works |
| 0.5 | lost | 0.70 works |
| 0.7+ | lost | lost |

- **Boundary: internalLeak ≈ 0.25** in the normal (bus-floating) hold state — the
  register only dies once the worst wall on the board leaks like a deliberate
  printed resistor (~0.2 conductance). That is ~10× the global-leak default and
  far porous-er than any plausible print; margin degrades only 0.87→0.80 before
  the cliff. Cross-talk corruption of an *isolated* cell needs ~2× more (0.5+).
- **Budget is shared with global leak** (same hold-vs-leak battle): at leak=0.035
  (the known global ceiling) internalLeak tolerance drops to ~0.1–0.2; at
  leak=0.005 it stretches to ~0.5. `map_leak__internalLeak.csv`.
- **Protocol discovery:** in the documented hold state (`WRITE=vac, READ=vac`) the
  bus transistor paths are OPEN — the latch drives the floating bus, but an
  externally driven bus writes straight through (perfect inversion, even at
  internalLeak=0). True isolation is `WRITE=atm, READ=atm`. The bus must float
  during normal hold; never park an external driver on it.
- The old `validate_internalleak.py` disturb column is invalid (left `WRITE=atm`,
  i.e. write-enabled). Superseded by `internalleak_sweep.py`.

## Files
- `internalleak_sweep.py` → `sens_internalLeak.csv`, `map_leak__internalLeak.csv`
- `register_current.vpcb` — the board rev tested (differs from `register.vpcb`)
