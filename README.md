# Vacuum PCB

A macOS desktop app for designing **pneumatic logic circuits** — vacuum-driven
"transistors" built from two 3D-printed plastic plates sandwiching a thin
silicone sheet — and exporting them as 3D-printable STL geometry.

## How it works

A vacuum transistor: two source/drain holes on the top plate sit above a
hemispherical dimple in the bottom plate. The silicone seals them in the
relaxed state. Pulling vacuum on the dimple (gate) deflects the silicone
downward, connecting the two source/drain channels. NMOS-equivalent;
vacuum-active.

The physical board is a single three-layer sandwich:

```
        top plate (printed plastic)
        ───────── silicone face ─────────   ← z = +siliconeThickness/2
        silicone sheet (one continuous piece)
        ───────── silicone face ─────────   ← z = -siliconeThickness/2
        bottom plate (printed plastic)
```

Channels run as **round bores through each plate's midline**. Transistor
**dimples** are bored into the silicone-facing surface; **source/drain holes**
are vertical drop bores connecting the channel midline to the silicone face;
**edge ports** are horizontal cylindrical bores exiting the board edge.
Through-plate **vias** punch through the silicone with a sealed perimeter, so
a route can cross plates mid-net.

## Workflow

1. Open the app — a new document seeds with the bundled inverter so there's
   always a known-good circuit to start from.
2. **Schematic** tab: drop components from the palette, click pin→pin to
   wire nets. Logic is the source of truth.
3. **Physical** tab: drag components from the parking lot onto the board,
   route channels Manhattan-style, switch plates with `F`, rotate with `R`.
   Layer visibility filter so each plate can be inspected in isolation.
4. **Manufacturing settings**: adjust per-document constants (plate
   thickness, channel diameter, grid pitch…) — these are bound to the
   document, since a printed plate is tied to the parameters it was
   generated for.
5. **DRC** sidebar reports unrouted nets, layer-mismatched routes, and
   minimum-spacing violations. Export is gated on clean DRC.
6. **Export STL** → print top + bottom plates → cut a silicone sheet to fit
   → assemble → plug 17-gauge blunt-tip needles into the edge ports.
7. **3D Preview** tab shows the merged plate meshes as you go.

Printing docs: [BAMBU_EXPORT.md](BAMBU_EXPORT.md) for slicing print-critical
features with a modifier volume, [PRINT_SWEEPS.md](PRINT_SWEEPS.md) for finding
settings empirically (many coupons on one plate) and for the slicer behaviours
that silently invalidate a plate.

## Component palette

Eight primitives:

| Kind            | Symbol | Notes |
| --------------- | ------ | --- |
| Transistor      | Q      | NMOS-equivalent. Pins: `gate`, `a`, `b` (`a`/`b` symmetric). Vacuum on `gate` connects `a`↔`b`. |
| Resistor        | R      | Flow restrictor, sized S / M / L. Serpentine channel between two pins. |
| Vacuum source   | VAC    | Edge port to the pump (active rail). |
| Atmospheric vent | VENT  | Edge port to atmosphere (ground rail). |
| External port   | IN / OUT | Generic edge-entry tube terminal, declared input or output. |
| Screw           | S      | Mechanical fastener: countersink head on top, clearance bore through, hex-nut pocket underneath. No pins. |
| LED             | D      | Visual indicator. Dimple + viewing hole on the opposite plate so silicone deflection is visible. One fluid pin. |
| Sub-part        | U      | Instance of another `.vpcb` from the parts library — reusable sub-circuits. May be nested. |

## Reusable parts

Drop a `.vpcb` into **Application Support / Vacuum PCB / Parts** (Library →
*Reveal Parts Folder in Finder*) and it appears in the schematic palette.
Library files may themselves use sub-parts — nesting expands recursively at
flatten / render time. Reference cycles between files are tolerated at load
and broken at use site with a red placeholder.

## Versioning your designs (iCloud documents)

The `.vpcb` design files live in iCloud at
`~/Library/Mobile Documents/iCloud~com~ionini~Vacuum-PCB/Documents` (synced by
the app), **separate** from this source repo. They're under their own git repo
that uses a split layout so iCloud never corrupts git internals:

- **Working tree:** the iCloud Documents folder (untouched, still iCloud-synced;
  only adds a one-line `.git` pointer file + `.gitignore`).
- **Git directory:** `~/Documents/dev/vacuum-docs` — all volatile git internals
  (index, locks, packfiles) live here, outside iCloud.

Commit design changes from the iCloud folder with plain git:

```bash
cd "$HOME/Library/Mobile Documents/iCloud~com~ionini~Vacuum-PCB/Documents"
git status && git add -A && git commit -m "…"
```

Caveats: this machine only (the `.git` pointer holds an absolute path), and
there's no remote yet — it's local history only. `.DS_Store`, `*.icloud`
placeholders, and `*.zip` exports are gitignored.

## Build

Standard Xcode project. Open `Vacuum PCB.xcodeproj`, Run.

- Sandbox is on; the only entitlement granted is read-write to user-selected
  files (for the STL save panel).
- Custom UTI `com.ionini.vacuum-pcb` is declared programmatically — works
  in the app's own file pickers; Finder doesn't recognize the type
  system-wide.
- [SwiftLint](https://github.com/realm/SwiftLint) runs as a build phase
  (`brew install swiftlint` if missing). Config in `.swiftlint.yml`.

## License

See `LICENSE`.
