#!/usr/bin/env python3
"""Generate a double-inverter resistor-length calibration board (.vpcb).

One physical board carrying N independent double-inverter test cells. All cells
share IN / VAC / VENT. Each cell is Inv1 -> Inv2:
    IN -> Q1.gate ; Q1.a -> VENT ; Q1.b -> MID
    MID -> R1 chain (1..K resistors in series) -> VAC      (the swept part)
    MID -> Q2.gate ; Q2.a -> VENT ; Q2.b -> OUT
    OUT -> R2 (fixed) -> VAC ; OUT -> OUT_<c> port
So OUT_<c> buffers IN *iff* that cell's R1 chain can still pull MID to vacuum.
Assert IN=atm and read which OUT_<c> went high; the transition across cells is
the threshold.

Only the R1 chain differs between cells. Edit CELLS and re-run to change the
sweep. Resistor sizes: S=12 mm, M=20 mm, L=34 mm of channel (XL=44 won't print).
"""
import itertools
import json

LEN = {"S": 12, "M": 20, "L": 34}  # printable channel length per resistor body

# Small first board: sweep R1 chain length by number of resistors in series.
# CHAIN_SIZE is the per-body size — S=12, M=20, L=34 mm of channel each.
# S keeps totals in ~36-72 mm, across where Inv1 starts losing Inv2; L would
# put every cell at 102-204 mm, all deep in the fail region (they read alike).
CHAIN_SIZE = "S"
CHAIN_COUNTS = [3, 4, 5, 6]
CELLS = [[CHAIN_SIZE] * n for n in CHAIN_COUNTS]
R2_SIZE = "M"  # Inv2's load resistor — fixed across every cell

_cc = itertools.count(1)
_nc = itertools.count(1)
components, nets, positions = [], [], []


def comp(kind, label, x, y, **extra):
    cid = f"00000000-0000-0000-0000-{next(_cc):012d}"
    c = {"id": cid, "kind": kind, "label": label}
    c.update(extra)
    components.append(c)
    positions.append({"componentId": cid, "position": {"x": x, "y": y}})
    return cid


def net(label, pins):
    nid = f"00000000-0000-0000-0001-{next(_nc):012d}"
    nets.append({"id": nid, "label": label,
                 "pins": [{"componentId": c, "pinKey": k} for c, k in pins]})
    return nid


# Shared rails / input.
vac = comp("vacuumSource", "VAC", 100, 30)
vent = comp("atmVent", "VENT", 320, 30)
in_port = comp("port", "IN", 540, 30, portDirection="input")

vac_pins = [(vac, "p")]
vent_pins = [(vent, "p")]
in_pins = [(in_port, "p")]

for ci, chain in enumerate(CELLS, start=1):
    y = 120 + (ci - 1) * 90
    q1 = comp("transistor", f"Q1_{ci}", 100, y)
    rs = [comp("resistor", f"R1_{ci}_{i + 1}", 180 + i * 80, y, resistorSize=sz)
          for i, sz in enumerate(chain)]
    q2 = comp("transistor", f"Q2_{ci}", 700, y)
    r2 = comp("resistor", f"R2_{ci}", 790, y, resistorSize=R2_SIZE)
    out = comp("port", f"OUT_{ci}", 880, y, portDirection="output")

    in_pins.append((q1, "gate"))
    vent_pins += [(q1, "a"), (q2, "a")]
    net(f"MID_{ci}", [(q1, "b"), (rs[0], "1"), (q2, "gate")])
    for i in range(len(rs) - 1):
        net(f"N_{ci}_{i + 1}", [(rs[i], "2"), (rs[i + 1], "1")])
    vac_pins.append((rs[-1], "2"))
    net(f"OUT_{ci}", [(q2, "b"), (r2, "1"), (out, "p")])
    vac_pins.append((r2, "2"))

net("IN", in_pins)
net("VENT", vent_pins)
net("VAC", vac_pins)

doc = {
    "logic": {"components": components, "nets": nets},
    "manufacturing": {
        "channelDiameter": 1.5, "dimpleDepth": 1, "dimpleDiameter": 5,
        "gridPitch": 1, "minChannelSpacing": 1.5, "plateThickness": 5,
        "portBoreDiameter": 1.6, "siliconeThickness": 0.5,
    },
    "physical": {
        "boardOutline": {"origin": {"x": 0, "y": 0},
                         "size": {"width": 250, "height": 200}},
        "placements": [],   # unplaced — you place + route in the Physical tab
        "routes": [],
    },
    "schemaVersion": 1,
    "schematic": {"positions": positions},
}

out_path = f"double_inverter_cal_3to6{CHAIN_SIZE}.vpcb"
with open(out_path, "w") as f:
    json.dump(doc, f, indent=2)

tot = sum(LEN[s] for chain in CELLS for s in chain)
print(f"wrote {out_path}")
print(f"  cells:       {len(CELLS)}")
print(f"  transistors: {2 * len(CELLS)}")
print(f"  resistors:   {sum(len(c) for c in CELLS)} chain + {len(CELLS)} load")
print(f"  components:  {len(components)}, nets: {len(nets)}")
print("  R1 lengths (mm): " +
      ", ".join(str(sum(LEN[s] for s in c)) for c in CELLS))
