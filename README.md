# Signal Master

A 2D train signalling game. You are the signaller — set routes signal to signal, keep trains on time, and don't let them meet head-on.

Created by: lucifer

## Play the web version

Open `index.html` in a browser, or open the public link https://aditya95595.github.io/SignalMaster/ — GitHub Pages is enabled on this repository (Settings → Pages → Deploy from branch → main) and serves the v43 build. The game is now at v43.

No login is needed. Each player runs their own solo copy.

## How to play

- **Signals:** Red = Stop, Yellow = Approach, Flashing Yellow = Approach Medium, Green = Clear.
- **Controlled signals** are round, at stations, junctions, loops and crossovers.
- **Automatic signals** are square, between stations, and clear by themselves.
- **Routes:** click a round controlled signal, then the next signal. The track between turns white, points swing automatically. A route runs manual → automatic → manual, never across a manual signal.
- **Cancel a route:** right-click the first signal, or use Cancel route.
- **Trains:** click a train berth for speed, next stop, delay, origin → destination, platform, type and length. Freight trains are longer and brake earlier.
- **Maps:** Map 1 Single Line (Albany → Syracuse), Map 2 Passing Loop (Pine Loop), Map 3 Branch Junction (Branchville), Map 4 Double Track with Crossovers, Map 5 Grand Network, plus Original and Community maps.

## Roblox version

`roblox/signal_master_ts2_roblox.lua` is a self-contained LocalScript that plays like TS2 (Train Signalling Simulator) in Roblox — same route, cancel, persistent-route, train-info, station-info and train-menu systems, in Luau.

To install it in Roblox Studio: create a ScreenGui, add a LocalScript inside it, paste the file, press Ctrl+S, then Play and prove Map 1 end to end. Saving and publishing are done in Studio. No login is built into the game, and no audio, Robux or DataStore IDs are invented in the file.

`roblox/signal_master_v43_ready.lua` is the v43-ready Luau file (Maps 1-3, TS2-style). It has not yet been Play-tested in Roblox Studio — see the install notes in `roblox/signal_master_v43_ready_README.md`.

## Status

The web version in `index.html` is the v43 build (a snapshot of the latest shared build). The game logic is still being fixed and proven map by map — Map 1 (5/5 arrivals) and Map 2 loop mechanics are the current proven baseline.
