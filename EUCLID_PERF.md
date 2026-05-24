# Euclid CSG perf — notes & optimization plan

## Fork setup

- **GitHub:** https://github.com/ioni-shape/Euclid (public fork of nicklockwood/Euclid)
  - `baseline` tag → upstream `0409eab` (v0.8.14, the version Vacuum PCB was pinned to before this work)
  - `perf` branch → optimizations on top of baseline
- **Local checkout:** `~/Documents/dev/Euclid` (sibling to `vacuum_pcb`)
  - `origin` → ioni-shape/Euclid (the fork)
  - `upstream` → nicklockwood/Euclid (for pulling future upstream changes)
- **Xcode wiring:** the Vacuum PCB project uses `XCLocalSwiftPackageReference "../../Euclid"`, so all builds pick up local edits immediately. No GitHub round-trip needed during iteration.

**Onboarding a new machine:** clone the fork to `~/Documents/dev/Euclid` next to `vacuum_pcb`, check out `perf`, and Xcode will resolve the local package on first open.

**Sending changes upstream:** push individual commits or cherry-picks to a topic branch on the fork, then `gh pr create --repo nicklockwood/Euclid`.

---


Baseline: Time Profiler trace of the 3D preview rebuild (before the object appears
on screen). 130 s wall-clock, 76.6 s of aggregate CPU time across cores
(≈59 % utilization → parallelism is itself a bottleneck before any algorithmic
work). All numbers below are from that single recording — re-profile after each
change and update them.

The hot code is entirely inside the **Euclid** Swift package (Nick Lockwood,
https://github.com/nicklockwood/Euclid). Changes need to go into a fork or a
local SwiftPM `.package(path:)` override.

---

## Baseline profile (record this before each change)

| Bucket | Self-time % | Notes |
|---|---|---|
| Vacuum PCB code | 47 % | Almost all of it inside Euclid |
| libswiftCore (retain/release/array destroy) | 32 % | ARC churn |
| libsystem_malloc | 14 % | Allocator |
| libsystem_platform (memmove/memset) | 4 % | Buffer copies |

**~50 % of total CPU is memory management, not geometry.** That's the headline.

### Top callers (total time, app code)

```
Mesh.union closure                             88.6 %  67.9 s
└── BSP.init / BSP.initialize                  81.4 %  62.4 s
    └── BSP.insert                             68.7 %  52.7 s
        ├── Polygon.compare → Collection.compare  8.0 %  6.1 s
        │   ├── PlaneComparison.union             3.8 %  2.9 s
        │   ├── PlaneComparison.init(signedDist:) 3.0 %  2.3 s
        │   └── PlaneComparison.init(rawValue:)   1.5 %  1.2 s
        ├── Polygon.split(spanning:)              8.4 %  6.4 s
        │   └── verticesAreDegenerate                    3.7 s
        ├── Array._createNewBuffer (front/back)          6.4 s
        └── ARC traffic attributed here                  8.0 s
```

`inParallel(_:_:)` accounts for 88 % of CPU but is only `DispatchQueue.concurrentPerform(iterations: 2)` — two-way parallelism. The leaf work (`BSP.insert`) is single-threaded.

---

## Status — measured after items 1, 3, 4 landed

Comparing baseline trace to `Trace after all changes.trace` (May 2026):

| Metric | Baseline | After | Δ |
|---|---:|---:|---:|
| Wallclock (trace duration) | 130 s | 10.6 s | **12.3× faster** |
| Total CPU work | 76.6 s | 10.8 s | **7.1× less** |
| App self-time | 36.3 s | 4.2 s | -88 % |
| libswiftCore (ARC) | 24.9 s | 4.1 s | -84 % |
| libsystem_malloc | 10.8 s | 1.4 s | -87 % |

The 7× CPU work reduction is larger than the per-change estimates because tree
reduction has an asymptotic effect (O(K²n) → O(Kn log K) for K-mesh unions) on
top of the constant-factor wins from inlining and capacity reservation. For
K=94 (the channel-mesh case in `PlateBuilder`) that alone is ~14× less work.

## Optimization candidates

Listed in priority order — biggest expected win first. Each has a checkbox so we
can tick them off as the fork progresses, and a "post-fix delta" column to fill
in after re-profiling.

### 1. `PlaneComparison` is doing way too much work per vertex

**File:** `Euclid/Sources/PlaneComparable.swift:198-210`

Combined cost: **~6.4 s** (2.9 s `union` + 2.3 s `init(signedDistance:)` +
1.2 s `init(rawValue:)`), called once per vertex of every polygon classified
during BSP construction.

Current code:

```swift
init(signedDistance: Double) {
    switch signedDistance {
    case ..<(-planeEpsilon): self = .back
    case ...planeEpsilon: self = .coplanar
    default: self = .front
    }
}

func union(_ other: PlaneComparison) -> PlaneComparison {
    PlaneComparison(rawValue: rawValue | other.rawValue)!   // failable init!
}
```

Problems:

- `PlaneComparison(rawValue:)` is a **failable initializer** — it has to construct
  an `Optional`, check it, and force-unwrap. The OR of two values in 0…3 is
  always in 0…3, so the failability is dead weight.
- The range-pattern `switch` on `Double` is heavier than a two-branch ternary.
- Neither is `@inline(__always)`, so they don't fold into the per-vertex loop.

Proposed:

```swift
@inlinable @inline(__always)
init(signedDistance d: Double) {
    self = d < -planeEpsilon ? .back : d > planeEpsilon ? .front : .coplanar
}

@inlinable @inline(__always)
func union(_ other: PlaneComparison) -> PlaneComparison {
    PlaneComparison(rawValue: rawValue | other.rawValue).unsafelyUnwrapped
}
```

- [x] **Applied** in fork commit `527aed3`. Post-fix self-time of `PlaneComparison.*` combined: **0.53 s** (was 6.4 s, -92 %). `Collection<>.compare(with:)` self also dropped from 6.2 s to 0.35 s (-94 %) because the inlined inner calls fold into the loop.

### 2. `Collection.compare(with:)` should be inlined and Bool-based

**File:** `Euclid/Sources/PlaneComparable.swift:234-243`

This is the per-vertex loop in `Polygon.compare(with:)`. It builds and unions
`PlaneComparison` values per vertex (6.1 s self). Most of that work is the
enum-OR mechanics from option 1, but the loop itself is also generic across
`Collection` which prevents specialization opportunities.

Proposed: rewrite the loop in terms of two `Bool`s (`anyFront`, `anyBack`),
short-circuit on both true, and inline directly into `Polygon.compare`. After
option 1 lands, this is partly addressed — but inlining the loop kills the
remaining allocation/dispatch.

- [x] **Subsumed by item 1.** After inlining, `Collection<>.compare(with:)` self-time fell from 6.1 s to 0.35 s — no further rewrite needed for now.

### 3. `BSP.insert` allocates `front` / `back` buffers in the hot loop

**File:** `Euclid/Sources/BSP.swift:241-265`

```swift
while let (node, polygons) = stack.popLast(), !isCancelled() {
    var front = [Polygon](), back = [Polygon]()   // ← allocated every iteration
    for polygon in polygons { ... front.append(...) / back.append(...) ... }
    ...
}
```

`Array._createNewBuffer` charges **6.4 s to `BSP.insert` and another 6.6 s to
`BSP.initialize`** — that's the arrays growing and reallocating. ARC charged
to `BSP.insert` is ~8 s, much of it tied to the same buffer churn.

Proposed:

- `front.reserveCapacity(polygons.count)` and `back.reserveCapacity(polygons.count)`
  at the top of each iteration. Cheap.
- Better: hoist the two buffers outside the `while` loop and call
  `removeAll(keepingCapacity: true)` per iteration.
- Even better: use a single shared `front`/`back` buffer pair across all stack
  frames and copy out the slice when we push to the stack. (More invasive,
  requires care because the stack stores `polygons` references.)

- [x] **Reserved capacity** in fork commit `a92ec48`. `Array._createNewBuffer` total dropped from **13.7 s to 1.0 s (-92 %)**. Skipped the hoisted-buffer variant — diminishing returns at this point.
- [ ] **Hoisted buffers.** Not attempted; current delta already saturates this hotspot.

### 4. `inParallel` is 2-way — leaving cores idle

**File:** `Euclid/Sources/Mesh+CSG.swift:1138-1145`

```swift
private func inParallel(_ op1: () -> Void, _ op2: () -> Void) {
    DispatchQueue.concurrentPerform(iterations: 2) { ... }
}
```

The two ops are `BSP(mesh).clip(self.polygons, ...)` and
`BSP(self).clip(mesh.polygons, ...)` — both end up serially constructing BSP
trees with `BSP.insert`. On an N-core machine, only 2 cores are busy.

Options (increasing scope):

- **Parallelize `BSP.insert` per-subtree.** When the stack pops a node and
  produces `front`/`back` polygon partitions, the two child subtrees are
  independent — they can be inserted concurrently. The current code uses
  an explicit stack; rework into a worker pool or `concurrentPerform`.
- **Parallelize the `Mesh.merge` reduce loop** (`Mesh+CSG.swift:836-848`).
  Currently serial: walks meshes one at a time and unions intersecting ones in.
  Could partition into independent groups and union each group in parallel.

- [ ] **BSP subtree parallelism.** Not attempted — would lift the per-`Mesh.union` 2-core ceiling that still bites the final phases of tree reduction. Real refactor: ~100–200 LOC, needs node-index renumbering when subtree forests get spliced. Left for a future round.
- [x] **`Mesh.merge` parallelism** in fork commits `f0587ed` (component partitioning — superseded) and `1aae8cb` (**tree-style pairwise reduction**, the version that actually shipped). The first attempt produced no parallelism because every call in the real workload had all meshes in a single bounds-overlap component (e.g. the 94-mesh channel-mesh case). The tree-reduction variant breaks the K-mesh union into ⌈log₂ K⌉ parallel phases and also has a smaller asymptotic CSG cost (O(K n log K) vs O(K² n) for the sequential left-fold). Post-fix: `static Mesh.merge` total dropped from **9.7 s to 0.22 s (-98 %)**, `closure #3 in Mesh.union` total from **67.7 s to 6.8 s (-90 %)**.

### 5. `Polygon.split(spanning:)` constructs degenerate polygons before discarding

**File:** `Euclid/Sources/Polygon+CSG.swift:121-184`

```swift
if !verticesAreDegenerate(f) {
    front.append(Polygon(unchecked: f, ...))
}
if !verticesAreDegenerate(b) {
    back.append(Polygon(unchecked: b, ...))
}
```

`verticesAreDegenerate` is 3.7 s — called every split. The check happens
*after* `f`/`b` are fully built. Some cases can be detected during the
inner loop (e.g. coincident points already filtered by the
`f.last?.position != v.position` checks) so we never even allocate `f`/`b`
when the split outcome is trivially degenerate.

Also, when the polygon is convex and the split produces two non-degenerate
polygons, each new `Polygon(...)` constructor copies the vertex array. Worth
checking whether the constructor's `sanitizeNormals: false` path actually
skips that copy or just keeps the array as-is.

- [ ] **Early-out in split loop.** Delta in `Polygon.split(spanning:)` total: ___
  (was 6.4 s)

### 6. `Mesh.Storage.deinit` churn from temporary `Mesh` objects

**File:** `Euclid/Sources/Mesh+CSG.swift:836-881`

`Mesh.Storage.deinit` is 4.7 s total / 2.8 s of ARC churn. `Mesh.merge` keeps
wrapping intermediate results in new `Mesh` storage on every reduce step.

Proposed: in `Mesh.merge` (`Mesh+CSG.swift:836`), work on `[Polygon]` (plus
bounds) until the very end, then wrap once in a `Mesh`. Avoids allocating a
new `Mesh.Storage` per intermediate reduction.

- [ ] **Applied.** Post-fix `Mesh.Storage.deinit` total: ___ ms (was 4.7 s)

### 7. `BSP.initialize` shuffles via `polygons.shuffled(using:)`

**File:** `Euclid/Sources/BSP.swift:218`

`shuffled(using:)` returns a copy. For large polygon arrays this is a full
array copy + 300 ms of ARC. Use `var copy = polygons; copy.shuffle(using:)`
on a single local mutable array. Small win, but free.

- [ ] **Applied.**

---

## How to record a comparable trace

Same template, same input scene, same machine, no other Xcode/Instruments
sessions, **Release build** (Debug profiling is meaningless for this).

1. Build the app in Release: `xcodebuild -scheme "Vacuum PCB" -configuration Release build`
   — or use Product → Profile in Xcode (`⌘I`), which auto-uses Release.
2. In Instruments, choose the **Time Profiler** template.
3. Attach to the running app (or relaunch via Profile).
4. **Important — reset to a clean state before recording.** For the "before
   showing object" rebuild we're measuring, you want a known starting document
   and to start recording *just before* triggering the rebuild that's slow.
5. Press Record, do the action, wait for the object to appear, press Stop.
6. Save as `.trace` somewhere I can read (e.g. `~/Desktop/Trace.trace`).

Tips for getting a clean comparison:

- Recording duration doesn't matter much, but try to keep it within ±20 % of the
  baseline (130 s).
- Make sure no other heavy processes are running (Xcode indexing, Spotlight
  reindex, browser tabs eating CPU).
- The Time Profiler weights samples by wall-clock, so what matters for
  comparison is **per-symbol ms**, not "% of recording".

---

## How to read the trace (so we can re-run this analysis)

The trace bundle is a directory. We don't open it in Instruments — we ask Claude
to parse it with `xctrace`. Here's the recipe:

### 1. Export raw time-profile XML

```bash
xcrun xctrace export --input ~/Desktop/Trace.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
    --output /tmp/timeprofile.xml
```

For long recordings this will be 20–30 MB.

If you want to see what tables are in the trace first:

```bash
xcrun xctrace export --input ~/Desktop/Trace.trace --toc
```

(Look for `<table schema="time-profile" .../>`.)

### 2. Aggregate self / total time per symbol

The XML is a list of `<row>`s, each with a `<weight>` (sample time in ns) and a
`<backtrace>` (frames leaf-first). Many frames reuse `id="..."` / `ref="..."`
references — the parser has to resolve those.

For each sample:
- **Self time** of the top (leaf) frame's symbol += weight.
- **Total time** of every *unique* symbol in the stack += weight.

Then sort and report. The script that produced the baseline lives at
`/tmp/parse_trace.py` (also kept inline below in case it gets cleaned up).

```python
#!/usr/bin/env python3
import sys, xml.etree.ElementTree as ET
from collections import defaultdict

XML_PATH = "/tmp/timeprofile.xml"
ids = {}

def resolve(elem):
    ref = elem.get("ref")
    if ref is not None: return ids[ref]
    eid = elem.get("id")
    if eid: ids[eid] = elem
    return elem

tree = ET.parse(XML_PATH); root = tree.getroot()
self_time, total_time = defaultdict(int), defaultdict(int)
self_by_binary = defaultdict(int)
binary_for_symbol = {}
total_weight_ns = 0

def fname(e):  e = resolve(e); return e.get("name")
def fbin(e):
    e = resolve(e); b = e.find("binary")
    return None if b is None else resolve(b).get("name")

for row in root.findall("./node/row"):
    w = int(resolve(row.find("weight")).text)
    total_weight_ns += w
    tb = row.find("tagged-backtrace")
    if tb is None: continue
    bt = resolve(tb).find("backtrace")
    if bt is None: continue
    frames = resolve(bt).findall("frame")
    if not frames: continue
    top_sym, top_bin = fname(frames[0]), fbin(frames[0])
    self_time[top_sym] += w
    self_by_binary[top_bin] += w
    binary_for_symbol.setdefault(top_sym, top_bin)
    seen = set()
    for f in frames:
        s, b = fname(f), fbin(f)
        if s in seen: continue
        seen.add(s)
        total_time[s] += w
        binary_for_symbol.setdefault(s, b)

def ms(ns): return f"{ns/1e6:.1f}"
def pct(p, w): return f"{(100*p/w):5.2f}%" if w else "  n/a "

print(f"Total CPU weight: {ms(total_weight_ns)} ms")
print("\n=== Self time by binary ===")
for b, w in sorted(self_by_binary.items(), key=lambda x: -x[1])[:10]:
    print(f"  {pct(w, total_weight_ns)}  {ms(w):>10} ms  {b}")
print("\n=== Top 40 self time, Vacuum PCB only ===")
for s, w in sorted(((s,w) for s,w in self_time.items() if binary_for_symbol.get(s)=="Vacuum PCB"), key=lambda x:-x[1])[:40]:
    print(f"  {pct(w, total_weight_ns)}  {ms(w):>10} ms  {s}")
print("\n=== Top 40 total time, Vacuum PCB only ===")
for s, w in sorted(((s,w) for s,w in total_time.items() if binary_for_symbol.get(s)=="Vacuum PCB"), key=lambda x:-x[1])[:40]:
    print(f"  {pct(w, total_weight_ns)}  {ms(w):>10} ms  {s}")
```

### 3. Caller / callee attribution for a specific symbol

When a hot symbol shows up, knowing *who calls it* and *what it calls* tells
you what to fix. For each sample, find the frame matching the target symbol,
then the frame above is the caller and the frame below is the callee. Sum
weights.

This is what produced the "Top callers / Top callees" tables in the analysis.
See `/tmp/parse_trace2.py` for the variant. Pattern:

```python
TARGETS = ["BSP.insert(_:_:)", "PlaneComparison.union(_:)", ...]
caller_of = {t: defaultdict(int) for t in TARGETS}
callee_of = {t: defaultdict(int) for t in TARGETS}

for row in rows:
    w = ...
    names = [fname(f) for f in frames]   # leaf-first
    for i, nm in enumerate(names):
        if nm in caller_of:
            if i > 0:        callee_of[nm][names[i-1]] += w   # one frame closer to leaf
            if i + 1 < n:    caller_of[nm][names[i+1]] += w   # one frame closer to root
```

### 4. Attributing ARC / malloc cost to app code

`swift_release`, `swift_retain`, `swift_arrayDestroy`, `_xzm_*malloc`, `_xzm_free`,
`_platform_memmove`, `_platform_memset` are leaf frames in libswiftCore /
libsystem_malloc / libsystem_platform. To see *which app code* triggers them,
walk up the stack until you hit a frame whose binary is `"Vacuum PCB"` and
charge the weight there.

This is how we discovered `BSP.insert` is responsible for ~8 s of ARC traffic
even though its self-time is "only" 5.8 s.

### 5. Things to look at first when re-profiling

- **Self-time by binary** — has `libswiftCore` / `libsystem_malloc` dropped?
- **Top-40 self-time in `Vacuum PCB`** — did the symbol we just optimized fall off?
- **Top-40 total time in `Vacuum PCB`** — has `BSP.insert` / `Mesh.union` total
  CPU dropped? (Total time is the real headline; self-time can shift around as
  inlining changes.)
- **`inParallel(_:_:)` total vs. total CPU weight** — if it's still ~90 %, the
  parallelism ceiling hasn't moved.
- **Wall-clock** of the same scenario in the app (not in the trace) — the
  trace gives CPU time; we ultimately care about user-visible latency.

---

## Working notes / open questions

- The trace was on macOS 26.5, M-series Mac. Re-profiling on a different
  machine class will shift the parallelism story.
- The `<deduplicated_symbol>` rows in SwiftUICore (~8 s) are layout/diff work
  happening *during* the rebuild but not driven by the CSG pipeline — separate
  investigation if rebuild latency still feels bad after Euclid is fixed.
- `Mesh.Storage.__deallocating_deinit` is 6.2 % total — confirms item #6 is
  real, but only worth doing after items 1–4.
- Need to verify `Polygon(unchecked:...)` doesn't itself copy vertices on the
  `sanitizeNormals: false` path; if it does, that's another quick win.
