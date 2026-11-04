# Signal Master — Roblox v43-ready edition

**File to paste:** `signal_master_v43_ready.lua` (this folder)
**Previous edition (unchanged, kept alongside):** `signal_master_ts2_roblox.lua`
**Web reference:** web game v43, fresh export 410,671 bytes
(`~/workspace/your_files/signal-master/signal-master.html`)

## What this is

A single self-contained LocalScript that builds a 2D signal-box panel in
Roblox (StarterGui ScreenGui), NOT 3D trains. You play the signaller:
set routes signal to signal, watch black headcode berths move live on
the track lines, keep trains on time, avoid SPADs and collisions.

## Install in Studio (user action only)

1. Open Roblox Studio and open your place.
2. In StarterGui, insert a ScreenGui and name it `SignalMasterTS2`.
3. Inside that ScreenGui, insert a LocalScript.
4. Select all of `signal_master_v43_ready.lua`, paste it into that
   LocalScript, and delete any placeholder code that was in it.
5. Press **Ctrl+S** to save the place. This script cannot save for you:
   the Roblox bridge has no save or publish tool, so saving and
   publishing are your actions only.
6. Press **Play** in Studio and prove **Map 1 end to end**: set routes
   signal to signal and get all **5 arrivals (A-101 to A-105)** with no
   SPAD and no collision, until the top bar shows **5/5** and
   "Shift complete". A partial run is not proof.
7. Publish only when that Map 1 5/5 Play test has actually passed.

## Delta vs the previous Luau edition

Everything from the previous edition is kept intact: TS2 systems
(route setting signal to signal, white highlighted track, points swung
automatically, right-click cancel on the first signal, Shift persistent
route with a white square, train info on click, station timetable on
platform click, train menu Assign / Reset / Reverse, departure rules,
auto service change, US aspects, signals rendered above berths, and the
scoring penalties — late −10/min, wrong platform −25, wrong direction
−30, missed stop −50, SPAD −50, collision −250).

Only two behaviour changes were added, both in `trySetRoute`:

### 1. v42 guard — `opposingTrainNearRoute` (adapted, not copied)

Web v42 fixed a collision where a train stopped at 84.8, 0.2 past a
signal, was missed because the web's x-span occupancy test shrank the
span by 0.5 at each end (84.8 failed the 84.5 bound) and because
`trainAheadOf` counted same-direction trains only. The web fix made
the span inclusive and stopped-clear not apply within 5 of the signal.

Luau trains live on graph edges and nodes, not x positions, so the
equivalent here is node/edge membership, which has no margin to slip
through at all. A route is now refused when an opposing train:

- occupies the edge immediately ahead of the entry signal, or
- is sitting at a node on the route's own graph path (other than the
  entry node itself — a train dwelling at the departure station is on
  the other platform face, P1 eastbound / P2 westbound, and does not
  block the departure).

Refusal message names the train and the node/edge, in plain words.

### 2. v43 guard — `farEndApproachTrain` (adapted, not copied)

Web v43 fixed a SPAD where a far-end "claim" (a dwelling train at the
far station with dwell done and a set departure route claiming the
section) flipped a signal to Red in front of a train already committed
in the station throat — Heat Daily seed 15: E-303 0.5 out from
JCT-DEP-9 at line speed, with no room to stop.

The Luau core has **no far-end claim at all**: `aspectOf` never flips
a routed signal to Red because a far-end departure route was set; it
goes Red only when the edge ahead is physically occupied. So that
exact flip cannot happen here, and there is nothing in `aspectOf` to
patch. The equivalent protection is therefore placed at route-setting
time: a departure route is refused when a train travelling the
opposite way is already committed toward this section from the far
end — on an edge whose far end is a path node, heading into the route.
Trains already on a route edge were already refused by the existing
opposing-edge check; this guard covers only the throat approach that
check cannot see.

Conservative side effect, stated plainly: this guard can also refuse
a main-line route through a junction while a branch train is one edge
out from that junction node (the branch train needs the points the
other way). That is points safety, not a bug — cancel and retry after
the branch train clears the junction.

### Already covered by the graph core (not re-added)

- Route-vs-route conflict is already true edge overlap
  (`pathEdgesOverlap`), stricter than the web's x-span overlap.
- An opposing train on any route edge already refuses the route.
- A train's edge occupancy already holds its signal Red in `aspectOf`.
- Sequential release already releases edges one by one behind a train
  (`releaseEdgeFromRoutes`).

No web line for those was pasted in, because the graph core already
does the same job more strictly.

### Deliberately NOT changed

- **Map 5 stays timing-dependent.** No sequential-release guard of any
  kind (full, scoped, or aspect-only) is in this file. The user closed
  that decision 2026-11-04 ~15:39 IST; it is never dispatched unless
  he reverses it himself.
- **Automatics stay STRICT**, as in the previous Luau edition: an
  automatic shows Yellow when the next signal is Red. They were NOT
  flipped to the web's look-through behaviour.
- **Maps 4–8, Daily Challenge, weather, ranks, achievements, Map
  Creator, Community Maps and Shop remain web-only.** This edition
  still covers Maps 1–3 only, which is what a single LocalScript can
  honestly carry.
- **Nothing else added:** no Ctrl+Alt force-route (deliberately left
  out — it bypasses conflict checks), no multiplayer, no editor, no
  announcements, no login, no DataStore, no Robux, no audio ID.
  Background music stays silent by design: `BGM_SOUND_ID = ""`.
  Upload a track you own through Creator Dashboard first, then paste
  its real ID there.

## Verification — stated honestly

- **Read-back:** the file was built by copying the previous edition
  and editing only the header and the guard block (plus the install
  step wording). `diff` against the previous edition shows only those
  sections changed; every TS2 system is otherwise byte-identical.
- **Balance check (not a parse):** no `lua`/`luac` interpreter exists
  on this machine (both checked, not found), so no Luau parse was
  run. A keyword/bracket balance read-back was run instead: the new
  edition has 74 `function` (was 71) and 256 `end` (was 240) — the
  +3 functions are exactly `pathNodeSet`, `opposingTrainNearRoute`
  and `farEndApproachTrain`, and the +16 `end` keywords are exactly
  the blocks inside those three functions plus the two new `if`
  blocks in `trySetRoute`. Parentheses, braces and brackets all
  balance (0 difference) in both files. That is a consistency check,
  NOT a parse and NOT a Play test.
- **NOT proven playable:** this file has NOT been Play-tested in
  Studio, because the user's PC is closed. Do not call it playable
  until the user pastes it in Studio and proves Map 1 5/5 end to end
  (install steps above).
- **Known Studio risks, carried over unchanged from the previous
  edition:** `MouseButton2Click` behaviour, diagonal segment
  rotation, westbound interpolation, and the Map 2 PLP node fallback
  (no node named PLP; the closest node by x is picked).

## Not published, not on GitHub

This file is local only. It has not been shared, published, or pushed
to GitHub. Publishing the game and any GitHub update are separate
steps for the parent agent, after the Studio Play test passes.
