# 4-bit register — comprehensive parameter sweep

Metric = worst-case read-back logic margin over patterns 1010 / 0101 (≥0.3 = latches reliably, ≈0 = loses its bits, `!!` = solver unstable). 1-D: one param varied, rest at GUI defaults. Maps: the two named params co-varied.

**Defaults:** resistance=0.15, leak=0.025, pumpMax=0.1, flow=30, gateThreshold=0.3, gateHysteresis=0.08, onConductance=5, offConductance=0.0005, busDrive=5, droop=-0.14


## 1-D sensitivity (working window @ margin ≥ 0.3)


**resistance** — R/mm — resistor strength (higher = weaker pull)  (default **0.15**)

| resistance | 0.03 | 0.05 | 0.075 | 0.1 | 0.15 | 0.2 | 0.3 | 0.4 | 0.6 | 0.8 |
|---|---|---|---|---|---|---|---|---|---|---|
| margin | 0.83 | 0.85 | 0.86 | 0.86 | 0.87 | 0.87 | -0.00 | -0.00 | 0.01 | 0.01 |
| works | ++ | ++ | ++ | ++ | ++ | ++ | X | X | . | . |

Working window: **0.03 … 0.2** (default 0.15 inside).

**leak** — leak — sealing (higher = leakier)  (default **0.025**)

| leak | 0.002 | 0.005 | 0.01 | 0.02 | 0.03 | 0.04 | 0.05 | 0.07 | 0.1 |
|---|---|---|---|---|---|---|---|---|---|
| margin | 0.89 | 0.88 | 0.88 | 0.87 | 0.86 | 0.00 | -0.00 | -0.00 | 0.00 |
| works | ++ | ++ | ++ | ++ | ++ | . | X | X | . |

Working window: **0.002 … 0.03** (default 0.025 inside).

**pumpMax** — pump deadhead (lower = deeper vacuum)  (default **0.1**)

| pumpMax | 0.02 | 0.05 | 0.08 | 0.1 | 0.12 | 0.15 | 0.18 | 0.2 | 0.25 | 0.3 |
|---|---|---|---|---|---|---|---|---|---|---|
| margin | 0.95 | 0.92 | 0.89 | 0.87 | 0.85 | 0.82 | 0.79 | 0.00 | -0.00 | 0.01 |
| works | ++ | ++ | ++ | ++ | ++ | ++ | ++ | . | X | . |

Working window: **0.02 … 0.18** (default 0.1 inside).

**flow** — pump flow capacity (rail stiffness)  (default **30**)

| flow | 5 | 10 | 15 | 20 | 30 | 40 | 50 | 60 |
|---|---|---|---|---|---|---|---|---|
| margin | 0.81 | 0.84 | 0.85 | 0.86 | 0.87 | 0.87 | 0.88 | 0.88 |
| works | ++ | ++ | ++ | ++ | ++ | ++ | ++ | ++ |

Working window: **5 … 60** (default 30 inside).

**gateThreshold** — gate activation threshold  (default **0.3**)

| gateThreshold | 0.15 | 0.2 | 0.25 | 0.3 | 0.35 | 0.4 | 0.45 | 0.5 | 0.55 |
|---|---|---|---|---|---|---|---|---|---|
| margin | -0.00 | -0.00 | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 |
| works | X | X | ++ | ++ | ++ | ++ | ++ | ++ | ++ |

Working window: **0.25 … 0.55** (default 0.3 inside).

**gateHysteresis** — gate hysteresis (switching band)  (default **0.08**)

| gateHysteresis | 0.02 | 0.04 | 0.06 | 0.08 | 0.1 | 0.12 | 0.15 | 0.2 |
|---|---|---|---|---|---|---|---|---|
| margin | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 |
| works | ++ | ++ | ++ | ++ | ++ | ++ | ++ | ++ |

Working window: **0.02 … 0.2** (default 0.08 inside).

**onConductance** — transistor ON conductance  (default **5**)

| onConductance | 1 | 2 | 3 | 5 | 7 | 10 | 15 |
|---|---|---|---|---|---|---|---|
| margin | 0.82 | 0.85 | 0.86 | 0.87 | 0.87 | 0.87 | 0.88 |
| works | ++ | ++ | ++ | ++ | ++ | ++ | ++ |

Working window: **1 … 15** (default 5 inside).

**offConductance** — transistor OFF / leakage  (default **0.0005**)

| offConductance | 0.0001 | 0.0002 | 0.0005 | 0.001 | 0.002 | 0.005 | 0.01 |
|---|---|---|---|---|---|---|---|
| margin | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 | 0.86 | 0.86 |
| works | ++ | ++ | ++ | ++ | ++ | ++ | ++ |

Working window: **0.0001 … 0.01** (default 0.0005 inside).

**busDrive** — bus drive conductance (write strength)  (default **5**)

| busDrive | 1 | 2 | 5 | 10 | 20 |
|---|---|---|---|---|---|
| margin | 0.87 | 0.87 | 0.87 | 0.87 | 0.87 |
| works | ++ | ++ | ++ | ++ | ++ |

Working window: **1 … 20** (default 5 inside).

**droop** — pump droop exponent (curve shape)  (default **-0.14**)

| droop | -0.5 | -0.3 | -0.14 | 0.0 | 0.3 | 0.5 |
|---|---|---|---|---|---|---|
| margin | 0.89 | 0.88 | 0.87 | 0.86 | 0.83 | 0.81 |
| works | ++ | ++ | ++ | ++ | ++ | ++ |

Working window: **-0.5 … 0.5** (default -0.14 inside).


## 2-D interaction maps  (++ ≥0.6, + ≥0.3, ~ ≥0.1, . >0, X broken, !! unstable)


**leak (rows) × resistance (cols)** — `map_leak__resistance.svg`

```
  leak\resistance   0.05  0.075    0.1   0.15    0.2    0.3    0.4
  0.005            ++     ++     ++     ++     ++     ++     ++
  0.0125           ++     ++     ++     ++     ++     ++     ++
  0.025            ++     ++     ++     ++     ++     X      X 
  0.05             ++     ++     ++     X      X      .      . 
  0.075            ++     X      X      X      .      .      . 
  0.1              .      X      X      .      .      .      . 
```

**leak (rows) × pumpMax (cols)** — `map_leak__pumpMax.svg`

```
  leak\pumpMax   0.05   0.08    0.1   0.12   0.15   0.18    0.2
  0.005            ++     ++     ++     ++     ++     ++     ++
  0.0125           ++     ++     ++     ++     ++     ++     ++
  0.025            ++     ++     ++     ++     ++     ++     . 
  0.05             X      X      X      X      X      X      X 
  0.075            X      X      X      X      .      .      . 
  0.1              .      .      .      .      .      .      . 
```

**pumpMax (rows) × gateThreshold (cols)** — `map_pumpMax__gateThreshold.svg`

```
  pumpMax\gateThreshold    0.2   0.25    0.3   0.35    0.4   0.45    0.5
  0.05             ++     ++     ++     ++     ++     ++     ++
  0.08             X      ++     ++     ++     ++     ++     ++
  0.1              X      ++     ++     ++     ++     ++     ++
  0.12             X      ++     ++     ++     ++     ++     ++
  0.15             X      X      ++     ++     ++     ++     ++
  0.18             X      X      ++     ++     ++     ++     ++
  0.2              .      X      .      ++     ++     ++     ++
```

**leak (rows) × gateThreshold (cols)** — `map_leak__gateThreshold.svg`

```
  leak\gateThreshold    0.2   0.25    0.3   0.35    0.4   0.45    0.5
  0.005            ++     ++     ++     ++     ++     ++     ++
  0.0125           ++     ++     ++     ++     ++     ++     ++
  0.025            X      ++     ++     ++     ++     ++     ++
  0.05             .      X      X      ++     ++     ++     ++
  0.075            .      .      X      X      X      ++     ++
  0.1              .      .      .      X      X      X      ++
```