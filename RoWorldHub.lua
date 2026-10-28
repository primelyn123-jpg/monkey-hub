--[[
	RoWorld Hub - automation for RoWorld [World PvP] (the Airfront / OpenFront-style map game).

	Troops, gold and combat are computed by the server; the client only mirrors them and sends validated
	intents (attack, build, ally, retreat). So this hub does not fake numbers: it decides which intents to
	send and when, using the game's own shared rules (ReplicatedStorage.Airfront.Core.Rules).
]]

-- Services.
local playersService = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local virtualUser = game:GetService("VirtualUser")

-- Constants.
local CONFIG = {
	RAW_BASE = "https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/",
	UI_FILE = "ui.lua",
	DECISION_INTERVAL = 1.5,
	SCAN_INTERVAL = 3,
	SCAN_YIELD_EVERY = 160000,
	CONTACT_SAMPLES = 8,
	WINDOW_RADIUS = 16,
	BUILDING_RADIUS = 70,
	INTERIOR_STRIDE = 97,
	INTERIOR_MAX = 160,
	BUILD_RETRY_S = 90,
	ALLY_REQUEST_RETRY_S = 90,
	TERRAIN_MAG = 80,
	-- Minimum seconds between sends of the same kind (everything goes through Net.send).
	REMOTE_GAPS = { attack = 0.7, build = 5, ally = 1.2, retreat = 2 },
	-- Tile-equivalent value of a structure when judging an area (kind id -> weight).
	STRUCT_VALUE = { [0] = 1.0, [1] = 0.6, [2] = 0.6, [3] = 0.2, [4] = 0.3, [5] = 0.5 },
	KIND_CITY = 0,
	KIND_DEFENSE = 3,
}

-- State.
local localPlayer = playersService.LocalPlayer
local RoWorldHub = { running = false, errors = 0 }
local UI = nil
local Window = nil
local Game = {}
local Net = { last = {}, counts = {}, total = 0, dry = 0 }
local Intel = { label = nil, lines = "", lastBuild = {}, lastAlly = {}, outgoing = {}, scan = nil, scanning = false }
local connections = {}

---@param err any
local function onError(err)
	warn("[RoWorldHub] " .. tostring(err) .. "\n" .. debug.traceback())
end

-- Live value of a UI flag (never cached, so toggles apply on the next tick).
---@param name string
---@return any
local function flag(name)
	local entry = UI and UI.Flags[name]
	return entry and entry.Value
end

---@param value number
---@return string
local function formatNumber(value)
	local sign = value < 0 and "-" or ""
	local digits = string.format("%.0f", math.abs(value))
	return sign .. (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- ---------------------------------------------------------------------------
-- Game access
-- ---------------------------------------------------------------------------

-- Finds the client Session object (it owns the live GameState) through the GC.
---@return table?
local function findSession()
	if type(getgc) ~= "function" then
		return nil
	end
	local ok, objects = pcall(getgc, true)
	if not ok then
		return nil
	end
	for _, candidate in ipairs(objects) do
		if type(candidate) == "table" and rawget(candidate, "mode") ~= nil and rawget(candidate, "env") ~= nil and rawget(candidate, "_queued") ~= nil then
			return candidate
		end
	end
	return nil
end

local function loadGame()
	local airfront = replicatedStorage:WaitForChild("Airfront", 15)
	assert(airfront, "this is not RoWorld (no Airfront module)")
	Game.protocol = require(airfront:WaitForChild("Net", 15):WaitForChild("Protocol", 15))
	Game.defs = require(airfront:WaitForChild("Core", 15):WaitForChild("Defs", 15))
	Game.toServer = replicatedStorage:WaitForChild("AirfrontNet"):WaitForChild("ToServer")
	assert(type(Game.protocol.encode_intent) == "function", "Protocol.encode_intent missing (game updated?)")
end

-- Current GameState, or nil while not in a running match.
---@return table?, number?, table?
local function getState()
	local session = Game.session
	if session == nil or session.state == nil then
		if os.clock() - (Game.sessionAt or -10) < 3 then
			return nil
		end
		Game.sessionAt = os.clock()
		Game.session = findSession()
		session = Game.session
	end
	local state = session and session.state
	if state == nil or not state.loaded or state.local_owner == 0 then
		return nil
	end
	local info = state.owners[state.local_owner]
	if info == nil or not info.alive or not info.spawned or state.phase ~= Game.defs.PHASE_PLAYING then
		return nil
	end
	return state, state.local_owner, info
end

-- The single exit for every intent: per-kind gap, counters, optional dry run (log only).
---@param key string
---@param group string
---@param intent table
---@return boolean
function Net.send(key, group, intent)
	local now = os.clock()
	if now - (Net.last[key] or -math.huge) < CONFIG.REMOTE_GAPS[group] then
		return false
	end
	Net.last[key] = now

	if flag("dryRun") then
		Net.dry += 1
		print("[RoWorldHub] dry run:", intent.type, intent.tile or intent.target or intent.attack_id, intent.ratio and string.format("ratio %.2f", intent.ratio) or "", intent.kind or "")
		return true
	end

	local encoded = Game.protocol.encode_intent(intent)
	if encoded == nil then
		return false
	end
	Game.toServer:FireServer(Game.protocol.OP.INTENT, encoded)
	Net.counts[group] = (Net.counts[group] or 0) + 1
	Net.total += 1
	return true
end

-- ---------------------------------------------------------------------------
-- Map scan: who touches my border, where, and safe interior tiles for building
-- ---------------------------------------------------------------------------

-- One chunked pass over the tile grid (yields so it never hitches a frame).
---@return table
local function scanBorders(state, me)
	local ownerBuffer, land = state.owner, state.map.land
	local width, total = state.W, state.N
	local readi32, readu8 = buffer.readi32, buffer.readu8
	local contacts, interior = {}, {}
	local random = Random.new()
	local ownTiles = 0

	local function touch(ownerId, theirTile, myTile)
		local contact = contacts[ownerId]
		if contact == nil then
			contact = { owner = ownerId, count = 0, theirs = {}, mine = {} }
			contacts[ownerId] = contact
		end
		contact.count += 1
		if #contact.theirs < CONFIG.CONTACT_SAMPLES then
			table.insert(contact.theirs, theirTile)
			table.insert(contact.mine, myTile)
		else
			local slot = random:NextInteger(1, contact.count)
			if slot <= CONFIG.CONTACT_SAMPLES then
				contact.theirs[slot] = theirTile
				contact.mine[slot] = myTile
			end
		end
	end

	for tile = 0, total - 1 do
		if tile % CONFIG.SCAN_YIELD_EVERY == 0 and tile > 0 then
			task.wait()
			if not RoWorldHub.running then
				return { contacts = contacts, interior = interior, tiles = ownTiles, at = os.clock() }
			end
		end

		if readi32(ownerBuffer, tile * 4) == me then
			ownTiles += 1
			local column = tile % width
			local border = false

			local function check(neighbor)
				if readu8(land, neighbor) ~= 0 then
					local other = readi32(ownerBuffer, neighbor * 4)
					if other ~= me then
						border = true
						touch(other, neighbor, tile)
					end
				end
			end

			if column > 0 then
				check(tile - 1)
			end
			if column < width - 1 then
				check(tile + 1)
			end
			if tile >= width then
				check(tile - width)
			end
			if tile < total - width then
				check(tile + width)
			end

			if not border and tile % CONFIG.INTERIOR_STRIDE == 0 and #interior < CONFIG.INTERIOR_MAX then
				table.insert(interior, tile)
			end
		end
	end

	return { contacts = contacts, interior = interior, tiles = ownTiles, at = os.clock() }
end

local function refreshScan(state, me)
	if Intel.scanning then
		return
	end
	local scan = Intel.scan
	if scan ~= nil and os.clock() - scan.at < CONFIG.SCAN_INTERVAL then
		return
	end

	Intel.scanning = true
	task.spawn(function()
		local ok, result = xpcall(scanBorders, onError, state, me)
		Intel.scanning = false
		if ok and result ~= nil then
			Intel.scan = result
		end
	end)
end

---@return number, number
local function tileXY(tile)
	local width = Game.session.state.W
	return tile % width, tile // width
end

-- Counts tiles owned by `ownerId` (0 = neutral land) in a square window around a tile.
---@return number
local function countWindow(state, centre, ownerId)
	local width, height = state.W, state.H
	local readi32, readu8 = buffer.readi32, buffer.readu8
	local land, ownerBuffer = state.map.land, state.owner
	local cx, cy = centre % width, centre // width
	local radius = CONFIG.WINDOW_RADIUS
	local count = 0
	for y = math.max(cy - radius, 0), math.min(cy + radius, height - 1) do
		local base = y * width
		for x = math.max(cx - radius, 0), math.min(cx + radius, width - 1) do
			local tile = base + x
			if readu8(land, tile) ~= 0 and readi32(ownerBuffer, tile * 4) == ownerId then
				count += 1
			end
		end
	end
	return count
end

-- Structure value near a tile (tile-equivalents) and defense-post cover for that owner.
---@return number, number
local function structuresNear(state, centre, ownerId)
	local cx, cy = tileXY(centre)
	local radius2 = CONFIG.BUILDING_RADIUS * CONFIG.BUILDING_RADIUS
	local value, posts = 0, 0
	for _, structure in pairs(state.structures) do
		if structure.owner == ownerId then
			local sx, sy = tileXY(structure.tile)
			if (sx - cx) ^ 2 + (sy - cy) ^ 2 <= radius2 then
				value += (CONFIG.STRUCT_VALUE[structure.kind] or 0.3) * structure.level
				if structure.kind == CONFIG.KIND_DEFENSE then
					posts += 1
				end
			end
		end
	end
	return value, posts
end

-- ---------------------------------------------------------------------------
-- Combat model (the game's own formulas, from SimAttacks._process_attack)
-- ---------------------------------------------------------------------------

-- Troops lost per conquered tile when attacking `target` (nil = neutral land) with `committed` troops.
---@return number
local function lossPerTile(state, info, target, committed, postCover)
	local rules = state.rules
	local kArea = rules.K_AREA
	local ok, result = pcall(function()
		if target == nil then
			return kArea * CONFIG.TERRAIN_MAG * rules.neutral_loss_per_mag(info.kind)
		end

		local defenderArea = math.max(target.tiles * kArea, 1)
		local attackerArea = info.tiles * kArea
		local density = target.troops / defenderArea
		local pressure = math.clamp(target.troops / math.max(committed, 1), 0.6, 2)

		local multiplier = 1
		if state:is_traitor(target.id) then
			multiplier *= rules.TRAITOR_DEFENSE_DEBUFF
		end
		if target.kind == Game.defs.KIND_TRIBE and info.kind ~= Game.defs.KIND_TRIBE then
			multiplier *= rules.BOT_DEFENDER_LOSS_MULT
		end

		local base = rules.ATTACKER_LOSS_BASE
			* rules.large_territory_bonus(attackerArea, rules.LARGE_ATTACKER_DEPTH)
			* rules.large_territory_bonus(defenderArea, rules.LARGE_DEFENDER_DEPTH)
		local perMag = multiplier * pressure * (base + rules.ATTACKER_LOSS_PER_DENSITY * density)
		local cover = 1 + postCover * (rules.DEFENSE_POST_MAG - 1)
		return kArea * CONFIG.TERRAIN_MAG * perMag * cover
	end)
	if ok and type(result) == "number" and result > 0 then
		return result
	end
	return math.huge
end

-- Evaluates attacking an owner (0 = neutral) from one of its contact samples. Returns a candidate or nil.
---@return table?
local function evaluateContact(state, me, info, contact, available, ratioCap)
	local targetId = contact.owner
	local target = targetId ~= 0 and state.owners[targetId] or nil
	if targetId ~= 0 and (target == nil or not target.alive or state:are_allies(me, targetId)) then
		return nil
	end

	-- Best sample = the one with the most land + structures around it.
	local best
	for index, tile in ipairs(contact.theirs) do
		if index > 3 then
			break
		end
		local landTiles = countWindow(state, tile, targetId)
		local structureValue, posts = 0, 0
		if targetId ~= 0 then
			structureValue, posts = structuresNear(state, tile, targetId)
		end
		local score = landTiles + structureValue * (flag("buildingWeight") or 25)
		if best == nil or score > best.score then
			best = { tile = tile, land = landTiles, structures = structureValue, posts = posts, score = score }
		end
	end
	if best == nil or best.land == 0 then
		return nil
	end

	local postCover = math.min(1, best.posts * 0.5)
	local maxCommit = available * ratioCap
	if maxCommit < 1 then
		return nil
	end

	-- Commit only what the prize justifies (land + buildings in the area), capped by what we may spend.
	local cost = lossPerTile(state, info, target, maxCommit, postCover)
	if cost == math.huge then
		return nil
	end
	local prize = best.land + best.structures * (flag("buildingWeight") or 25)
	local commit = math.min(maxCommit, prize * cost * 1.25)
	cost = lossPerTile(state, info, target, commit, postCover)
	local tiles = math.min(commit / cost, best.land)

	return {
		owner = targetId,
		target = target,
		tile = best.tile,
		myTile = contact.mine[1],
		commit = commit,
		tiles = tiles,
		land = best.land,
		structures = best.structures,
		posts = best.posts,
		efficiency = (tiles + best.structures * (flag("buildingWeight") or 25)) / math.max(commit, 1),
		cost = cost,
	}
end

-- ---------------------------------------------------------------------------
-- Decisions
-- ---------------------------------------------------------------------------

-- Incoming attacks on me, my outgoing attacks, and how many troops the threat commits.
---@return table, table, number
local function readAttacks(state, me)
	local incoming, outgoing, threat = {}, {}, 0
	for _, attack in pairs(state.attacks) do
		if attack.target == me and not attack.retreating and attack.troops > 1 then
			table.insert(incoming, attack)
			threat += attack.troops
		elseif attack.attacker == me then
			table.insert(outgoing, attack)
		end
	end
	return incoming, outgoing, threat
end

-- Pulls outgoing attacks back when I'm under threat with too few troops at home, or when one has stalled.
local function manageRetreats(info, outgoing, threatened, reserve)
	local tilesNow = info.tiles
	local seen = {}
	for _, attack in ipairs(outgoing) do
		seen[attack.aid] = true
		local record = Intel.outgoing[attack.aid]
		if record == nil then
			record = { troops = attack.troops, tiles = tilesNow, at = os.clock() }
			Intel.outgoing[attack.aid] = record
		end

		if not attack.retreating then
			local stalled = os.clock() - record.at > 10 and attack.troops < record.troops * 0.6 and tilesNow - record.tiles < 5
			local pullBack = threatened and info.troops < reserve
			if (stalled or pullBack) and flag("autoRetreat") then
				Net.send("retreat" .. attack.aid, "retreat", { type = "retreat", attack_id = attack.aid })
			end
		end
	end
	for aid in pairs(Intel.outgoing) do
		if not seen[aid] then
			Intel.outgoing[aid] = nil
		end
	end
end

local function structureCount(state, me, kind)
	local count = 0
	for _, structure in pairs(state.structures) do
		if structure.owner == me and structure.kind == kind then
			count += 1
		end
	end
	return count
end

-- Builds a defense post on the contested border, or a city on safe interior land.
local function manageBuilding(state, me, info, threatened, incoming, scan)
	if not flag("autoBuild") or scan == nil then
		return
	end
	local rules = state.rules
	local goldReserve = flag("goldReserve") or 0

	-- Defense post where an attacker touches me.
	if threatened and flag("buildDefense") then
		local cost = rules.build_cost_kind(CONFIG.KIND_DEFENSE, structureCount(state, me, CONFIG.KIND_DEFENSE))
		if info.gold >= cost + goldReserve then
			for _, attack in ipairs(incoming) do
				local contact = scan.contacts[attack.attacker]
				local tile = contact and contact.mine[1]
				if tile and os.clock() - (Intel.lastBuild[tile] or -1000) > CONFIG.BUILD_RETRY_S then
					Intel.lastBuild[tile] = os.clock()
					Net.send("build", "build", { type = "build", kind = "defense", tile = tile })
					return
				end
			end
		end
	end

	-- Cities raise max troops: put them deep inside my land, away from every contact.
	if threatened or not flag("buildCities") then
		return
	end
	local cost = rules.build_cost_kind(CONFIG.KIND_CITY, structureCount(state, me, CONFIG.KIND_CITY))
	if info.gold < cost + goldReserve then
		return
	end

	local bestTile, bestDistance = nil, -1
	for _, tile in ipairs(scan.interior) do
		if os.clock() - (Intel.lastBuild[tile] or -1000) > CONFIG.BUILD_RETRY_S then
			local tx, ty = tileXY(tile)
			local nearest = math.huge
			for _, contact in pairs(scan.contacts) do
				for _, mineTile in ipairs(contact.mine) do
					local mx, my = tileXY(mineTile)
					nearest = math.min(nearest, (tx - mx) ^ 2 + (ty - my) ^ 2)
				end
			end
			if nearest > bestDistance then
				bestTile, bestDistance = tile, nearest
			end
		end
	end
	if bestTile then
		Intel.lastBuild[bestTile] = os.clock()
		Net.send("build", "build", { type = "build", kind = "city", tile = bestTile })
	end
end

local function manageDiplomacy(state, me, info)
	local rules = state.rules
	local minStrength = (flag("allyMinStrength") or 50) / 100
	local allies = 0

	for id, other in pairs(state.owners) do
		if id ~= me and other.alive then
			if state:are_allies(me, id) then
				allies += 1
				if flag("autoExtend") then
					local key = math.min(me, id) * 1024 + math.max(me, id)
					local expires = state.alliance_expires[key]
					if expires and expires - state.tick < rules.ALLIANCE_EXTEND_WINDOW_TICKS then
						Net.send("extend" .. id, "ally", { type = "ally_extend", target = id })
					end
				end
			elseif flag("autoAccept") and state:has_request(id, me) and not state:is_traitor(id) and other.troops >= info.troops * minStrength then
				Net.send("reply" .. id, "ally", { type = "ally_reply", target = id, accept = true })
			end
		end
	end

	-- Ask the strongest neighbours for an alliance (they would be the costliest to fight).
	if flag("requestAllies") and allies < (rules.AI_MAX_ALLIES or 3) and Intel.scan then
		local pick, pickTroops = nil, 0
		for id in pairs(Intel.scan.contacts) do
			local other = state.owners[id]
			if id ~= 0 and other and other.alive and other.troops > pickTroops and not state:are_allies(me, id) and not state:has_request(me, id) then
				if os.clock() - (Intel.lastAlly[id] or -1000) > CONFIG.ALLY_REQUEST_RETRY_S and other.troops >= info.troops * minStrength then
					pick, pickTroops = id, other.troops
				end
			end
		end
		if pick then
			Intel.lastAlly[pick] = os.clock()
			Net.send("request", "ally", { type = "ally_request", target = pick })
		end
	end
end

-- Chooses and sends at most one attack per cycle.
local function manageAttacks(state, me, info, available, threatened, incoming, outgoing, scan)
	if scan == nil or available < 1 then
		return nil
	end

	local activeTargets = {}
	for _, attack in ipairs(outgoing) do
		if not attack.retreating then
			activeTargets[attack.target] = attack.troops
		end
	end

	local capHit = flag("capGuard") and info.troops >= info.max_troops * ((flag("capThreshold") or 90) / 100)
	local minTiles = flag("minTiles") or 60
	local candidates = {}

	-- Counter-attack: cancel an attacker's troops 1:1 only when I'm clearly stronger.
	if threatened and flag("counterAttack") then
		for _, attack in ipairs(incoming) do
			local contact = scan.contacts[attack.attacker]
			if contact and info.troops >= attack.troops * 1.5 and available >= attack.troops then
				local ratio = math.clamp(attack.troops / info.troops, 0.01, 1)
				Net.send("counter" .. attack.attacker, "attack", { type = "attack", tile = contact.theirs[1], ratio = ratio })
				return { kind = "counter", owner = attack.attacker, ratio = ratio }
			end
		end
	end
	-- No early exit under threat: the raised reserve already keeps enough troops at home.
	for ownerId, contact in pairs(scan.contacts) do
		local isNeutral = ownerId == 0
		local wantsPlayers = flag("smartAttack") or capHit
		local wantsNeutral = flag("autoExpand") or capHit
		if (isNeutral and wantsNeutral) or (not isNeutral and wantsPlayers) then
			local target = state.owners[ownerId]
			local allowed = true
			if not isNeutral then
				allowed = target ~= nil and target.troops <= info.troops * ((flag("maxTargetStrength") or 100) / 100)
			end
			if allowed and activeTargets[ownerId] == nil then
				local ratioCap = isNeutral and ((flag("expandRatio") or 20) / 100) or ((flag("attackRatio") or 50) / 100)
				if capHit then
					ratioCap = math.max(ratioCap, (flag("capSpendRatio") or 40) / 100)
				end
				local candidate = evaluateContact(state, me, info, contact, available, ratioCap)
				if candidate and (candidate.tiles >= (capHit and minTiles / 2 or minTiles)) then
					if not (flag("avoidPosts") and candidate.posts >= 2 and not capHit) then
						if not isNeutral and flag("preferTraitors") and state:is_traitor(ownerId) then
							candidate.efficiency *= 1.5
						end
						table.insert(candidates, candidate)
					end
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a.efficiency > b.efficiency
	end)

	local best = candidates[1]
	if best == nil then
		return nil
	end

	local ratio = math.clamp(best.commit / info.troops, 0.01, 1)
	Net.send("attack", "attack", { type = "attack", tile = best.tile, ratio = ratio })
	best.ratio = ratio
	best.kind = best.owner == 0 and "expand" or "attack"
	return best
end

-- ---------------------------------------------------------------------------
-- Intel panel
-- ---------------------------------------------------------------------------

local function buildPanel(state, me, info, reserve, available, threat, incoming, outgoing, decision)
	local lines = {}
	table.insert(lines, string.format(
		"Troops %s / %s (%d%%)  |  reserve %s  |  free %s",
		formatNumber(info.troops), formatNumber(info.max_troops), math.floor(info.troops / math.max(info.max_troops, 1) * 100 + 0.5),
		formatNumber(reserve), formatNumber(math.max(available, 0))
	))
	table.insert(lines, string.format("Gold %s (+%s/s)  |  tiles %s", formatNumber(info.gold), formatNumber(info.income), formatNumber(info.tiles)))

	if #incoming > 0 then
		local parts = {}
		for _, attack in ipairs(incoming) do
			local attacker = state.owners[attack.attacker]
			table.insert(parts, string.format("%s %s", attacker and attacker.name or "?", formatNumber(attack.troops)))
		end
		table.insert(lines, "UNDER ATTACK: " .. table.concat(parts, ", ") .. string.format(" (threat %s)", formatNumber(threat)))
	else
		table.insert(lines, "No incoming attacks")
	end
	table.insert(lines, string.format("My attacks: %d active  |  intents sent %d (dry %d)", #outgoing, Net.total, Net.dry))

	if decision then
		table.insert(lines, string.format("Last move: %s -> %s, commit %s (~%d tiles)", decision.kind, decision.owner == 0 and "neutral land" or (decision.target and decision.target.name or "?"), formatNumber(decision.commit or 0), math.floor(decision.tiles or 0)))
	end

	-- Neighbours by threat (strength), from the last border scan.
	local scan = Intel.scan
	if scan then
		local neighbours = {}
		for id, contact in pairs(scan.contacts) do
			local other = state.owners[id]
			if id ~= 0 and other and other.alive then
				table.insert(neighbours, { id = id, other = other, border = contact.count })
			end
		end
		table.sort(neighbours, function(a, b)
			return a.other.troops > b.other.troops
		end)
		table.insert(lines, "Neighbours (by troops):")
		for index = 1, math.min(#neighbours, 6) do
			local entry = neighbours[index]
			local tag = state:are_allies(me, entry.id) and "ally" or (state:is_traitor(entry.id) and "TRAITOR" or "enemy")
			table.insert(lines, string.format("  %s [%s]  troops %s  gold %s  tiles %s  border %d", entry.other.name, tag, formatNumber(entry.other.troops), formatNumber(entry.other.gold), formatNumber(entry.other.tiles), entry.border))
		end
	end

	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

local function decide()
	local state, me, info = getState()
	if state == nil then
		if Intel.label then
			Intel.label:SetText("Waiting for a running match...")
		end
		return
	end

	refreshScan(state, me)
	local scan = Intel.scan

	local incoming, outgoing, threat = readAttacks(state, me)
	local threatened = #incoming > 0

	-- Conserve soldiers: keep a base reserve, raised to cover whatever is attacking me.
	local reserve = info.max_troops * ((flag("reservePercent") or 25) / 100)
	if threatened and flag("raiseReserve") then
		reserve = math.max(reserve, threat * (flag("threatMultiplier") or 1.5))
	end
	local available = info.troops - reserve

	manageRetreats(info, outgoing, threatened, reserve)

	local decision = nil
	if flag("autoExpand") or flag("smartAttack") or flag("capGuard") or flag("counterAttack") then
		decision = manageAttacks(state, me, info, available, threatened, incoming, outgoing, scan)
	end
	manageBuilding(state, me, info, threatened, incoming, scan)
	manageDiplomacy(state, me, info)

	if Intel.label then
		Intel.label:SetText(buildPanel(state, me, info, reserve, available, threat, incoming, outgoing, decision or Intel.lastDecision))
	end
	Intel.lastDecision = decision or Intel.lastDecision
end

local function buildUi()
	local ok, body = pcall(game.HttpGet, game, CONFIG.RAW_BASE .. CONFIG.UI_FILE)
	if ok and type(body) == "string" and #body > 0 then
		UI = loadstring(body)()
	else
		assert(isfile and isfile(CONFIG.UI_FILE), "could not download ui.lua and no local copy exists")
		UI = loadstring(readfile(CONFIG.UI_FILE))()
	end

	Window = UI:CreateWindow({
		Title = "RoWorld Hub",
		Subtitle = "World PvP automation",
		Intro = not shared.RoWorldHubIntroSeen,
	})
	shared.RoWorldHubIntroSeen = true

	Window:CreateCategory("Gameplay")

	local expand = Window:CreateTab("Expansion")
	expand:AddSection("Neutral land")
	expand:AddToggle({ Text = "Auto expand", Flag = "autoExpand", Default = false })
	expand:AddSlider({ Text = "Expand ratio (%)", Flag = "expandRatio", Min = 5, Max = 60, Default = 20 })
	expand:AddSection("Troop-cap guard")
	expand:AddToggle({ Text = "Spend near max troops", Flag = "capGuard", Default = false })
	expand:AddSlider({ Text = "Cap threshold (% of max)", Flag = "capThreshold", Min = 70, Max = 100, Default = 90 })
	expand:AddSlider({ Text = "Spend ratio (%)", Flag = "capSpendRatio", Min = 10, Max = 100, Default = 40 })
	expand:AddSection("Conserve soldiers")
	expand:AddSlider({ Text = "Base reserve (% of max)", Flag = "reservePercent", Min = 0, Max = 80, Default = 25 })
	expand:AddToggle({ Text = "Raise reserve when attacked", Flag = "raiseReserve", Default = true })
	expand:AddSlider({ Text = "Threat reserve (x attacker troops)", Flag = "threatMultiplier", Min = 1, Max = 3, Default = 1.5, Increment = 0.25 })

	local combat = Window:CreateTab("Combat")
	combat:AddSection("Smart attack")
	combat:AddToggle({ Text = "Smart attack (players)", Flag = "smartAttack", Default = false })
	combat:AddSlider({ Text = "Max attack ratio (%)", Flag = "attackRatio", Min = 5, Max = 100, Default = 50 })
	combat:AddSlider({ Text = "Min tiles to gain", Flag = "minTiles", Min = 10, Max = 400, Default = 60 })
	combat:AddSlider({ Text = "Max target strength (% of mine)", Flag = "maxTargetStrength", Min = 20, Max = 300, Default = 100 })
	combat:AddSlider({ Text = "Building weight (tiles each)", Flag = "buildingWeight", Min = 0, Max = 100, Default = 25 })
	combat:AddToggle({ Text = "Prefer traitors", Flag = "preferTraitors", Default = true })
	combat:AddToggle({ Text = "Skip fortified areas", Flag = "avoidPosts", Default = true })
	combat:AddSection("Defense")
	combat:AddToggle({ Text = "Counter-attack", Flag = "counterAttack", Default = false })
	combat:AddToggle({ Text = "Auto retreat", Flag = "autoRetreat", Default = true })

	local economy = Window:CreateTab("Economy")
	economy:AddSection("Auto build")
	economy:AddToggle({ Text = "Auto build", Flag = "autoBuild", Default = false })
	economy:AddToggle({ Text = "Build cities (more max troops)", Flag = "buildCities", Default = true })
	economy:AddToggle({ Text = "Defense posts when attacked", Flag = "buildDefense", Default = true })
	economy:AddSlider({ Text = "Keep gold reserve", Flag = "goldReserve", Min = 0, Max = 1000000, Default = 0, Increment = 25000 })

	local diplomacy = Window:CreateTab("Diplomacy")
	diplomacy:AddSection("Alliances")
	diplomacy:AddToggle({ Text = "Auto-accept alliances", Flag = "autoAccept", Default = false })
	diplomacy:AddToggle({ Text = "Auto-extend alliances", Flag = "autoExtend", Default = false })
	diplomacy:AddToggle({ Text = "Request alliances with strong neighbours", Flag = "requestAllies", Default = false })
	diplomacy:AddSlider({ Text = "Min ally strength (% of mine)", Flag = "allyMinStrength", Min = 0, Max = 200, Default = 50 })

	Window:CreateCategory("Visuals")

	local intel = Window:CreateTab("Intel")
	intel:AddSection("Live panel")
	Intel.label = intel:AddLabel("Waiting for a running match...")

	Window:CreateCategory("Player")

	local utility = Window:CreateTab("Utility")
	utility:AddSection("Safety")
	utility:AddToggle({ Text = "Anti-AFK", Flag = "antiAfk", Default = true })
	utility:AddToggle({ Text = "Dry run (log only, send nothing)", Flag = "dryRun", Default = false })
	utility:AddButton({
		Text = "Unload",
		Callback = function()
			RoWorldHub.detach()
		end,
	})
end

-- Internals exposed for live testing.
RoWorldHub.debug = { getState = getState, scanBorders = scanBorders, evaluateContact = evaluateContact, lossPerTile = lossPerTile, readAttacks = readAttacks, net = Net, intel = Intel }

function RoWorldHub.detach()
	if not RoWorldHub.running then
		return
	end
	RoWorldHub.running = false
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	if UI then
		pcall(UI.Destroy, UI)
	end
end

function RoWorldHub.init()
	loadGame()
	RoWorldHub.running = true
	buildUi()

	-- Anti-AFK: answer the idle kick like a click.
	table.insert(connections, localPlayer.Idled:Connect(function()
		if flag("antiAfk") then
			pcall(function()
				virtualUser:CaptureController()
				virtualUser:ClickButton2(Vector2.new())
			end)
		end
	end))

	task.spawn(function()
		while RoWorldHub.running do
			local ok, err = pcall(decide)
			if ok then
				RoWorldHub.errors = 0
			else
				RoWorldHub.errors += 1
				if RoWorldHub.errors <= 3 then
					warn("[RoWorldHub]", err)
				end
				if RoWorldHub.errors >= 10 then
					Window:Notify({ Title = "RoWorld Hub stopped", Text = tostring(err), Duration = 8 })
					RoWorldHub.detach()
					break
				end
			end
			task.wait(CONFIG.DECISION_INTERVAL)
		end
	end)

	Window:Notify({ Title = "RoWorld Hub loaded", Text = "RightShift toggles the menu. Everything starts off.", Duration = 5 })
end

-- Singleton: unload any previous copy first.
if shared.RoWorldHub then
	pcall(shared.RoWorldHub.detach)
end
shared.RoWorldHub = RoWorldHub

xpcall(RoWorldHub.init, function(err)
	onError(err)
	pcall(RoWorldHub.detach)
end)
