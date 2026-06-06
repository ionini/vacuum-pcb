#!/usr/bin/env python3
"""Dependency-free SVG heatmap of the R/mm x leak margin sweep."""
import csv

leaks, res, M = [], [], []
with open("register_margin.csv") as f:
    r = csv.reader(f)
    header = next(r)
    leaks = [h.split("_")[1] for h in header[1:]]
    for line in r:
        res.append(line[0])
        M.append([float(x) for x in line[1:]])

STOPS = [(-0.1, (215, 48, 39)), (0.4, (255, 255, 191)), (0.9, (26, 152, 80))]


def color(m):
    if m <= STOPS[0][0]:
        return STOPS[0][1]
    for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
        if m <= b:
            t = (m - a) / (b - a)
            return tuple(int(ca[i] + t * (cb[i] - ca[i])) for i in range(3))
    return STOPS[-1][1]


cw, ch = 84, 46
x0, y0 = 120, 70
W = x0 + cw * len(leaks) + 30
H = y0 + ch * len(res) + 70
s = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="sans-serif">' % (W, H)]
s.append('<text x="%d" y="28" font-size="18" font-weight="bold">4-bit register read-back margin</text>' % (x0))
s.append('<text x="%d" y="48" font-size="12" fill="#555">green = latches reliably &#183; red = loses its stored bits</text>' % (x0))
s.append('<text x="%d" y="%d" font-size="13" font-weight="bold">leak (sealing &#8594; leakier)</text>' % (x0, H - 14))
s.append('<text x="22" y="%d" font-size="13" font-weight="bold" transform="rotate(-90 22 %d)">R/mm (weaker pull &#8594;)</text>' % (y0 + ch * len(res) // 2, y0 + ch * len(res) // 2))

for j, lk in enumerate(leaks):
    s.append('<text x="%d" y="%d" font-size="12" text-anchor="middle">%s</text>' % (x0 + cw * j + cw // 2, y0 - 8, lk))
for i, rv in enumerate(res):
    s.append('<text x="%d" y="%d" font-size="12" text-anchor="end">%s</text>' % (x0 - 10, y0 + ch * i + ch // 2 + 4, rv))
    for j, m in enumerate(M[i]):
        cr, cg, cb = color(m)
        x, y = x0 + cw * j, y0 + ch * i
        s.append('<rect x="%d" y="%d" width="%d" height="%d" fill="rgb(%d,%d,%d)" stroke="white"/>' % (x, y, cw, ch, cr, cg, cb))
        tc = "black" if m > 0.25 else "white"
        s.append('<text x="%d" y="%d" font-size="12" text-anchor="middle" fill="%s">%.2f</text>' % (x + cw // 2, y + ch // 2 + 4, tc, m))

# default operating point: R/mm 0.15, leak 0.025
di = res.index("0.15") if "0.15" in res else None
dj = leaks.index("0.025") if "0.025" in leaks else None
if di is not None and dj is not None:
    s.append('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#1133cc" stroke-width="3"/>' % (x0 + cw * dj, y0 + ch * di, cw, ch))
    s.append('<text x="%d" y="%d" font-size="11" fill="#1133cc" font-weight="bold">default</text>' % (x0 + cw * dj + 4, y0 + ch * di + ch - 5))
s.append('</svg>')
open("register_sweetspot.svg", "w").write("\n".join(s))
print("wrote register_sweetspot.svg")
