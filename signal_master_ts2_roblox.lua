-- ============================================================================
-- Signal Master -- TS2-style signalling game for Roblox (2D signal-box panel)
-- ============================================================================
-- WHAT THIS IS
--   A single self-contained LocalScript. It builds a 2D signal-box panel in
--   Roblox (StarterGui ScreenGui), NOT 3D trains. You play the signaller:
--   set routes signal to signal, watch headcode berths move live on the
--   track lines, keep trains on time, and avoid SPADs and collisions.
--
-- GAMEPLAY INSPIRATION (NOT COPIED CODE)
--   Gameplay systems are adapted from TS2 - Train Signalling Simulator
--   (https://github.com/ts2/ts2, GPL-2.0, by its authors). The systems
--   adapted are: route setting signal to signal, white highlighted track,
--   points turned automatically, first signal Yellow or Green by the
--   second signal, cancel by right-click, auto-cancel by the first train,
--   persistent routes with Shift, train info on click, station info on
--   platform click, train menu (Assign / Reset / Reverse), departure
--   rules, auto service change, and scoring penalties. All code, text,
--   map layouts and US signalling in this file are original. No TS2
--   source code, assets, or text were copied into this file.
--
-- US SIGNALLING USED HERE (not UK, not Indian)
--   Controlled signals (round) sit at stations, junctions, loops and
--   crossovers. Automatic signals (square, labelled AUTO) sit in the
--   section between stations and clear by themselves.
--   Red = Stop. Yellow = Approach (prepare to stop at the next signal).
--   Flashing Yellow = Approach Medium (medium speed).
--   Green = Clear.
--   A route runs from a controlled signal to the next signal only:
--   manual -> automatic -> manual. No route ever crosses a manual
--   signal. Set the next route again from the next manual signal.
--
-- STUDIO INSTALL (user action only -- read this before pasting)
--   1. Open Roblox Studio and open your place.
--   2. In StarterGui, insert a ScreenGui and name it SignalMasterTS2.
--   3. Inside that ScreenGui, insert a LocalScript.
--   4. Select all of this file, paste it into that LocalScript, and
--      delete any placeholder code that was in the LocalScript.
--   5. Press Ctrl+S to save the place. This script cannot save for you:
--      the Roblox bridge used by the assistant has no save or publish
--      tool, so saving and publishing are your actions only.
--   6. Press Play in Studio and test Map 1: click a round signal, then
--      the next signal, and watch the track turn white and the train go.
--   7. Publish only when a Play test has actually passed.
--
-- LIMITS, STATED PLAINLY
--   * Music: the background-music SoundId is left as an empty string
--     below (BGM_SOUND_ID = ""). No audio ID has been invented. Upload
--     a track you own through Creator Dashboard first, then paste its
--     real ID there. Until then the game is silent by design.
--   * No invented Robux prices, no invented DataStore names, no
--     Marketplace products. Progress, scores and stars live only in
--     this play session (in-memory tables). Nothing is saved.
--   * No login anywhere in this game. It never asks for a username,
--     password, or account, and it never reads the player's account
--     data. The signaller name shown is the fixed label "lucifer"
--     from the game's own settings, not a logged-in account.
--   * TS2's Ctrl+Alt forcing route is DELIBERATELY LEFT OUT. In TS2
--     it bypasses conflict checks and can crash trains on purpose.
--     This game never offers it. A route that conflicts is refused
--     with a plain reason instead.
--   * NOT YET PROVEN: this file has not been Play-tested in Studio,
--     because the user's PC is closed. Do not call it playable until
--     a Studio Play test proves Map 1 end to end.
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BGM_SOUND_ID = "" -- empty on purpose; see header. No invented ID.
local SIGNALLER_NAME = "lucifer"

-- ---------------------------------------------------------------------------
-- Small helpers (no external modules, so this file stays self-contained)
-- ---------------------------------------------------------------------------
local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function splitPath(path)
	-- "A-101" style codes only; this helper is for log lines, not parsing.
	return path
end

local function fmtTime(seconds)
	local h = math.floor(seconds / 3600) % 24
	local m = math.floor(seconds / 60) % 60
	local s = math.floor(seconds) % 60
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function dist(x1, y1, x2, y2)
	local dx = x2 - x1
	local dy = y2 - y1
	return math.sqrt(dx * dx + dy * dy)
end

-- ---------------------------------------------------------------------------
-- Game state (one source of truth; UI only reads from here, never the
-- other way round)
-- ---------------------------------------------------------------------------
local State = {
	mapIndex = 1,
	clock = 9 * 3600, -- 09:00:00 game clock
	speed = 1,
	paused = false,
	score = 0,
	arrivals = 0,
	arrivalsNeeded = 5,
	failed = false,
	selectedSignal = nil, -- entry signal waiting for an exit click
	selectedTrain = nil,
	selectedStation = nil,
	selectedRoute = nil,
	logLines = {},
}

local function log(msg)
	table.insert(State.logLines, 1, fmtTime(State.clock) .. "  " .. msg)
	while #State.logLines > 200 do
		table.remove(State.logLines)
	end
	if State.logText then
		State.logText.Text = table.concat(State.logLines, "\n")
	end
end

local function addScore(points, reason)
	State.score = State.score + points
	if points < 0 then
		log(reason .. " (" .. tostring(points) .. " pts)")
	else
		log(reason .. " (+" .. tostring(points) .. " pts)")
	end
end

-- ---------------------------------------------------------------------------
-- Track graph (this is the core fix: no line-index + x hacks)
-- ---------------------------------------------------------------------------
-- A node is a point on the panel: {id, x, y} in panel units (0..1000, 0..600).
-- An edge is a track section between two nodes. A train's position is a
-- distance along one edge, interpolated every frame, so crossing points
-- means travelling along the crossover edge itself -- never a snap from
-- one line to another.
-- A points group sits at a node and selects exactly one outgoing edge:
-- its Normal edge or its Reverse edge. Routes choose the edge; the
-- points then swing to match. Trains only ever travel on the selected
-- edge, so a train follows the highlighted path it was routed on.
local Nodes = {}    -- id -> {id, x, y}
local Edges = {}    -- id -> {id, from, to, line, pointsGroup, occupiedBy}
local NodeEdges = {} -- node id -> list of edge ids leaving that node
local Signals = {}  -- id -> signal table (see below)
local Points = {}   -- id -> {id, node, normalEdge, reverseEdge, state}
local Stations = {} -- code -> {code, name, x, nodeA, nodeB, platforms}
local Routes = {}   -- list of active route tables
local Trains = {}   -- id -> train table
local Timetable = {} -- list of service tables for the current map

local function addNode(id, x, y)
	Nodes[id] = { id = id, x = x, y = y }
	NodeEdges[id] = {}
	return Nodes[id]
end

local function addEdge(id, fromId, toId, line, pointsGroup)
	Edges[id] = { id = id, from = fromId, to = toId, line = line,
		pointsGroup = pointsGroup, occupiedBy = nil }
	table.insert(NodeEdges[fromId], id)
	table.insert(NodeEdges[toId], id)
	return Edges[id]
end

local function edgeOtherEnd(edge, nodeId)
	if edge.from == nodeId then return edge.to end
	return edge.from
end

local function edgeLength(edge)
	local a = Nodes[edge.from]
	local b = Nodes[edge.to]
	return dist(a.x, a.y, b.x, b.y)
end

-- Breadth-first path through the graph from one node to another.
-- Points nodes may use either branch (the route will swing the points
-- to the branch it uses). Manual signal nodes are barriers: the path
-- may start at one and end at one, but may not pass through a third.
local function findPath(fromNode, toNode)
	local cameFrom = {}
	local cameEdge = {}
	local queue = { fromNode }
	cameFrom[fromNode] = true
	local head = 1
	while head <= #queue do
		local cur = queue[head]
		head = head + 1
		if cur == toNode then break end
		for _, edgeId in ipairs(NodeEdges[cur]) do
			local edge = Edges[edgeId]
			local nxt = edgeOtherEnd(edge, cur)
			if not cameFrom[nxt] then
				-- Do not pass through a manual signal node in the middle.
				local blocks = false
				for _, sig in pairs(Signals) do
					if sig.node == nxt and sig.kind == "controlled"
						and nxt ~= toNode then
						blocks = true
					end
				end
				if not blocks then
					cameFrom[nxt] = true
					cameEdge[nxt] = edgeId
					table.insert(queue, nxt)
				end
			end
		end
	end
	if not cameFrom[toNode] then return nil end
	local path = {}
	local cur = toNode
	while cur ~= fromNode do
		local edgeId = cameEdge[cur]
		if not edgeId then return nil end
		table.insert(path, 1, edgeId)
		cur = edgeOtherEnd(Edges[edgeId], cur)
	end
	return path
end

local function pathEdgesOverlap(pathA, pathB)
	for _, a in ipairs(pathA) do
		for _, b in ipairs(pathB) do
			if a == b then return a end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Signals, aspects, routes
-- ---------------------------------------------------------------------------
-- Signal: {id, code, node, kind, dir, x, y, button, lamp}
-- kind: "controlled" (round) or "auto" (square, AUTO).
-- dir: 1 = eastbound (increasing node order), -1 = westbound.
local function addSignal(id, code, nodeId, kind, dir)
	local node = Nodes[nodeId]
	Signals[id] = { id = id, code = code, node = nodeId, kind = kind,
		dir = dir, x = node.x, y = node.y - 18, route = nil }
	return Signals[id]
end

local function signalRouteFor(sig)
	for _, route in ipairs(Routes) do
		if route.entry == sig.id then return route end
	end
	return nil
end

local function nextSignalAhead(sig)
	-- The next signal in this signal's direction along the same line,
	-- ignoring branch automatics on a different line.
	local best = nil
	local bestDist = nil
	for _, other in pairs(Signals) do
		if other.id ~= sig.id and other.dir == sig.dir then
			local d = (other.x - sig.x) * sig.dir
			if d > 0 and (bestDist == nil or d < bestDist) then
				-- Only count signals on the same track row (within 60 units).
				if math.abs(other.y - sig.y) < 60 then
					best = other
					bestDist = d
				end
			end
		end
	end
	return best
end

local function edgeAheadOfSignal(sig)
	-- The edge immediately ahead of this signal, in its direction.
	local node = Nodes[sig.node]
	for _, edgeId in ipairs(NodeEdges[sig.node]) do
		local edge = Edges[edgeId]
		local other = Nodes[edgeOtherEnd(edge, sig.node)]
		if (other.x - node.x) * sig.dir > 0 then
			return edge
		end
	end
	return nil
end

-- TS2 aspect rule, written out plainly:
--   Controlled, no route: Red.
--   Controlled or auto, route set: Yellow, or Green if the next signal
--   ahead is already Yellow or Green.
--   Automatic, no route: Red if its own block is occupied, Yellow if
--   the next signal is Red, Flashing Yellow if the next is Yellow,
--   Green if the next is Green or Flashing Yellow and the block is free.
--   A signal behind a train's tail returns to Red because the train
--   still occupies the edge behind it; aspects are recomputed every
--   frame from live occupancy, never cached across frames.
local function aspectOf(sig, depth)
	depth = depth or 0
	if depth > 6 then return "Red" end
	local route = signalRouteFor(sig)
	if sig.kind == "controlled" and not route then
		return "Red"
	end
	local ahead = edgeAheadOfSignal(sig)
	if ahead and ahead.occupiedBy then
		return "Red"
	end
	local nxt = nextSignalAhead(sig)
	if route then
		if nxt and (aspectOf(nxt, depth + 1) == "Yellow"
			or aspectOf(nxt, depth + 1) == "Green") then
			return "Green"
		end
		return "Yellow"
	end
	-- Automatic, no route of its own: it clears by itself.
	if not nxt then return "Green" end
	local na = aspectOf(nxt, depth + 1)
	if na == "Red" then return "Yellow" end
	if na == "Yellow" then return "Flashing" end
	return "Green"
end

local function routeEdgesBetween(entrySig, exitSig)
	-- A valid exit is downstream of the entry, and the path must not
	-- cross a manual signal. findPath already enforces the barrier.
	return findPath(entrySig.node, exitSig.node)
end

local function trySetRoute(entrySig, exitSig, persistent)
	if State.failed then return false, "Shift has failed." end
	if entrySig.kind ~= "controlled" then
		return false, entrySig.code .. " is an automatic signal. Routes "
			.. "start only from controlled (round) signals."
	end
	if exitSig.id == entrySig.id then
		return false, "Pick a different signal as the exit."
	end
	-- Exit must be downstream of the entry.
	if (exitSig.x - entrySig.x) * entrySig.dir <= 0 then
		return false, exitSig.code .. " is not downstream of "
			.. entrySig.code .. ". A route runs downstream only."
	end
	local path = routeEdgesBetween(entrySig, exitSig)
	if not path then
		return false, exitSig.code .. " is not a valid exit for "
			.. entrySig.code .. ". A route never crosses the next "
			.. "manual signal: set it to the next automatic first, "
			.. "then set the next manual section after that."
	end
	-- True graph conflict only: a shared edge, a shared platform node,
	-- or a points group already used in conflict by another route.
	for _, route in ipairs(Routes) do
		local shared = pathEdgesOverlap(path, route.edges)
		if shared then
			return false, "Route refused: " .. route.entryCode .. " to "
				.. route.exitCode .. " already uses section " .. shared
				.. ". Cancel that route first, then set this one."
		end
	end
	-- Single-line deadlock guard: an opposing train already inside the
	-- inter-station section blocks an opposing route into it. The
	-- second train is held at its station signal instead of meeting
	-- the first train face to face in the middle.
	for _, edgeId in ipairs(path) do
		local edge = Edges[edgeId]
		if edge.occupiedBy then
			local other = Trains[edge.occupiedBy]
			if other and other.dir ~= entrySig.dir then
				return false, "Opposing train " .. other.code
					.. " is already in section " .. edgeId
					.. ". Hold this train at " .. entrySig.code
					.. " until that train clears the section."
			end
		end
	end
	-- Occupied platform guard: refuse into a platform that is occupied,
	-- unless the player has chosen Call-on (handled by the caller).
	for _, edgeId in ipairs(path) do
		local edge = Edges[edgeId]
		if edge.occupiedBy and not State.callOn then
			local other = Trains[edge.occupiedBy]
			if other and other.dir == entrySig.dir then
				return false, "Section " .. edgeId .. " is occupied by "
					.. other.code .. ". Wait for it to clear, or use "
					.. "Call-on to enter an occupied section slowly."
			end
		end
	end
	-- Swing points automatically to the branch this path uses.
	for _, edgeId in ipairs(path) do
		local edge = Edges[edgeId]
		if edge.pointsGroup then
			local pts = Points[edge.pointsGroup]
			if pts then
				if pts.failed then
					return false, "Points " .. pts.id .. " have failed "
						.. "(flashing purple). Leave them until they "
						.. "recover, then set the route again."
				end
				if edgeId == pts.reverseEdge then
					pts.state = "Reverse"
				else
					pts.state = "Normal"
				end
			end
		end
	end
	local route = { entry = entrySig.id, entryCode = entrySig.code,
		exit = exitSig.id, exitCode = exitSig.code, edges = path,
		persistent = persistent or false, released = {} }
	table.insert(Routes, route)
	entrySig.route = route
	log("Route set: " .. entrySig.code .. " to " .. exitSig.code
		.. (route.persistent and " (persistent)" or ""))
	return true, "Route set: " .. entrySig.code .. " to " .. exitSig.code
end

local function cancelRoute(route, reason)
	if not route then return end
	for i, r in ipairs(Routes) do
		if r == route then table.remove(Routes, i) break end
	end
	local sig = Signals[route.entry]
	if sig then sig.route = nil end
	log("Route cancelled: " .. route.entryCode .. " to " .. route.exitCode
		.. (reason and (" (" .. reason .. ")") or ""))
end

local function releaseEdgeFromRoutes(edgeId, train)
	-- Sequential release: as a train clears an edge, that edge drops
	-- out of the route behind it. A non-persistent route is cancelled
	-- entirely once its first train has passed its exit.
	for i = #Routes, 1, -1 do
		local route = Routes[i]
		local found = false
		for _, e in ipairs(route.edges) do
			if e == edgeId then found = true break end
		end
		if found then
			route.released[edgeId] = true
			local allReleased = true
			for _, e in ipairs(route.edges) do
				if not route.released[e] then allReleased = false break end
			end
			if allReleased and not route.persistent then
				cancelRoute(route, "train passed through")
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Maps (US only; Map 1 is the fully playable map, Maps 2-3 share the core)
-- ---------------------------------------------------------------------------
-- Panel units: x 0..1000 across, y 0..600 down. Main line y = 300.
-- Loop line y = 210. Branch line runs down-right from the junction.
local function buildMap1()
	Nodes = {}; Edges = {}; NodeEdges = {}; Signals = {}; Points = {}
	Stations = {}; Routes = {}; Trains = {}; Timetable = {}
	addNode("ALB", 60, 300); addNode("N2", 250, 300)
	addNode("N3", 450, 300); addNode("N4", 650, 300)
	addNode("SYR", 940, 300)
	addEdge("E1", "ALB", "N2", "main")
	addEdge("E2", "N2", "N3", "main")
	addEdge("E3", "N3", "N4", "main")
	addEdge("E4", "N4", "SYR", "main")
	Stations.ALB = { code = "ALB", name = "Albany", x = 60,
		platforms = { P1 = nil, P2 = nil } }
	Stations.SYR = { code = "SYR", name = "Syracuse", x = 940,
		platforms = { P1 = nil, P2 = nil } }
	-- Eastbound controlled at Albany, westbound controlled at Syracuse;
	-- automatics between them, both directions, on the same single line.
	addSignal("ALB-DEP", "ALB-DEP", "ALB", "controlled", 1)
	addSignal("ALB-A1", "ALB-AUTO-1", "N2", "auto", 1)
	addSignal("ALB-A2", "ALB-AUTO-2", "N3", "auto", 1)
	addSignal("SYR-W", "SYR-W", "N4", "controlled", 1)
	addSignal("SYR-DEP", "SYR-DEP", "SYR", "controlled", -1)
	addSignal("SYR-A2", "SYR-AUTO-2", "N4", "auto", -1)
	addSignal("SYR-A1", "SYR-AUTO-1", "N3", "auto", -1)
	addSignal("ALB-W", "ALB-W", "N2", "controlled", -1)
	Timetable = {
		{ code = "A-101", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 0, dir = 1, dwell = 15, length = 4 },
		{ code = "A-102", kind = "Amtrak", from = "SYR", to = "ALB",
			depart = 60, dir = -1, dwell = 15, length = 4 },
		{ code = "A-103", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 150, dir = 1, dwell = 15, length = 4 },
		{ code = "A-104", kind = "Amtrak", from = "SYR", to = "ALB",
			depart = 210, dir = -1, dwell = 15, length = 4 },
		{ code = "A-105", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 300, dir = 1, dwell = 15, length = 4 },
	}
	State.arrivalsNeeded = 5
end

local function buildMap2()
	-- Pine Loop: a loop line above the main line between two points
	-- groups. A train routed into the loop travels along the loop edge
	-- itself; it never snaps from the main line to the loop line.
	buildMap1()
	Nodes = {}; Edges = {}; NodeEdges = {}; Signals = {}; Points = {}
	Stations = {}; Routes = {}; Trains = {}; Timetable = {}
	addNode("ALB", 60, 300); addNode("PLP-W", 380, 300)
	addNode("PLP-LW", 380, 210); addNode("PLP-LE", 620, 210)
	addNode("PLP-E", 620, 300); addNode("SYR", 940, 300)
	addNode("N2", 220, 300); addNode("N4", 780, 300)
	addEdge("E1", "ALB", "N2", "main")
	addEdge("E2", "N2", "PLP-W", "main")
	addEdge("E3", "PLP-W", "PLP-E", "main")
	addEdge("E4", "PLP-E", "N4", "main")
	addEdge("E5", "N4", "SYR", "main")
	addEdge("L1", "PLP-W", "PLP-LW", "loop", "PT-PLP-01")
	addEdge("L2", "PLP-LW", "PLP-LE", "loop")
	addEdge("L3", "PLP-LE", "PLP-E", "loop", "PT-PLP-02")
	Points["PT-PLP-01"] = { id = "PT-PLP-01", node = "PLP-W",
		normalEdge = "E3", reverseEdge = "L1", state = "Normal",
		failed = false }
	Points["PT-PLP-02"] = { id = "PT-PLP-02", node = "PLP-LE",
		normalEdge = "E3", reverseEdge = "L3", state = "Normal",
		failed = false }
	Stations.ALB = { code = "ALB", name = "Albany", x = 60,
		platforms = { P1 = nil, P2 = nil } }
	Stations.PLP = { code = "PLP", name = "Pine Loop", x = 500,
		platforms = { P1 = nil, P2 = nil } }
	Stations.SYR = { code = "SYR", name = "Syracuse", x = 940,
		platforms = { P1 = nil, P2 = nil } }
	addSignal("ALB-DEP", "ALB-DEP", "ALB", "controlled", 1)
	addSignal("PLP-W", "PLP-W", "PLP-W", "controlled", 1)
	addSignal("PLP-E", "PLP-E", "PLP-E", "controlled", 1)
	addSignal("SYR-W", "SYR-W", "N4", "controlled", 1)
	addSignal("SYR-DEP", "SYR-DEP", "SYR", "controlled", -1)
	addSignal("ALB-W", "ALB-W", "N2", "controlled", -1)
	Timetable = {
		{ code = "A-101", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 0, dir = 1, dwell = 15, length = 4 },
		{ code = "E-202", kind = "Express", from = "SYR", to = "ALB",
			depart = 60, dir = -1, dwell = 10, length = 5 },
		{ code = "A-103", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 150, dir = 1, dwell = 15, length = 4 },
		{ code = "I-303", kind = "Intercity", from = "SYR", to = "ALB",
			depart = 210, dir = -1, dwell = 8, length = 4 },
		{ code = "A-105", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 300, dir = 1, dwell = 15, length = 4 },
		{ code = "E-206", kind = "Express", from = "ALB", to = "SYR",
			depart = 360, dir = 1, dwell = 10, length = 5 },
	}
	State.arrivalsNeeded = 6
end

local function buildMap3()
	-- Branch Junction: the branch to Branchville leaves the main line
	-- at Junction on a diagonal edge. A branch train travels that edge
	-- continuously; it never jumps to the branch line.
	buildMap2()
	Nodes = {}; Edges = {}; NodeEdges = {}; Signals = {}; Points = {}
	Stations = {}; Routes = {}; Trains = {}; Timetable = {}
	addNode("ALB", 60, 300); addNode("JCT", 500, 300)
	addNode("SYR", 940, 300); addNode("BRV", 700, 480)
	addNode("N2", 280, 300); addNode("N4", 720, 300)
	addEdge("E1", "ALB", "N2", "main")
	addEdge("E2", "N2", "JCT", "main")
	addEdge("E3", "JCT", "N4", "main")
	addEdge("E4", "N4", "SYR", "main")
	addEdge("B1", "JCT", "BRV", "branch", "PT-JCT-01")
	Points["PT-JCT-01"] = { id = "PT-JCT-01", node = "JCT",
		normalEdge = "E3", reverseEdge = "B1", state = "Normal",
		failed = false }
	Stations.ALB = { code = "ALB", name = "Albany", x = 60,
		platforms = { P1 = nil, P2 = nil } }
	Stations.JCT = { code = "JCT", name = "Junction", x = 500,
		platforms = { P1 = nil, P2 = nil } }
	Stations.SYR = { code = "SYR", name = "Syracuse", x = 940,
		platforms = { P1 = nil, P2 = nil } }
	Stations.BRV = { code = "BRV", name = "Branchville", x = 700,
		platforms = { P1 = nil, P2 = nil } }
	addSignal("ALB-DEP", "ALB-DEP", "ALB", "controlled", 1)
	addSignal("JCT-W", "JCT-W", "JCT", "controlled", 1)
	addSignal("JCT-B", "JCT-B", "JCT", "controlled", 1)
	addSignal("SYR-W", "SYR-W", "N4", "controlled", 1)
	addSignal("SYR-DEP", "SYR-DEP", "SYR", "controlled", -1)
	addSignal("ALB-W", "ALB-W", "N2", "controlled", -1)
	Timetable = {
		{ code = "A-101", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 0, dir = 1, dwell = 15, length = 4 },
		{ code = "A-102", kind = "Amtrak", from = "SYR", to = "ALB",
			depart = 60, dir = -1, dwell = 15, length = 4 },
		{ code = "I-303", kind = "Intercity", from = "ALB", to = "BRV",
			depart = 120, dir = 1, dwell = 8, length = 4 },
		{ code = "E-202", kind = "Express", from = "SYR", to = "ALB",
			depart = 180, dir = -1, dwell = 10, length = 5 },
		{ code = "A-105", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 240, dir = 1, dwell = 15, length = 4 },
		{ code = "I-306", kind = "Intercity", from = "BRV", to = "ALB",
			depart = 300, dir = -1, dwell = 8, length = 4 },
		{ code = "A-107", kind = "Amtrak", from = "ALB", to = "SYR",
			depart = 360, dir = 1, dwell = 15, length = 4 },
		{ code = "E-208", kind = "Express", from = "SYR", to = "ALB",
			depart = 420, dir = -1, dwell = 10, length = 5 },
	}
	State.arrivalsNeeded = 8
end

local MAP_BUILDERS = { buildMap1, buildMap2, buildMap3 }
local MAP_NAMES = {
	"Map 1: Albany - Syracuse",
	"Map 2: Pine Loop",
	"Map 3: Branch Junction",
}

-- ---------------------------------------------------------------------------
-- Trains: movement, dwell, service change, penalties
-- ---------------------------------------------------------------------------
local PENALTIES = {
	latePerMinute = 10,
	wrongPlatform = 25,
	wrongDirection = 30,
	missedStop = 50,
	spad = 50,
	collision = 250,
}

local function stationNodeFor(code)
	-- First node whose id matches the station code, else the closest
	-- node to the station's x position.
	if Nodes[code] then return code end
	local best = nil
	local bestD = nil
	for id, node in pairs(Nodes) do
		local d = math.abs(node.x - (Stations[code] and Stations[code].x or 0))
		if bestD == nil or d < bestD then best = id bestD = d end
	end
	return best
end

local function spawnTrain(service)
	local fromNode = stationNodeFor(service.from)
	local train = {
		id = service.code, code = service.code, kind = service.kind,
		from = service.from, to = service.to, dir = service.dir,
		dwellSecs = service.dwell, length = service.length,
		node = fromNode, edge = nil, distAlong = 0, speed = 0,
		maxSpeed = service.kind == "Freight" and 55 or 90,
		state = "dwelling", dwellLeft = service.dwell,
		departAt = service.depart, spawnedAt = State.clock,
		delay = 0, progress = 0, platform = nil,
		passAtDanger = false, serviceIndex = 1,
		bookedPlatform = service.dir == 1 and "P1" or "P2",
		arrived = false, spawned = true,
	}
	Trains[train.id] = train
	log("Train " .. train.code .. " (" .. train.kind .. ") ready at "
		.. train.from .. ", due " .. train.to)
	return train
end

local function nextEdgeFor(train)
	-- At a node, choose the edge that continues toward the destination
	-- and, at a points node, matches the points state. This is the only
	-- place a train changes edge, and it happens at a node, on the
	-- graph, never by changing a line index mid-edge.
	local destNode = stationNodeFor(train.to)
	if train.node == destNode then return nil end
	local path = findPath(train.node, destNode)
	if not path or #path == 0 then return nil end
	local first = Edges[path[1]]
	if first.pointsGroup then
		local pts = Points[first.pointsGroup]
		if pts and pts.state == "Reverse" and first.id ~= pts.reverseEdge then
			-- Points are set the other way: use the reverse edge if it
			-- is on a path to the destination, otherwise stop.
			local alt = findPath(train.node, destNode)
			if alt then return Edges[alt[1]] end
			return nil
		end
	end
	return first
end

local function signalGuardingEdge(edge, dir)
	for _, sig in pairs(Signals) do
		if sig.dir == dir then
			local ahead = edgeAheadOfSignal(sig)
			if ahead and ahead.id == edge.id then return sig end
		end
	end
	return nil
end

local function updateTrain(train, dt)
	if State.failed or State.paused then return end
	if train.state == "done" then return end
	if train.state == "dwelling" then
		train.dwellLeft = train.dwellLeft - dt
		train.speed = 0
		if train.dwellLeft <= 0 and State.clock >= train.departAt then
			train.state = "running"
		end
		return
	end
	if train.state == "waiting" then
		-- Waiting at a red signal: re-check every frame, do not move.
		train.speed = 0
		local edge = nextEdgeFor(train)
		if edge then
			local sig = signalGuardingEdge(edge, train.dir)
			if not sig or aspectOf(sig) ~= "Red" then
				train.state = "running"
			end
		end
		return
	end
	-- Running: pick the next edge at a node, then move along it.
	if not train.edge then
		local edge = nextEdgeFor(train)
		if not edge then
			-- At destination: arrive, score, then auto-change service.
			local station = Stations[train.to]
			if station then
				local plat = train.bookedPlatform
				if station.platforms[plat] and station.platforms[plat] ~= train.id then
					addScore(-PENALTIES.wrongPlatform, train.code
						.. " arrived at the wrong platform at " .. train.to)
				else
					station.platforms[plat] = train.id
					train.platform = plat
				end
			end
			train.state = "done"
			train.arrived = true
			State.arrivals = State.arrivals + 1
			local late = math.max(0, math.floor((State.clock - train.departAt) / 60))
			if late > 0 then
				addScore(-late * PENALTIES.latePerMinute, train.code
					.. " arrived " .. tostring(late) .. " min late at " .. train.to)
			else
				addScore(10, train.code .. " arrived right time at " .. train.to)
			end
			log(train.code .. " arrived at " .. train.to
				.. ". Service over; auto-changing service.")
			-- Auto-change service: reverse and run the return leg as
			-- the next timetable code for that direction, if one exists.
			train.from, train.to = train.to, train.from
			train.dir = -train.dir
			train.bookedPlatform = train.dir == 1 and "P1" or "P2"
			train.state = "dwelling"
			train.dwellLeft = train.dwellSecs
			train.departAt = State.clock + train.dwellSecs
			train.arrived = false
			return
		end
		-- Do not enter an edge occupied by an opposing train: hold.
		if edge.occupiedBy and edge.occupiedBy ~= train.id then
			local other = Trains[edge.occupiedBy]
			if other and other.dir ~= train.dir then
				train.state = "waiting"
				return
			end
		end
		train.edge = edge
		train.distAlong = 0
		edge.occupiedBy = train.id
		-- Leaving a station frees its platform for the next train.
		-- Without this, a departed train would block its platform
		-- forever and later trains could never spawn or arrive there.
		local originStation = Stations[train.from]
		if originStation then
			for plat, holder in pairs(originStation.platforms) do
				if holder == train.id then
					originStation.platforms[plat] = nil
				end
			end
		end
	end
	local edge = train.edge
	local len = edgeLength(edge)
	-- Signal aspect ahead governs target speed: Red = stop at the
	-- node, Yellow = approach slowly, Flashing = medium, Green = full.
	local sig = signalGuardingEdge(edge, train.dir)
	local aspect = sig and aspectOf(sig) or "Green"
	local target = train.maxSpeed
	if aspect == "Red" and not train.passAtDanger then target = 0
	elseif aspect == "Yellow" then target = train.maxSpeed * 0.35
	elseif aspect == "Flashing" then target = train.maxSpeed * 0.6
	elseif train.passAtDanger then target = train.maxSpeed * 0.25 end
	-- Smooth acceleration / braking: ease toward target, brake harder
	-- as the end of the edge (the signal node) gets closer.
	local remaining = len - train.distAlong
	if target == 0 and remaining < 120 then
		target = 0
	end
	if train.speed < target then
		train.speed = math.min(target, train.speed + 30 * dt)
	else
		train.speed = math.max(target, train.speed - 45 * dt)
	end
	if target == 0 and train.speed <= 0.5 and remaining > 1 then
		-- Held at a red signal: stop before the node, do not cross it.
		if remaining < 8 then
			train.state = "waiting"
			train.speed = 0
			return
		end
	end
	local step = train.speed * dt * 0.9
	train.distAlong = train.distAlong + step
	train.progress = clamp(train.distAlong / len * 100, 0, 100)
	if train.distAlong >= len then
		-- Crossed a node: check SPAD, then release the edge behind.
		if sig and aspect == "Red" and not train.passAtDanger then
			addScore(-PENALTIES.spad, train.code .. " passed signal "
				.. sig.code .. " at danger (SPAD)")
			train.state = "waiting"
			train.speed = 0
			train.distAlong = len - 1
			return
		end
		train.passAtDanger = false
		local oldEdge = train.edge
		local nextNode = edgeOtherEnd(edge, train.node)
		train.node = nextNode
		train.edge = nil
		train.distAlong = 0
		if oldEdge.occupiedBy == train.id then
			oldEdge.occupiedBy = nil
			releaseEdgeFromRoutes(oldEdge.id, train)
		end
		-- Collision check: two trains on the same edge, or a train
		-- entering a node another train is dwelling at, is a collision.
		for _, other in pairs(Trains) do
			if other.id ~= train.id and other.edge == oldEdge then
				addScore(-PENALTIES.collision, "Collision between "
					.. train.code .. " and " .. other.code)
				State.failed = true
				log("Shift failed: collision. Reset to try again.")
				return
			end
		end
	end
end

local function reverseTrain(train)
	if train.speed > 0 then
		log(train.code .. ": reverse queued at the next station or "
			.. "signal; a moving train never reverses in place.")
		train.queueReverse = true
		return
	end
	train.dir = -train.dir
	train.from, train.to = train.to, train.from
	train.bookedPlatform = train.dir == 1 and "P1" or "P2"
	train.edge = nil
	train.distAlong = 0
	train.state = "dwelling"
	train.dwellLeft = 5
	log(train.code .. " reversed. New direction: "
		.. (train.dir == 1 and "eastbound" or "westbound"))
end

local function resetService(train)
	train.state = "dwelling"
	train.dwellLeft = train.dwellSecs
	train.edge = nil
	train.distAlong = 0
	train.speed = 0
	log(train.code .. " service reset: driver will stop at the "
		.. "first station again.")
end

local function assignService(train, service)
	-- Assigning a service changes where the train is booked to go.
	-- It never teleports the train: the new destination only takes
	-- effect from the train's current node onward.
	train.to = service.to
	train.from = service.from
	train.dir = service.dir
	train.kind = service.kind
	train.dwellSecs = service.dwell
	train.bookedPlatform = service.dir == 1 and "P1" or "P2"
	log(train.code .. " assigned new service: " .. service.from
		.. " to " .. service.to .. " (" .. service.kind .. ")")
end

-- ---------------------------------------------------------------------------
-- UI: 2D panel, built entirely in code so one LocalScript is enough
-- ---------------------------------------------------------------------------
local gui = nil
local board = nil
local topBar = nil
local selectedBox = nil
local trainListBox = nil
local stationBox = nil
local menuFrame = nil
local trackFrames = {} -- edge id -> Frame
local signalButtons = {} -- signal id -> {button, lamp}
local pointsButtons = {} -- points id -> TextButton
local trainBerths = {} -- train id -> TextButton
local platformButtons = {} -- station code -> {P1, P2}

local ASPECT_COLORS = {
	Red = Color3.fromRGB(220, 40, 40),
	Yellow = Color3.fromRGB(240, 200, 40),
	Flashing = Color3.fromRGB(240, 200, 40),
	Green = Color3.fromRGB(40, 200, 80),
}

local function make(parent, className, props)
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function clearChildren(frame)
	for _, child in ipairs(frame:GetChildren()) do
		child:Destroy()
	end
end

local function buildUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	if gui then gui:Destroy() end
	gui = make(playerGui, "ScreenGui", {
		Name = "SignalMasterTS2", ResetOnSpawn = false,
		IgnoreGuiInset = false, DisplayOrder = 10,
	})
	make(gui, "Frame", { Name = "Backdrop", Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(18, 20, 24), BorderSizePixel = 0 })
	topBar = make(gui, "TextLabel", { Name = "TopBar",
		Size = UDim2.new(1, 0, 0, 44), Position = UDim2.new(0, 0, 0, 0),
		BackgroundColor3 = Color3.fromRGB(30, 33, 40),
		TextColor3 = Color3.fromRGB(240, 240, 240), Font = Enum.Font.Code,
		TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Signal Master  |  Signaller: " .. SIGNALLER_NAME })
	board = make(gui, "Frame", { Name = "Board",
		Size = UDim2.new(0.72, 0, 0.62, 0), Position = UDim2.new(0.01, 0, 0.08, 0),
		BackgroundColor3 = Color3.fromRGB(12, 14, 18), BorderSizePixel = 1,
		BorderColor3 = Color3.fromRGB(90, 95, 105) })

	-- Right panel: train list, selected info, station timetable, log.
	local right = make(gui, "Frame", { Name = "RightPanel",
		Size = UDim2.new(0.25, 0, 0.86, 0), Position = UDim2.new(0.74, 0, 0.08, 0),
		BackgroundColor3 = Color3.fromRGB(26, 29, 36), BorderSizePixel = 1,
		BorderColor3 = Color3.fromRGB(90, 95, 105) })
	make(right, "TextLabel", { Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(240, 200, 40),
		Font = Enum.Font.Code, TextSize = 14, Text = "TRAINS  (click for info, right-click for menu)" })
	trainListBox = make(right, "ScrollingFrame", {
		Size = UDim2.new(1, -8, 0, 150), Position = UDim2.new(0, 4, 0, 28),
		BackgroundColor3 = Color3.fromRGB(18, 20, 24),
		CanvasSize = UDim2.new(0, 0, 0, 300),
		ScrollBarThickness = 6 })
	selectedBox = make(right, "TextLabel", { Name = "Selected",
		Size = UDim2.new(1, -8, 0, 170), Position = UDim2.new(0, 4, 0, 184),
		BackgroundColor3 = Color3.fromRGB(18, 20, 24),
		TextColor3 = Color3.fromRGB(235, 235, 235), Font = Enum.Font.Code,
		TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
		Text = "SELECTED\nClick a train, signal, or platform." })
	stationBox = make(right, "TextLabel", { Name = "Station",
		Size = UDim2.new(1, -8, 0, 130), Position = UDim2.new(0, 4, 0, 360),
		BackgroundColor3 = Color3.fromRGB(18, 20, 24),
		TextColor3 = Color3.fromRGB(235, 235, 235), Font = Enum.Font.Code,
		TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
		Text = "STATION\nClick a platform for its timetable." })
	State.logBox = make(right, "ScrollingFrame", {
		Size = UDim2.new(1, -8, 0, 140), Position = UDim2.new(0, 4, 0, 496),
		BackgroundColor3 = Color3.fromRGB(18, 20, 24),
		CanvasSize = UDim2.new(0, 0, 0, 600), ScrollBarThickness = 6 })
	make(State.logBox, "TextLabel", { Size = UDim2.new(1, 0, 0, 600),
		BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(210, 210, 210),
		Font = Enum.Font.Code, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
		Text = "" })
	-- The log text label is the first child; keep a direct reference.
	State.logText = State.logBox:GetChildren()[1]

	-- Bottom bar: maps, speed, danger, route tools. No login buttons.
	local bottom = make(gui, "Frame", { Name = "BottomBar",
		Size = UDim2.new(1, 0, 0, 56), Position = UDim2.new(0, 0, 1, -56),
		BackgroundColor3 = Color3.fromRGB(30, 33, 40) })
	local function btn(text, x, width, fn)
		local b = make(bottom, "TextButton", {
			Size = UDim2.new(0, width, 0, 40), Position = UDim2.new(0, x, 0, 8),
			BackgroundColor3 = Color3.fromRGB(55, 60, 72),
			TextColor3 = Color3.fromRGB(240, 240, 240), Font = Enum.Font.Code,
			TextSize = 13, Text = text })
		b.MouseButton1Click:Connect(fn)
		return b
	end
	btn("Map 1", 8, 70, function() loadMap(1) end)
	btn("Map 2", 84, 70, function() loadMap(2) end)
	btn("Map 3", 160, 70, function() loadMap(3) end)
	btn("Pause", 240, 70, function()
		State.paused = not State.paused
		log(State.paused and "Paused." or "Resumed.")
	end)
	btn("1x", 318, 44, function() State.speed = 1 end)
	btn("2x", 366, 44, function() State.speed = 2 end)
	btn("4x", 414, 44, function() State.speed = 4 end)
	btn("All to danger", 468, 120, function()
		for _, route in ipairs({ table.unpack(Routes) }) do
			cancelRoute(route, "all to danger")
		end
		State.selectedSignal = nil
		log("All signals to danger. All routes cancelled.")
	end)
	btn("Cancel route", 596, 110, function()
		if State.selectedRoute then
			cancelRoute(State.selectedRoute, "cancel button")
			State.selectedRoute = nil
		elseif State.selectedSignal then
			local route = signalRouteFor(State.selectedSignal)
			if route then cancelRoute(route, "cancel button") end
		else
			log("No route selected to cancel. Click a route's first signal first.")
		end
	end)
	btn("Pass at danger", 714, 130, function()
		local train = State.selectedTrain
		if train and train.state == "waiting" then
			train.passAtDanger = true
			train.state = "running"
			log(train.code .. ": Pass at danger authorised to the next "
				.. "signal, on sight, slowly. This is logged.")
		else
			log("Pass at danger is only for a train held at a red signal.")
		end
	end)
	btn("Call-on: OFF", 852, 120, function()
		State.callOn = not State.callOn
		log("Call-on is now " .. (State.callOn and "ON" or "OFF")
			.. ". Call-on lets a train enter an occupied section slowly, on sight.")
	end)

	menuFrame = make(gui, "Frame", { Name = "TrainMenu",
		Size = UDim2.new(0, 260, 0, 220), Position = UDim2.new(0.4, 0, 0.35, 0),
		BackgroundColor3 = Color3.fromRGB(26, 29, 36), BorderSizePixel = 1,
		BorderColor3 = Color3.fromRGB(240, 200, 40), Visible = false })
end

local function renderBoard()
	if not board then return end
	clearChildren(board)
	trackFrames = {}; signalButtons = {}; pointsButtons = {}
	platformButtons = {}; trainBerths = {}
	-- Track segments: one Frame per graph edge, so a section turns red
	-- only on the exact edge a train occupies, and a routed edge turns
	-- white only on the exact edges of that route's graph path.
	for id, edge in pairs(Edges) do
		local a = Nodes[edge.from]
		local b = Nodes[edge.to]
		local mx = (a.x + b.x) / 2 / 1000
		local my = (a.y + b.y) / 2 / 600
		local len = dist(a.x, a.y, b.x, b.y) / 1000
		local angle = math.deg(math.atan2(b.y - a.y, b.x - a.x))
		local seg = make(board, "Frame", {
			Name = "Track_" .. id,
			Size = UDim2.new(len, 0, 0, 3),
			Position = UDim2.new(mx, 0, my, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = angle,
			BackgroundColor3 = Color3.fromRGB(120, 125, 135),
			BorderSizePixel = 0 })
		trackFrames[id] = seg
	end
	-- Stations: nameboard + two platform buttons (P1 / P2).
	for code, station in pairs(Stations) do
		local x = station.x / 1000
		make(board, "TextLabel", {
			Size = UDim2.new(0, 120, 0, 22), Position = UDim2.new(x, -60, 0.32, 0),
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundColor3 = Color3.fromRGB(20, 22, 28),
			TextColor3 = Color3.fromRGB(240, 240, 240), Font = Enum.Font.Code,
			TextSize = 13, Text = station.name .. " (" .. code .. ")" })
		platformButtons[code] = {}
		for _, plat in ipairs({ "P1", "P2" }) do
			local offY = plat == "P1" and -34 or 34
			local pb = make(board, "TextButton", {
				Size = UDim2.new(0, 90, 0, 20),
				Position = UDim2.new(x, -45, 0.5, offY),
				BackgroundColor3 = Color3.fromRGB(45, 50, 62),
				TextColor3 = Color3.fromRGB(235, 235, 235),
				Font = Enum.Font.Code, TextSize = 12,
				Text = code .. " " .. plat .. ": Free" })
			pb.MouseButton1Click:Connect(function()
				showStationInfo(code)
			end)
			platformButtons[code][plat] = pb
		end
	end
	-- Signals: round = controlled, square = automatic.
	for id, sig in pairs(Signals) do
		local btn = make(board, "TextButton", {
			Name = "Sig_" .. id,
			Size = UDim2.new(0, 30, 0, 30),
			Position = UDim2.new(sig.x / 1000, -15, sig.y / 600, -15),
			BackgroundColor3 = Color3.fromRGB(20, 22, 28),
			BorderColor3 = Color3.fromRGB(200, 200, 200),
			TextColor3 = Color3.fromRGB(235, 235, 235),
			Font = Enum.Font.Code, TextSize = 9, Text = sig.code })
		if sig.kind == "controlled" then
			make(btn, "UICorner", { CornerRadius = UDim.new(1, 0) })
		end
		-- The lamp sits above the button so a passing train berth never
		-- hides it: signals render on a higher layer than trains.
		local lamp = make(board, "Frame", {
			Size = UDim2.new(0, 12, 0, 12),
			Position = UDim2.new(sig.x / 1000, -6, sig.y / 600, -32),
			BackgroundColor3 = Color3.fromRGB(220, 40, 40),
			BorderSizePixel = 1, BorderColor3 = Color3.fromRGB(0, 0, 0),
			ZIndex = 10 })
		signalButtons[id] = { button = btn, lamp = lamp }
		btn.MouseButton1Click:Connect(function()
			onSignalClick(sig)
		end)
		btn.MouseButton2Click:Connect(function()
			local route = signalRouteFor(sig)
			if route then
				cancelRoute(route, "right-click on first signal")
			else
				log(sig.code .. " has no route to cancel.")
			end
		end)
	end
	-- Points buttons: Normal (white) / Reverse (yellow) / Failed (purple).
	for id, pts in pairs(Points) do
		local node = Nodes[pts.node]
		local pb = make(board, "TextButton", {
			Size = UDim2.new(0, 34, 0, 22),
			Position = UDim2.new(node.x / 1000, -17, node.y / 600, 26),
			BackgroundColor3 = Color3.fromRGB(45, 50, 62),
			TextColor3 = Color3.fromRGB(235, 235, 235),
			Font = Enum.Font.Code, TextSize = 11, Text = id })
		pb.MouseButton1Click:Connect(function()
			if pts.failed then
				log(id .. " has failed (flashing purple). Leave it until it recovers.")
				return
			end
			-- Hand-setting points is allowed only when no train is on
			-- them and no locked route uses them; normal routes swing
			-- points automatically, so this is a manual override.
			for _, route in ipairs(Routes) do
				for _, e in ipairs(route.edges) do
					if Edges[e].pointsGroup == id then
						log(id .. " is locked by a set route. Cancel that route first.")
						return
					end
				end
			end
			pts.state = pts.state == "Normal" and "Reverse" or "Normal"
			log(id .. " set by hand to " .. pts.state
				.. ". The highlighted path follows the points.")
		end)
		pointsButtons[id] = pb
	end
	-- Train berths: one black berth per train, on the line, above the
	-- track but below signal lamps (signals stay visible and clickable).
	for id, train in pairs(Trains) do
		local berth = make(board, "TextButton", {
			Size = UDim2.new(0, 64, 0, 22),
			BackgroundColor3 = Color3.fromRGB(0, 0, 0),
			BorderColor3 = Color3.fromRGB(240, 200, 40),
			TextColor3 = Color3.fromRGB(240, 240, 240),
			Font = Enum.Font.Code, TextSize = 12, Text = train.code,
			ZIndex = 8 })
		berth.MouseButton1Click:Connect(function()
			showTrainInfo(train)
		end)
		berth.MouseButton2Click:Connect(function()
			showTrainMenu(train)
		end)
		trainBerths[id] = berth
	end
end

function showTrainInfo(train)
	State.selectedTrain = train
	local nextStop = train.to
	local speed = math.floor(train.speed + 0.5)
	selectedBox.Text = "TRAIN " .. train.code .. "\n"
		.. "Type: " .. train.kind .. "  Length: " .. tostring(train.length) .. " cars\n"
		.. "From: " .. train.from .. "  To: " .. train.to .. "\n"
		.. "Route: " .. train.from .. " -> " .. train.to .. "\n"
		.. "Destination: " .. train.to .. "\n"
		.. "Next stop: " .. nextStop .. "\n"
		.. "Speed: " .. tostring(speed) .. "  Progress: "
		.. tostring(math.floor(train.progress + 0.5)) .. "%\n"
		.. "Platform: " .. (train.platform or "not assigned yet") .. "\n"
		.. "State: " .. train.state .. "\n"
		.. "Right-click the berth for Assign / Reset / Reverse."
	log("Train info shown for " .. train.code .. ".")
end

function showStationInfo(code)
	State.selectedStation = code
	local lines = { "STATION " .. code .. " -- timetable" }
	for _, svc in ipairs(Timetable) do
		if svc.from == code or svc.to == code then
			table.insert(lines, svc.code .. "  " .. svc.from .. " -> "
				.. svc.to .. "  dep " .. fmtTime(9 * 3600 + svc.depart)
				.. "  (" .. svc.kind .. ")")
		end
	end
	stationBox.Text = table.concat(lines, "\n")
	log("Station timetable shown for " .. code .. ".")
end

function showTrainMenu(train)
	State.selectedTrain = train
	clearChildren(menuFrame)
	menuFrame.Visible = true
	make(menuFrame, "TextLabel", { Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(240, 200, 40),
		Font = Enum.Font.Code, TextSize = 14,
		Text = "Train menu: " .. train.code })
	local y = 30
	local function menuBtn(text, fn)
		local b = make(menuFrame, "TextButton", {
			Size = UDim2.new(1, -16, 0, 28), Position = UDim2.new(0, 8, 0, y),
			BackgroundColor3 = Color3.fromRGB(55, 60, 72),
			TextColor3 = Color3.fromRGB(240, 240, 240),
			Font = Enum.Font.Code, TextSize = 13, Text = text })
		b.MouseButton1Click:Connect(fn)
		y = y + 32
	end
	menuBtn("Assign new service", function()
		-- Assign the first timetable service not already running.
		for _, svc in ipairs(Timetable) do
			if not Trains[svc.code] then
				assignService(train, svc)
				menuFrame.Visible = false
				showTrainInfo(train)
				return
			end
		end
		log("No free service left to assign to " .. train.code .. ".")
	end)
	menuBtn("Reset service", function()
		resetService(train)
		menuFrame.Visible = false
	end)
	menuBtn("Reverse train", function()
		reverseTrain(train)
		menuFrame.Visible = false
	end)
	menuBtn("Close menu", function()
		menuFrame.Visible = false
	end)
end

function onSignalClick(sig)
	if State.failed then return end
	if not State.selectedSignal then
		if sig.kind ~= "controlled" then
			log(sig.code .. " is an automatic signal. It clears by "
				.. "itself. Routes start only from controlled (round) "
				.. "signals, then run to the next automatic, then again "
				.. "from the next manual signal.")
			return
		end
		State.selectedSignal = sig
		State.selectedRoute = signalRouteFor(sig)
		if State.selectedRoute then
			selectedBox.Text = sig.code .. " has a route set to "
				.. State.selectedRoute.exitCode .. ".\n"
				.. "Click Cancel route, or right-click this signal, "
				.. "to cancel it. Call-on: "
				.. (State.callOn and "ON" or "OFF") .. "."
		else
			selectedBox.Text = "Entry selected: " .. sig.code .. ".\n"
				.. "Now click the exit signal. A route runs to the "
				.. "next signal only and never crosses a manual signal."
		end
		log("Entry selected: " .. sig.code .. ". Click an exit signal.")
		return
	end
	local entry = State.selectedSignal
	State.selectedSignal = nil
	if entry.id == sig.id then
		log("Entry cleared. Click a different signal as the exit.")
		return
	end
	local persistent = false
	pcall(function()
		persistent = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end)
	local ok, msg = trySetRoute(entry, sig, persistent)
	if ok then
		State.selectedRoute = signalRouteFor(entry)
	else
		log(msg)
		selectedBox.Text = msg
	end
end

local function refreshUI()
	if not board then return end
	-- Track colours: routed = bold white, occupied = red, else grey.
	-- Occupancy is per edge, so only the edge a train is on turns red.
	local routed = {}
	for _, route in ipairs(Routes) do
		for _, e in ipairs(route.edges) do routed[e] = true end
	end
	for id, frame in pairs(trackFrames) do
		local edge = Edges[id]
		if edge and edge.occupiedBy then
			frame.BackgroundColor3 = Color3.fromRGB(220, 40, 40)
		elseif routed[id] then
			frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		else
			frame.BackgroundColor3 = Color3.fromRGB(120, 125, 135)
		end
	end
	-- Signal lamps, recomputed live every frame.
	for id, pair in pairs(signalButtons) do
		local sig = Signals[id]
		if sig then
			local aspect = aspectOf(sig)
			pair.lamp.BackgroundColor3 = ASPECT_COLORS[aspect]
			-- Flashing Yellow: blink by game clock (0.5 s on / off).
			if aspect == "Flashing" then
				local on = math.floor(State.clock * 2) % 2 == 0
				pair.lamp.BackgroundTransparency = on and 0 or 0.7
			else
				pair.lamp.BackgroundTransparency = 0
			end
			-- Persistent route marker: small white square by first signal.
			if sig.route and sig.route.persistent then
				pair.button.BorderColor3 = Color3.fromRGB(255, 255, 255)
			elseif State.selectedSignal and State.selectedSignal.id == id then
				pair.button.BorderColor3 = Color3.fromRGB(240, 200, 40)
			else
				pair.button.BorderColor3 = Color3.fromRGB(200, 200, 200)
			end
		end
	end
	-- Points colours: Normal white, Reverse yellow, Failed purple.
	for id, btn in pairs(pointsButtons) do
		local pts = Points[id]
		if pts then
			if pts.failed then
				btn.BackgroundColor3 = Color3.fromRGB(160, 60, 220)
			elseif pts.state == "Reverse" then
				btn.BackgroundColor3 = Color3.fromRGB(240, 200, 40)
				btn.TextColor3 = Color3.fromRGB(0, 0, 0)
			else
				btn.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
				btn.TextColor3 = Color3.fromRGB(0, 0, 0)
			end
		end
	end
	-- Platform lights: Free / Occupied / Reserved, per platform only.
	for code, station in pairs(Stations) do
		for plat, holder in pairs(station.platforms) do
			local btn = platformButtons[code] and platformButtons[code][plat]
			if btn then
				if holder then
					btn.Text = code .. " " .. plat .. ": Occupied (" .. holder .. ")"
					btn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
				else
					btn.Text = code .. " " .. plat .. ": Free"
					btn.BackgroundColor3 = Color3.fromRGB(45, 50, 62)
				end
			end
		end
	end
	-- Train berths: position along their current edge, interpolated.
	for id, train in pairs(Trains) do
		local berth = trainBerths[id]
		if not berth then
			-- A train spawned after the board was rendered: add its berth.
			berth = make(board, "TextButton", {
				Size = UDim2.new(0, 64, 0, 22),
				BackgroundColor3 = Color3.fromRGB(0, 0, 0),
				BorderColor3 = Color3.fromRGB(240, 200, 40),
				TextColor3 = Color3.fromRGB(240, 240, 240),
				Font = Enum.Font.Code, TextSize = 12, Text = train.code,
				ZIndex = 8 })
			berth.MouseButton1Click:Connect(function() showTrainInfo(train) end)
			berth.MouseButton2Click:Connect(function() showTrainMenu(train) end)
			trainBerths[id] = berth
		end
		local x, y = 0, 300
		if train.edge then
			local edge = train.edge
			local a = Nodes[edge.from]
			local b = Nodes[edge.to]
			local len = edgeLength(edge)
			local t = len > 0 and clamp(train.distAlong / len, 0, 1) or 0
			-- If the train travels from B to A, interpolate backwards.
			if train.node == edge.to then
				x = b.x + (a.x - b.x) * t
				y = b.y + (a.y - b.y) * t
			else
				x = a.x + (b.x - a.x) * t
				y = a.y + (b.y - a.y) * t
			end
		else
			local node = Nodes[train.node]
			if node then x, y = node.x, node.y end
		end
		berth.Position = UDim2.new(x / 1000, -32, y / 600, -34)
		berth.Text = train.code
		if State.selectedTrain == train then
			berth.BorderColor3 = Color3.fromRGB(255, 255, 255)
		else
			berth.BorderColor3 = Color3.fromRGB(240, 200, 40)
		end
	end
	-- Train list rows.
	if trainListBox then
		clearChildren(trainListBox)
		local y = 0
		for _, train in pairs(Trains) do
			local row = make(trainListBox, "TextButton", {
				Size = UDim2.new(1, -8, 0, 26), Position = UDim2.new(0, 4, 0, y),
				BackgroundColor3 = Color3.fromRGB(35, 38, 48),
				TextColor3 = Color3.fromRGB(235, 235, 235),
				Font = Enum.Font.Code, TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = train.code .. "  " .. train.from .. "->" .. train.to
					.. "  " .. train.state })
			row.MouseButton1Click:Connect(function() showTrainInfo(train) end)
			row.MouseButton2Click:Connect(function() showTrainMenu(train) end)
			y = y + 30
		end
	end
	if topBar then
		topBar.Text = MAP_NAMES[State.mapIndex] .. "  |  Signaller: "
			.. SIGNALLER_NAME .. "  |  Clock " .. fmtTime(State.clock)
			.. "  |  Score " .. tostring(State.score)
			.. "  |  Arrivals " .. tostring(State.arrivals) .. "/"
			.. tostring(State.arrivalsNeeded)
			.. "  |  Speed " .. tostring(State.speed) .. "x"
			.. (State.failed and "  |  SHIFT FAILED" or "")
	end
	if State.selectedTrain then
		-- Keep the selected train's info live, not static.
		local t = State.selectedTrain
		if t.state ~= "done" then
			showTrainInfo(t)
		end
	end
	if State.logText then
		State.logText.Text = table.concat(State.logLines, "\n")
	end
end

function loadMap(index)
	State.mapIndex = index
	State.clock = 9 * 3600
	State.score = 0
	State.arrivals = 0
	State.failed = false
	State.won = false
	State.selectedSignal = nil
	State.selectedTrain = nil
	State.selectedRoute = nil
	State.callOn = false
	State.logLines = {}
	MAP_BUILDERS[index]()
	log("Loaded " .. MAP_NAMES[index] .. ". No login. Set a route "
		.. "signal to signal: click a round signal, then the next signal.")
	renderBoard()
	refreshUI()
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local function onHeartbeat(dt)
	if State.paused then
		refreshUI()
		return
	end
	local scaled = dt * State.speed
	State.clock = State.clock + scaled
	-- Spawn timetable services at their departure time, if not spawned.
	for _, svc in ipairs(Timetable) do
		if not Trains[svc.code] and State.clock >= 9 * 3600 + svc.depart then
			-- Spawn only if the origin platform is free; otherwise wait
			-- and try again next frame (never spawn into an occupied
			-- platform, never stack two trains on one platform).
			local station = Stations[svc.from]
			local plat = svc.dir == 1 and "P1" or "P2"
			if not station or not station.platforms[plat] then
				spawnTrain(svc)
				if station then station.platforms[plat] = svc.code end
				renderBoard()
			end
		end
	end
	for _, train in pairs(Trains) do
		updateTrain(train, scaled)
	end
	-- Win check: arrivals reached, and no shift failure. The won flag
	-- stops the line repeating; arrivals are NOT reset, so the top
	-- bar still shows the real final count after the win.
	if State.arrivals >= State.arrivalsNeeded and not State.failed
		and not State.won then
		State.won = true
		log("Shift complete: " .. tostring(State.arrivals) .. " arrivals, "
			.. "score " .. tostring(State.score) .. ". Well signalled.")
	end
	refreshUI()
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------
buildUI()
if BGM_SOUND_ID ~= "" then
	-- Only runs if the user pastes a real uploaded audio ID above.
	local sound = Instance.new("Sound")
	sound.SoundId = BGM_SOUND_ID
	sound.Looped = true
	sound.Volume = 0.3
	sound.Parent = gui
	sound:Play()
end
loadMap(1)
RunService.Heartbeat:Connect(onHeartbeat)
log("Signal Master (TS2-style, Roblox panel) started. Map 1 loaded.")
