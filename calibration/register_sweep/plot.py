#!/usr/bin/env python3
"""Heatmap of the R/mm x leak margin sweep -> register_sweetspot.png"""
import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

leaks, res, M = [], [], []
with open("register_margin.csv") as f:
    r = csv.reader(f)
    header = next(r)
    leaks = [float(h.split("_")[1]) for h in header[1:]]
    for line in r:
        res.append(float(line[0]))
        M.append([float(x) for x in line[1:]])
M = np.array(M)

fig, ax = plt.subplots(figsize=(7.5, 5.2))
im = ax.imshow(M, aspect="auto", cmap="RdYlGn", vmin=-0.1, vmax=0.9, origin="upper")
ax.set_xticks(range(len(leaks)))
ax.set_xticklabels(leaks)
ax.set_yticks(range(len(res)))
ax.set_yticklabels(res)
ax.set_xlabel("leak conductance  (sealing — higher = leakier)")
ax.set_ylabel("R/mm  (resistor strength — higher = weaker pull)")
ax.set_title("4-bit register read-back margin\n(green = latches reliably; red = loses its bits)")
for i in range(len(res)):
    for j in range(len(leaks)):
        v = M[i, j]
        ax.text(j, i, f"{v:.2f}", ha="center", va="center",
                fontsize=8, color="black" if v > 0.3 else "white")
# mark default operating point (R/mm 0.15, leak 0.025)
ax.scatter([leaks.index(0.025)], [res.index(0.15)], s=240, facecolors="none",
           edgecolors="blue", linewidths=2.2)
ax.annotate("default", (leaks.index(0.025), res.index(0.15)),
            color="blue", fontsize=9, xytext=(4, -10), textcoords="offset points")
plt.colorbar(im, label="logic margin  (stored-0 readback − stored-1 readback)")
plt.tight_layout()
plt.savefig("register_sweetspot.png", dpi=130)
print("wrote register_sweetspot.png")
