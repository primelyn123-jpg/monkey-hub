if not shared then
	return warn("No shared, no script.")
end

loadstring("getfenv().LPH_NO_VIRTUALIZE = function(...) return ... end")()
loadstring("getfenv().PP_SCRAMBLE_NUM = function(...) return ... end")()
loadstring("getfenv().PP_SCRAMBLE_STR = function(...) return ... end")()
loadstring("getfenv().PP_SCRAMBLE_RE_NUM = function(...) return ... end")()

---@module MonkeyHub
-- Survive a Million Monkeys hub. Every server-bound action goes through the game's own
-- client code or a remote the game's own UI fires, with the same arguments, gated by the
-- same attributes the UI reads, and throttled to button-press rates.
local MonkeyHub = {}

-- Maid: owns every connection, instance, drawing and cleanup function so detach() leaves nothing.
local Maid = {}
Maid.__index = Maid

---@return table
function Maid.new()
	return setmetatable({ tasks = {} }, Maid)
end

---@param task any
---@return any
function Maid:give(task)
	table.insert(self.tasks, task)
	return task
end

function Maid:clean()
	for index = #self.tasks, 1, -1 do
		local task = self.tasks[index]
		self.tasks[index] = nil
		local kind = typeof(task)
		if kind == "RBXScriptConnection" then
			task:Disconnect()
		elseif kind == "Instance" then
			pcall(task.Destroy, task)
		elseif kind == "function" then
			pcall(task)
		else
			pcall(function()
				task:Remove()
			end)
		end
	end
end

-- Constants.
local LOBBY_PLACE_ID = 99409088950210
local MATCH_PLACE_ID = 115317125060158

local CONFIG = {
	RAW_BASE = "https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/",
	UI_LIBRARY_FILE = "ui.lua",
	SETTINGS_FILE = "MonkeyHub/settings/config.json",
	INTRO_STAMP_FILE = "MonkeyHub/settings/intro.stamp",
	INTRO_COOLDOWN = 180,
	REEXEC_SOURCE = 'loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/MonkeyHub.lua"))()',
	READY_TIMEOUT = 90,
	TICK_RATE = 0.08,
	BOSS_TICK_RATE = 0.03,
	SCAN_MAX = 4096,
	SCAN_RADIUS = 2000,
	ESP_MAX = 150,
	ESP_RADIUS = 600,
	MIN_FIRE_GAP = 0.06,
	BOSS_DISTANCE = 90,
	BOSS_RETREAT_DISTANCE = 120,
	RETREAT_HEALTH = 0.6,
	SKIP_METER_LIMIT = 0.85,
	SKIP_ENEMY_LIMIT = 400,
	SKIP_RESUME_ENEMIES = 300,
	FLIGHT_HEIGHT = 2.5,
	-- AimAssist.CONE_RANGE measured live 2026-10-24: the game's own assist ignores monkeys past this.
	GAME_ASSIST_RANGE = 250,
	CHEST_REACH = 7,
	CHEST_TIMEOUT = 30,
	-- Minimum seconds between two fires of the same remote; a player can't click faster than this.
	REMOTE_GAPS = { Vote = 1, Upgrade = 1, Ability = 1, GameAction = 10 },
}

-- Services.
local playersService = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")
local lightingService = game:GetService("Lighting")
local virtualUser = game:GetService("VirtualUser")
local pathfindingService = game:GetService("PathfindingService")

-- State.
local localPlayer = playersService.LocalPlayer
local maid = Maid.new()
local Game = {}
local Library, Toggles, Options = nil, nil, nil
local Net = { last = {}, counts = {}, total = 0 }
local state = {
	buffs = false,
	originalFireRate = false,
	zones = {},
	skillLast = {},
	bossEvents = {},
	hazardSequence = 0,
	lastFire = 0,
	lastUpgrade = 0,
	lastSkipScan = 0,
	lastTurret = 0,
	lastUlt = 0,
	lastStatus = 0,
	errors = 0,
}
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Include

---@return table
local function newCrowd()
	return { x = {}, y = {}, z = {}, r = {}, hp = {}, id = {}, d = {} }
end

local crowd = newCrowd()
local skillCrowd = newCrowd()
local espCrowd = newCrowd()

-- Game ModuleScripts must be required at identity 2, otherwise they inherit the executor env.
---@param module Instance
---@return any
local function safeRequire(module)
	local previous = getthreadidentity and getthreadidentity() or 8
	if setthreadidentity then
		setthreadidentity(2)
	end
	local ok, result = pcall(require, module)
	if setthreadidentity then
		setthreadidentity(previous)
	end
	if not ok then
		error(string.format("require %s failed: %s", module:GetFullName(), tostring(result)), 2)
	end
	return result
end

-- Controllers live under PlayerScripts; fall back to the loaded-module list if they were moved.
---@param name string
---@return Instance?
local function findModule(name)
	local scripts = localPlayer:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild(name, true)
	if module then
		return module
	end
	if not getloadedmodules then
		return nil
	end
	for _, loaded in getloadedmodules() do
		if loaded.Name == name then
			return loaded
		end
	end
	return nil
end

---@param root Instance
---@param path string
---@return Instance
local function waitPath(root, path)
	local current = root
	for name in path:gmatch("[^%.]+") do
		current = current:WaitForChild(name, 15)
		assert(current, "missing " .. root.Name .. "." .. path)
	end
	return current
end

---@param folder Instance
---@return table
local function requireFolder(folder)
	local result = {}
	for _, module in folder:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end
		local ok, value = pcall(safeRequire, module)
		if ok then
			result[module.Name] = value
		end
	end
	return result
end

-- Resolve every module and remote once; a missing piece means the game updated and the hub stops.
local function loadGame()
	local unitsModule = findModule("UnitViewController")
	local placementModule = findModule("PlacementController")
	local dataModule = findModule("DataController")
	assert(unitsModule and placementModule and dataModule, "game controllers not found (game updated?)")
	Game.units = safeRequire(unitsModule)
	Game.placement = safeRequire(placementModule)
	Game.data = safeRequire(dataModule)
	Game.gun = safeRequire(waitPath(replicatedStorage, "GunKit.Controllers.GunRigController"))
	Game.cinematic = safeRequire(waitPath(replicatedStorage, "GunKit.Shared.CutsceneFlag"))
	Game.patterns = safeRequire(waitPath(replicatedStorage, "Shared.Content.AoePatterns"))
	Game.progression = safeRequire(waitPath(replicatedStorage, "Shared.Content.Progression"))
	Game.abilities = requireFolder(waitPath(replicatedStorage, "Shared.Content.Abilities"))
	Game.classes = requireFolder(waitPath(replicatedStorage, "Shared.Content.Classes"))
	Game.bossDefinitions = requireFolder(waitPath(replicatedStorage, "Shared.Bosses.Definitions"))
	Game.waves = waitPath(replicatedStorage, "Shared.Waves")
	Game.bossesLive = waitPath(replicatedStorage, "Shared.Bosses.Live")
	Game.voteRemote = waitPath(Game.waves, "Vote")
	Game.upgradeRemote = waitPath(replicatedStorage, "Remotes.UpgradeRequest")
	Game.gameActionRemote = waitPath(replicatedStorage, "Remotes.GameAction")
	Game.abilityRemote = waitPath(replicatedStorage, "Shared.Abilities.Use")
	Game.bossFxRemote = waitPath(replicatedStorage, "Shared.Bosses.Fx")
	Game.aoeRemote = waitPath(replicatedStorage, "Shared.Effects.Aoe")
	assert(type(Game.units.crowd) == "function", "UnitViewController.crowd missing (game updated?)")
	assert(type(Game.gun.AddAimOverride) == "function", "GunRigController.AddAimOverride missing (game updated?)")
end

-- The single exit for every remote: per-remote gap, counted, never faster than a human click.
---@param key string
---@param group string
---@param remote RemoteEvent
---@return boolean
function Net.fire(key, group, remote, ...)
	local now = os.clock()
	if now - (Net.last[key] or -math.huge) < CONFIG.REMOTE_GAPS[group] then
		return false
	end
	Net.last[key] = now
	Net.counts[group] = (Net.counts[group] or 0) + 1
	Net.total += 1
	remote:FireServer(...)
	return true
end

---@param name string
---@return boolean
local function enabled(name)
	local toggle = Toggles and Toggles[name]
	return toggle ~= nil and toggle.Value == true
end

-- Fire-rate multiplier from the Rapid fire toggle (1 when off).
---@return number
local function rapidMultiplier()
	if not enabled("RapidFire") then
		return 1
	end
	return math.max(1, tonumber(Options and Options.RapidFireMult and Options.RapidFireMult.Value) or 1)
end

-- Wraps GunKit Buffs.fireRate so the game's own firing loop runs faster. The server may still cap cadence.
local function hookRapidFire()
	if state.originalFireRate then
		return
	end
	local ok, buffs = pcall(function()
		return safeRequire(waitPath(replicatedStorage, "GunKit.Shared.Buffs"))
	end)
	if not ok or type(buffs) ~= "table" or type(buffs.fireRate) ~= "function" then
		warn("[MonkeyHub] Buffs.fireRate not found; rapid fire unavailable")
		return
	end
	local original = buffs.fireRate
	pcall(function()
		if setreadonly then
			setreadonly(buffs, false)
		end
	end)
	local installed = pcall(function()
		buffs.fireRate = function(...)
			return original(...) * rapidMultiplier()
		end
	end)
	if installed then
		state.originalFireRate = original
		state.buffs = buffs
	end
end

---@return Model?, Humanoid?, BasePart?
local function getCharacter()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, root
end

---@param i number
---@param set table
---@return Vector3
local function crowdPoint(set, i)
	return Vector3.new(set.x[i], set.y[i], set.z[i])
end

---@param point Vector3
---@param radius number
---@param count number
---@return number
local function clusterCount(point, radius, count)
	local total = 0
	for i = 1, count do
		if skillCrowd.hp[i] > 0 and (crowdPoint(skillCrowd, i) - point).Magnitude <= radius then
			total += 1
		end
	end
	return total
end

-- Line of sight against map geometry only; monkeys are client-rendered views, not blockers.
---@param origin Vector3
---@param point Vector3
---@return boolean
local function hasLineOfSight(origin, point)
	if not enabled("RequireSight") then
		return true
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		return true
	end
	sightParams.FilterDescendantsInstances = { map }
	local delta = point - origin
	local hit = workspace:Raycast(origin, delta, sightParams)
	return not hit or hit.Distance >= delta.Magnitude - 4
end

-- Hazards: telegraphs arrive through the game's own OnClientEvent feeds; we only listen.
---@param zone table
local function addHazard(zone)
	state.hazardSequence += 1
	state.zones["persistent_" .. state.hazardSequence] = zone
end

local function hookHazards()
	maid:give(Game.bossFxRemote.OnClientEvent:Connect(function(id, _, event, attackName, data)
		local definition
		for _, live in Game.bossesLive:GetChildren() do
			if live:GetAttribute("Id") == id then
				definition = Game.bossDefinitions[live:GetAttribute("Definition")]
				break
			end
		end
		local attack = definition and definition.Attacks and definition.Attacks[attackName]
		if event == "Windup" then
			state.bossEvents[id] = { untilTime = os.clock() + 5, attack = attackName }
		elseif event == "Recovery" or event == "Cancel" or event == "Dead" then
			state.bossEvents[id] = nil
		end
		if type(data) ~= "table" then
			return
		end
		local now = workspace:GetServerTimeNow()
		if event == "Residue" and typeof(data.At) == "Vector3" then
			addHazard({ Position = data.At, Yaw = 0, Pattern = "Circle", Radius = data.Radius or 10, EndsAt = data.Ends or now + 6 })
		elseif event == "Acid" and type(data.Points) == "table" then
			for i = 1, #data.Points - 1 do
				addHazard({ Kind = "AcidSegment", A = data.Points[i], B = data.Points[i + 1], Width = data.Width or 20, EndsAt = data.Ends or now + 6 })
			end
		elseif event == "Charge" and typeof(data.At) == "Vector3" and typeof(data.Direction) == "Vector3" then
			local finish = data.At + data.Direction * (data.Distance or 50)
			local width = attack and attack.Aoe and attack.Aoe.Width or 24
			addHazard({ Kind = "AcidSegment", A = data.At, B = finish, Width = width, EndsAt = (data.Start or now) + (data.Duration or 1) + 0.5 })
		end
	end))
	maid:give(Game.aoeRemote.OnClientEvent:Connect(function(position, yaw, pattern, radius, endsAt, _, id, width)
		if typeof(position) == "Vector3" then
			state.zones[id] = { Position = position, Yaw = yaw, Pattern = pattern, Radius = radius, Width = width, EndsAt = endsAt + 0.4 }
			return
		end
		if type(position) ~= "number" then
			return
		end
		local zone = state.zones[position]
		if typeof(yaw) == "Vector3" and zone then
			zone.Position, zone.Yaw, zone.Radius = yaw, pattern, radius
		else
			state.zones[position] = nil
		end
	end))
end

---@param point Vector3
---@param serverNow number
---@return boolean
local function dangerous(point, serverNow)
	local margin = state.bossId and 16 or 10
	if state.bossPoint then
		local delta = point - state.bossPoint
		if Vector3.new(delta.X, 0, delta.Z).Magnitude < (state.requiredBossDistance or CONFIG.BOSS_DISTANCE) - 8 then
			return true
		end
	end
	for id, zone in state.zones do
		if zone.EndsAt < serverNow then
			state.zones[id] = nil
			continue
		end
		if zone.Kind == "AcidSegment" then
			local segment = Vector3.new(zone.B.X - zone.A.X, 0, zone.B.Z - zone.A.Z)
			local delta = Vector3.new(point.X - zone.A.X, 0, point.Z - zone.A.Z)
			local length = segment:Dot(segment)
			local t = length > 0 and math.clamp(delta:Dot(segment) / length, 0, 1) or 0
			if (delta - segment * t).Magnitude < zone.Width * 0.5 + margin then
				return true
			end
		elseif zone.Kind == "AcidBox" then
			local localPoint = zone.CFrame:PointToObjectSpace(point)
			if math.abs(localPoint.X) < zone.Size.X * 0.5 + margin and math.abs(localPoint.Z) < zone.Size.Z * 0.5 + margin then
				return true
			end
		else
			local shape = Game.patterns.Patterns and Game.patterns.Patterns[zone.Pattern]
			if not shape then
				continue
			end
			local dx, dz = point.X - zone.Position.X, point.Z - zone.Position.Z
			local hit
			if shape.Kind == "Rect" then
				hit = Game.patterns.containsRect(dx, dz, zone.Yaw, zone.Radius, zone.Width or 10, -margin)
			else
				hit = Game.patterns.contains(shape, dx, dz, zone.Yaw, zone.Radius, -margin)
			end
			if hit then
				return true
			end
		end
	end
	return false
end

---@param from Vector3
---@param to Vector3
---@param serverNow number
---@return boolean
local function safePath(from, to, serverNow)
	local steps = math.max(2, math.ceil((to - from).Magnitude / 8))
	local leftDanger = not dangerous(from, serverNow)
	for i = 1, steps do
		local hit = dangerous(from:Lerp(to, i / steps), serverNow)
		if hit and leftDanger then
			return false
		end
		if not hit then
			leftDanger = true
		end
	end
	return leftDanger
end

-- Pick the closest safe point to where we wanted to go; ring search around the root.
---@param root BasePart
---@param destination Vector3
---@return Vector3
local function dodge(root, destination)
	state.avoiding = false
	if not enabled("AvoidHazards") then
		return destination
	end
	local serverNow = workspace:GetServerTimeNow()
	local ahead = root.Position + root.AssemblyLinearVelocity * 0.7
	if not dangerous(root.Position, serverNow) and not dangerous(ahead, serverNow) and not dangerous(destination, serverNow)
		and safePath(root.Position, destination, serverNow) then
		return destination
	end
	local best, bestScore
	for _, radius in { 30, 60, 100, 160 } do
		for i = 1, 16 do
			local angle = i * math.pi / 8
			local point = root.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			if dangerous(point, serverNow) or not safePath(root.Position, point, serverNow) then
				continue
			end
			local score = (point - destination).Magnitude + radius * 0.25
			if not bestScore or score < bestScore then
				best, bestScore = point, score
			end
		end
	end
	state.avoiding = true
	return best or root.Position
end

-- Boss tracking, health-based retreat and acid puddles.
---@param root BasePart
---@param humanoid Humanoid
---@param now number
local function survival(root, humanoid, now)
	state.healthRatio = humanoid.Health / math.max(humanoid.MaxHealth, 1)
	if state.lastHealth and humanoid.Health < state.lastHealth - 3 then
		state.retreatUntil = now + 5
	end
	state.lastHealth = humanoid.Health
	local liveBosses = {}
	for _, live in Game.bossesLive:GetChildren() do
		local id = live:GetAttribute("Id")
		if id and (live:GetAttribute("Health") or 1) > 0 then
			liveBosses[id] = live
		end
	end
	state.bossId, state.bossPoint, state.bossName, state.bossHealth = nil, nil, nil, nil
	if next(liveBosses) then
		local count = Game.units.crowd(root.Position.X, root.Position.Z, CONFIG.SCAN_RADIUS, CONFIG.SCAN_MAX, crowd)
		local nearest = math.huge
		for i = 1, count do
			local live = liveBosses[crowd.id[i]]
			if not live then
				continue
			end
			local point = crowdPoint(crowd, i)
			local distance = (point - root.Position).Magnitude
			if distance < nearest then
				nearest = distance
				state.bossId, state.bossPoint = crowd.id[i], point
				state.bossName = live:GetAttribute("Definition")
				state.bossHealth = live:GetAttribute("Health")
			end
		end
	end
	local retreat = state.healthRatio < CONFIG.RETREAT_HEALTH or now < (state.retreatUntil or 0)
	state.requiredBossDistance = retreat and CONFIG.BOSS_RETREAT_DISTANCE or CONFIG.BOSS_DISTANCE
	if now - (state.lastAcidScan or 0) <= 0.4 then
		return
	end
	state.lastAcidScan = now
	local acid = workspace:FindFirstChild("BossAcid")
	if not acid then
		return
	end
	for _, part in acid:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 0.95 then
			state.zones[part] = { Kind = "AcidBox", CFrame = part.CFrame, Size = part.Size, EndsAt = workspace:GetServerTimeNow() + 0.7 }
		end
	end
end

-- Upgrade shop: same remote and argument the shop button sends, only when the shop says it's buyable.
local function upgrades()
	local weapon = localPlayer:GetAttribute("WeaponUpgradeAvailable")
	local health = localPlayer:GetAttribute("HealthUpgradeAvailable")
	state.upgradesComplete = weapon == false and health == false
	if not enabled("AutoUpgrade") then
		return
	end
	local cash = localPlayer:GetAttribute("Cash") or 0
	local kind, cost
	if weapon == true then
		kind, cost = "Weapon", localPlayer:GetAttribute("WeaponUpgradeCost") or math.huge
	elseif health == true then
		kind, cost = "Health", localPlayer:GetAttribute("HealthUpgradeCost") or math.huge
	end
	if not kind or cash < cost then
		return
	end
	Net.fire("Upgrade", "Upgrade", Game.upgradeRemote, kind)
end

-- Wave auto-skip vote: only while it's safe to pull more monkeys in.
---@param root BasePart
---@param humanoid Humanoid
---@param now number
local function adaptiveSkip(root, humanoid, now)
	if now - state.lastSkipScan < 0.4 then
		return
	end
	state.lastSkipScan = now
	local count = Game.units.crowd(root.Position.X, root.Position.Z, CONFIG.SCAN_RADIUS, CONFIG.SCAN_MAX, skillCrowd)
	local alive = 0
	for i = 1, count do
		if skillCrowd.hp[i] > 0 then
			alive += 1
		end
	end
	state.liveEnemies = alive
	state.skillEnemyCount = count
	if not enabled("AutoSkip") then
		if state.skipOwned and localPlayer:GetAttribute("AutoSkip") == true then
			if Net.fire("Vote", "Vote", Game.voteRemote, "Auto", false) then
				state.skipOwned = false
			end
		end
		return
	end
	local progress = Game.waves:GetAttribute("BossProgress") or 0
	local bossFight = Game.waves:GetAttribute("BossState") == "Fight" or #Game.bossesLive:GetChildren() > 0
	if alive >= CONFIG.SKIP_ENEMY_LIMIT then
		state.skipCrowdPaused = true
	elseif alive < CONFIG.SKIP_RESUME_ENEMIES then
		state.skipCrowdPaused = false
	end
	local wanted = not bossFight
		and progress < CONFIG.SKIP_METER_LIMIT
		and not state.skipCrowdPaused
		and humanoid.Health / humanoid.MaxHealth >= 0.8
		and now >= (state.retreatUntil or 0)
	if (localPlayer:GetAttribute("AutoSkip") == true) == wanted then
		return
	end
	if Net.fire("Vote", "Vote", Game.voteRemote, "Auto", wanted) then
		state.skipOwned = true
	end
end

-- Weapon handling: equip the first real gun (a Tool with a WeaponConfig).
---@param humanoid Humanoid
---@param character Model
---@return Tool?
local function equipGun(humanoid, character)
	local equipped = character:FindFirstChildOfClass("Tool")
	if equipped and equipped:FindFirstChild("WeaponConfig") then
		state.lastGunTool = equipped
		return equipped
	end
	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	local candidate = state.lastGunTool
	if not candidate or not candidate:FindFirstChild("WeaponConfig") or (candidate.Parent ~= backpack and candidate.Parent ~= character) then
		candidate = nil
		for _, tool in backpack and backpack:GetChildren() or {} do
			if tool:IsA("Tool") and tool:FindFirstChild("WeaponConfig") then
				candidate = tool
				break
			end
		end
	end
	if not candidate then
		return nil
	end
	if equipped then
		equipped:Deactivate()
	end
	humanoid:EquipTool(candidate)
	state.lastGunTool = candidate
	return candidate
end

-- Tool-based skills (e.g. grenades) equip, click once, then the gun comes back.
---@param name string
---@param humanoid Humanoid
---@param character Model
---@param now number
---@return boolean
local function activateSkillTool(name, humanoid, character, now)
	if now < (state.skillToolUntil or 0) then
		return false
	end
	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	local tool = character:FindFirstChild(name) or (backpack and backpack:FindFirstChild(name))
	if not tool or not tool:IsA("Tool") then
		return false
	end
	state.skillToolUntil = now + 0.8
	humanoid:EquipTool(tool)
	task.delay(0.15, function()
		if localPlayer.Character ~= character or humanoid.Health <= 0 or tool.Parent ~= character then
			return
		end
		tool:Activate()
		task.delay(0.1, function()
			if tool.Parent then
				tool:Deactivate()
			end
		end)
	end)
	task.delay(0.8, function()
		if localPlayer.Character == character and humanoid.Health > 0 then
			equipGun(humanoid, character)
		end
	end)
	return true
end

---@param root BasePart
---@param stats table
---@return Vector3?
local function skillTarget(root, stats)
	local range = stats.Range or 200
	local best, bestCount
	for i = 1, state.skillEnemyCount or 0 do
		if skillCrowd.hp[i] <= 0 then
			continue
		end
		local point = crowdPoint(skillCrowd, i)
		if (point - root.Position).Magnitude >= range * 0.9 then
			continue
		end
		local count = clusterCount(point, stats.BlastRadius or 12, state.skillEnemyCount)
		if not bestCount or count > bestCount then
			best, bestCount = point, count
		end
	end
	return best
end

---@param threshold number
---@return boolean
local function teamNeedsHeal(threshold)
	for _, player in playersService:GetPlayers() do
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and humanoid.Health / humanoid.MaxHealth < threshold then
			return true
		end
	end
	return false
end

---@param kind string
---@return number
local function placementCount(kind)
	local count = 0
	local folder = workspace:FindFirstChild("Placements")
	for _, object in folder and folder:GetChildren() or {} do
		if object:IsA("Model") and object.Name == kind then
			count += 1
		end
	end
	return count
end

-- Cast one skill the way its own keybind would: tool skills click the tool, placed skills go
-- through PlacementController, self/ultimate skills fire the ability remote with the game's aim.
---@param id string
---@param stats table
---@param humanoid Humanoid
---@param now number
---@param aim Vector3?
---@return boolean
local function castSkill(id, stats, humanoid, now, aim)
	if now - (state.skillLast[id] or -100) < math.max(1, stats.Swing or 0) then
		return false
	end
	if stats.Tool then
		if not activateSkillTool(stats.Tool, humanoid, localPlayer.Character, now) then
			return false
		end
	elseif not stats.Self and not stats.Ultimate then
		Game.placement:Activate(id)
	else
		local previousAim = state.targetPoint
		state.skillAimPoint = aim
		if aim then
			state.targetPoint = aim
		end
		Game.gun:PushAim()
		local fired = Net.fire("Ability:" .. id, "Ability", Game.abilityRemote, id)
		state.skillAimPoint = nil
		state.targetPoint = previousAim
		if not fired then
			return false
		end
	end
	state.skillLast[id] = now
	if id == localPlayer:GetAttribute("Ability1Id") then
		state.gunResumeAt = now + 0.8
	end
	return true
end

---@param id string
---@param stats table
---@param root BasePart
---@param hp number
---@return boolean, Vector3?
local function skillWanted(id, stats, root, hp)
	local target = skillTarget(root, stats)
	local count = state.skillEnemyCount or 0
	if id == "Grenade" or id == "Decoy" or id == "Quickdraw" then
		return target ~= nil, target
	elseif id == "ShortFuse" then
		return clusterCount(root.Position, (stats.BlastRadius or 36) * 0.8, count) > 0 or hp < 0.6, target
	elseif id == "GroundSlam" then
		return clusterCount(root.Position, (stats.Radius or 16) * 0.9, count) > 0, target
	elseif id == "Brace" or id == "Adrenaline" then
		return hp < 0.8 or state.bossId ~= nil, target
	elseif id == "Medkit" then
		return hp < 0.85, root.Position
	elseif id == "HealingPod" then
		return teamNeedsHeal(0.85) and placementCount("HealingPod") == 0, target
	elseif id == "Barricade" or id == "Mine" then
		return clusterCount(root.Position, 25, count) >= 3 and not state.bossId and not state.avoiding, target
	elseif id == "Ricochet" then
		local velocity = root.AssemblyLinearVelocity
		local direction = velocity.Magnitude > 1 and velocity.Unit or root.CFrame.LookVector
		return target ~= nil and not state.bossId and safePath(root.Position, root.Position + direction * 22, workspace:GetServerTimeNow()), target
	elseif id == "Repair" then
		local folder = workspace:FindFirstChild("Placements")
		for _, object in folder and folder:GetChildren() or {} do
			local max = object:GetAttribute("MaxHealth")
			if object:IsA("Model") and max and (object:GetAttribute("Health") or max) < max
				and (object:GetPivot().Position - root.Position).Magnitude < (stats.Range or 14) then
				return true, target
			end
		end
	end
	return false, nil
end

-- Primary/secondary class skills, gated on the same ReadyAt/Cost/Cash attributes the HUD shows.
---@param root BasePart
---@param humanoid Humanoid
---@param now number
local function useClassSkills(root, humanoid, now)
	if not enabled("AutoSkills") then
		return
	end
	local hp = humanoid.Health / humanoid.MaxHealth
	local serverNow = workspace:GetServerTimeNow()
	local cash = localPlayer:GetAttribute("Cash") or 0
	for i = 1, 2 do
		local slot = "Ability" .. i
		local id = localPlayer:GetAttribute(slot .. "Id")
		local definition = id and Game.abilities[id]
		if not definition or id == "Turret" or id == "Satchel" then
			continue
		end
		local stats = Game.progression.Gameplay(definition, localPlayer:GetAttribute(slot .. "Level") or 1)
		local cost = localPlayer:GetAttribute(slot .. "Cost") or stats.Cost or 0
		if serverNow < (localPlayer:GetAttribute(slot .. "ReadyAt") or 0) or cash < cost then
			continue
		end
		if cost > 0 and not state.upgradesComplete then
			continue
		end
		local wanted, aim = skillWanted(id, stats, root, hp)
		if wanted then
			castSkill(id, stats, humanoid, now, aim)
		end
	end
end

---@param root BasePart
---@param humanoid Humanoid
---@param now number
local function useUltimate(root, humanoid, now)
	if not enabled("AutoUltimate") then
		return
	end
	local charge = localPlayer:GetAttribute("UltimateCharge") or 0
	if charge < 1 or workspace:GetServerTimeNow() < (localPlayer:GetAttribute("UltimateReadyAt") or 0) or now - state.lastUlt < 2 then
		return
	end
	local id = localPlayer:GetAttribute("UltimateId")
	local definition = id and Game.abilities[id]
	if not definition then
		return
	end
	local stats = Game.progression.Gameplay(definition, localPlayer:GetAttribute("UltimateLevel") or 1)
	local aim = skillTarget(root, stats)
	local hp = humanoid.Health / humanoid.MaxHealth
	local count = state.skillEnemyCount or 0
	local wanted = true
	if id == "CodeBlue" then
		wanted = teamNeedsHeal(0.9)
	elseif id == "Overclock" then
		wanted = placementCount("Turret") > 0
	elseif id == "LastStand" then
		wanted = hp < 0.7
	elseif id == "Airstrike" then
		wanted = aim ~= nil
	elseif id == "FanTheHammer" then
		wanted = clusterCount(root.Position, stats.Fan and stats.Fan.TargetRadius or 30, count) > 0
	elseif id == "Warpath" then
		wanted = clusterCount(root.Position, stats.TauntRadius or 30, count) > 0 or hp < 0.7
	elseif id == "BlastDash" then
		local direction = root.CFrame.LookVector
		aim = root.Position + Vector3.new(direction.X, 0, direction.Z).Unit * 120
		wanted = count > 0 and safePath(root.Position, aim, workspace:GetServerTimeNow())
	end
	if not wanted then
		return
	end
	if castSkill(id, stats, humanoid, now, aim) then
		state.lastUlt = now
	end
end

-- Turret: drop one where we stand when monkeys are in its range and the slot is ready.
---@param root BasePart
---@param now number
local function autoTurret(root, now)
	if not enabled("AutoTurret") or state.bossId or now - state.lastTurret < 2 then
		return
	end
	local slot
	for i = 1, 2 do
		if localPlayer:GetAttribute("Ability" .. i .. "Id") == "Turret" then
			slot = "Ability" .. i
		end
	end
	local definition = Game.abilities.Turret
	if not slot or not definition then
		return
	end
	local cost = localPlayer:GetAttribute(slot .. "Cost") or (definition.Gameplay and definition.Gameplay.Cost) or 0
	if (localPlayer:GetAttribute("Cash") or 0) < cost or workspace:GetServerTimeNow() < (localPlayer:GetAttribute(slot .. "ReadyAt") or 0) then
		return
	end
	local stats = Game.progression.Gameplay(definition, localPlayer:GetAttribute(slot .. "Level") or 1)
	if clusterCount(root.Position, (stats.Range or 50) * 0.8, state.skillEnemyCount or 0) == 0 then
		return
	end
	state.lastTurret = now
	Game.placement:Activate("Turret")
end

-- Ground movement: walk away from the swarm and out of telegraphs with Humanoid:MoveTo.
---@param humanoid Humanoid
---@param root BasePart
local function kite(humanoid, root)
	if enabled("FlightOrbit") then
		return
	end
	local destination
	if enabled("Kite") and state.enemyPoint then
		local distance = Options.KiteDistance.Value
		local delta = root.Position - state.enemyPoint
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude < distance then
			local away = flat.Magnitude > 0.1 and flat.Unit or root.CFrame.LookVector
			destination = root.Position + away * (distance - flat.Magnitude + 6)
		end
	end
	if state.bossPoint then
		local delta = root.Position - state.bossPoint
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude < state.requiredBossDistance then
			local away = flat.Magnitude > 0.1 and flat.Unit or root.CFrame.LookVector
			destination = state.bossPoint + away * state.requiredBossDistance
		end
	end
	local safe = dodge(root, destination or root.Position)
	if destination or state.avoiding then
		humanoid:MoveTo(safe)
		state.moving = true
	elseif state.moving then
		humanoid:Move(Vector3.zero)
		state.moving = false
	end
end

-- Chests: walk there with pathfinding and press the prompt like a player would (10-stud server range).
local Chest = { tried = {}, lastStart = 0 }

---@param chest Model
---@return boolean
function Chest.isOpened(chest)
	for _, id in string.split(localPlayer:GetAttribute("OpenedChests") or "", ",") do
		if id == chest.Name then
			return true
		end
	end
	return false
end

---@param root BasePart
---@return Model?, ProximityPrompt?
function Chest.pick(root)
	local folder = workspace:FindFirstChild("Chests")
	local budget = (localPlayer:GetAttribute("Cash") or 0) - Options.ChestReserve.Value
	local best, bestPrompt, bestDistance
	for _, chest in folder and folder:GetChildren() or {} do
		local price = chest:GetAttribute("Price")
		local prompt = chest:FindFirstChildWhichIsA("ProximityPrompt", true)
		if not price or price > budget or not prompt or not prompt.Enabled or chest:GetAttribute("Leaving") then
			continue
		end
		if Chest.isOpened(chest) or os.clock() < (Chest.tried[chest] or 0) then
			continue
		end
		local distance = (chest:GetPivot().Position - root.Position).Magnitude
		if not bestDistance or distance < bestDistance then
			best, bestPrompt, bestDistance = chest, prompt, distance
		end
	end
	return best, bestPrompt
end

---@param chest Model
---@param root BasePart
function Chest.plan(chest, root)
	local path = pathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local ok = pcall(path.ComputeAsync, path, root.Position, chest:GetPivot().Position)
	Chest.waypoints = ok and path.Status == Enum.PathStatus.Success and path:GetWaypoints() or nil
	Chest.waypointIndex = 2
end

-- Returns true while a chest run owns movement, so kiting stays out of the way.
---@param humanoid Humanoid
---@param root BasePart
---@param now number
---@return boolean
function Chest.step(humanoid, root, now)
	if not enabled("AutoChest") or state.bossId or (state.healthRatio or 1) < 0.6 or enabled("FlightOrbit") then
		Chest.target = nil
		return false
	end
	if not Chest.target then
		if now - Chest.lastStart < 3 then
			return false
		end
		local chest, prompt = Chest.pick(root)
		if not chest then
			return false
		end
		Chest.target, Chest.prompt, Chest.startedAt, Chest.lastStart = chest, prompt, now, now
		Chest.planning = true
		task.spawn(function()
			Chest.plan(chest, root)
			Chest.planning = false
		end)
	end
	local chest, prompt = Chest.target, Chest.prompt
	if not chest.Parent or not prompt.Enabled or Chest.isOpened(chest) or now - Chest.startedAt > CONFIG.CHEST_TIMEOUT then
		Chest.tried[chest] = os.clock() + 20
		Chest.target = nil
		return false
	end
	local goal = chest:GetPivot().Position
	if (goal - root.Position).Magnitude <= CONFIG.CHEST_REACH then
		humanoid:Move(Vector3.zero)
		prompt:InputHoldBegin()
		task.delay(0.1, function()
			prompt:InputHoldEnd()
		end)
		Chest.tried[chest] = os.clock() + 5
		Chest.target = nil
		return true
	end
	if Chest.planning then
		return true
	end
	local waypoints = Chest.waypoints
	local waypoint = waypoints and waypoints[Chest.waypointIndex]
	if waypoint and (waypoint.Position - root.Position).Magnitude < 4 then
		Chest.waypointIndex += 1
		waypoint = waypoints[Chest.waypointIndex]
	end
	if waypoint and waypoint.Action == Enum.PathWaypointAction.Jump then
		humanoid.Jump = true
	end
	humanoid:MoveTo(dodge(root, waypoint and waypoint.Position or goal))
	return true
end

-- Flight orbit (risky): LinearVelocity circle around the map center, optional local noclip.
local Flight = { obstacleState = {}, obstacleConnections = {} }

---@param object Instance
function Flight.disableObstacle(object)
	local original = Flight.obstacleState[object]
	if not original then
		original = {}
		Flight.obstacleState[object] = original
	end
	if object:IsA("BasePart") then
		if original.CanCollide == nil then
			original.CanCollide = object.CanCollide
		end
		object.CanCollide = false
	end
end

function Flight.restoreObstacles()
	for _, connection in Flight.obstacleConnections do
		connection:Disconnect()
	end
	table.clear(Flight.obstacleConnections)
	for object, original in Flight.obstacleState do
		for property, value in original do
			pcall(function()
				object[property] = value
			end)
		end
	end
	table.clear(Flight.obstacleState)
	Flight.noclipped = false
end

function Flight.stop()
	Flight.restoreObstacles()
	if Flight.velocity then
		Flight.velocity:Destroy()
	end
	if Flight.attachment then
		Flight.attachment:Destroy()
	end
	if Flight.root and Flight.root.Parent then
		Flight.root.AssemblyLinearVelocity = Vector3.zero
	end
	Flight.root, Flight.attachment, Flight.velocity, Flight.center = nil, nil, nil, nil
end

---@param humanoid Humanoid
---@param root BasePart
---@param destination Vector3
function Flight.flyTo(humanoid, root, destination)
	if Flight.root ~= root or not Flight.velocity or not Flight.velocity.Parent then
		Flight.stop()
		Flight.root = root
		Flight.attachment = Instance.new("Attachment")
		Flight.attachment.Parent = root
		Flight.velocity = Instance.new("LinearVelocity")
		Flight.velocity.Attachment0 = Flight.attachment
		Flight.velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		Flight.velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		Flight.velocity.MaxForce = 1000000
		Flight.velocity.VectorVelocity = Vector3.zero
		Flight.velocity.Parent = root
		humanoid:Move(Vector3.zero)
	end
	if enabled("FlightNoclip") and not Flight.noclipped then
		Flight.noclipped = true
		for _, name in { "Map", "EdgeWalls", "Placements", "GlassKits" } do
			local folder = workspace:FindFirstChild(name)
			if not folder then
				continue
			end
			for _, object in folder:GetDescendants() do
				Flight.disableObstacle(object)
			end
			table.insert(Flight.obstacleConnections, folder.DescendantAdded:Connect(Flight.disableObstacle))
		end
	elseif not enabled("FlightNoclip") and Flight.noclipped then
		Flight.restoreObstacles()
	end
	local speed = Options.FlightSpeed.Value
	local delta = destination - root.Position
	Flight.velocity.VectorVelocity = delta.Magnitude > 0.6 and delta.Unit * math.min(speed, delta.Magnitude * 3) or Vector3.zero
end

---@param humanoid Humanoid
---@param root BasePart
---@param now number
function Flight.orbit(humanoid, root, now)
	local map = workspace:FindFirstChild("Map")
	if not map then
		Flight.stop()
		return
	end
	local speed = Options.FlightSpeed.Value
	if Flight.map ~= map or not Flight.center then
		local bounds, size = map:GetBoundingBox()
		local center = Vector3.new(bounds.Position.X, 0, bounds.Position.Z)
		local spawn = map:FindFirstChild("SpawnLocation")
		Flight.radius = math.clamp(math.min(size.X, size.Z) * 0.25, 35, 120)
		Flight.angle = math.atan2(root.Position.Z - center.Z, root.Position.X - center.X)
		Flight.height = (spawn and spawn.Position.Y or root.Position.Y) + CONFIG.FLIGHT_HEIGHT
		Flight.time = now
		Flight.center = center
		Flight.map = map
	end
	local dt = math.clamp(now - (Flight.time or now), 0, 0.2)
	Flight.time = now
	Flight.angle = (Flight.angle + speed / Flight.radius * dt) % (math.pi * 2)
	local ahead = Flight.angle + 0.18
	local destination = Flight.center + Vector3.new(math.cos(ahead) * Flight.radius, Flight.height, math.sin(ahead) * Flight.radius)
	if state.bossPoint then
		local delta = root.Position - state.bossPoint
		local angle = math.atan2(delta.Z, delta.X) + speed / state.requiredBossDistance * dt + 0.12
		destination = state.bossPoint + Vector3.new(math.cos(angle) * state.requiredBossDistance, 10, math.sin(angle) * state.requiredBossDistance)
	end
	Flight.flyTo(humanoid, root, dodge(root, destination))
end

-- Targeting: nearest / boss / lowest HP inside the weapon's own max range, with lead.
---@param root BasePart
---@param range number
---@param count number
---@return number?, number
local function pickTarget(root, range, count)
	local mode = Options.TargetMode.Value
	local best, bestScore, bestDistance = nil, math.huge, math.huge
	local origin = root.Position + Vector3.new(0, 1.5, 0)
	for i = 1, count do
		if crowd.hp[i] <= 0 then
			continue
		end
		local point = crowdPoint(crowd, i)
		local distance = (point - root.Position).Magnitude
		if distance > range then
			continue
		end
		local score = distance
		if mode == "Lowest HP" then
			score = crowd.hp[i]
		end
		if mode ~= "Nearest" and crowd.id[i] == state.bossId then
			score = -math.huge
		end
		if score < bestScore and hasLineOfSight(origin, point) then
			best, bestScore, bestDistance = i, score, distance
		end
	end
	return best, bestDistance
end

---@param humanoid Humanoid
---@param character Model
---@param root BasePart
---@param now number
local function combat(humanoid, character, root, now)
	local wantsAim = enabled("AutoFight") or enabled("AimAssist")
	if not wantsAim or now < (state.skillToolUntil or 0) or now < (state.gunResumeAt or 0) then
		state.targetPoint = nil
		return
	end
	local tool = enabled("AutoFight") and equipGun(humanoid, character) or character:FindFirstChildOfClass("Tool")
	local configModule = tool and tool:FindFirstChild("WeaponConfig")
	if not configModule then
		state.targetPoint = nil
		return
	end
	if tool ~= state.tool then
		if state.tool then
			state.tool:Deactivate()
		end
		state.tool = tool
		state.config = safeRequire(configModule)
		state.lastFire = 0
	end
	local projectile = state.config and state.config.projectile
	if not projectile then
		return
	end
	local gameAim = Options.AimMode.Value == "Game assist"
	local range = projectile.maxRange or 200
	if gameAim then
		range = math.min(range, CONFIG.GAME_ASSIST_RANGE)
	end
	local count = Game.units.crowd(root.Position.X, root.Position.Z, range + 10, CONFIG.SCAN_MAX, crowd)
	local best, distance = pickTarget(root, range, count)
	if not best then
		state.targetPoint, state.enemyPoint = nil, nil
		tool:Deactivate()
		return
	end
	local point = crowdPoint(crowd, best)
	local velocity = Vector3.zero
	if state.targetId == crowd.id[best] and state.targetAt and now > state.targetAt then
		local measured = (point - state.lastTargetPoint) / (now - state.targetAt)
		if measured.Magnitude <= 80 then
			velocity = (state.targetVelocity or Vector3.zero):Lerp(measured, 0.45)
		end
	end
	state.targetId, state.lastTargetPoint, state.targetAt, state.targetVelocity = crowd.id[best], point, now, velocity
	state.enemyPoint, state.enemyHealth, state.distance = point, crowd.hp[best], distance
	-- Game assist: leave the aim point to the game's AimAssist (it keeps its own wall check and lead).
	state.targetPoint = not gameAim and point + velocity * math.min(distance / (projectile.speed or 200), 0.5) or nil
	if not enabled("AutoFight") then
		return
	end
	Game.gun:PushAim()
	local multiplier = rapidMultiplier()
	local interval = 60 / (projectile.roundsPerMinute or 60) / multiplier
	if now - state.lastFire >= math.max(CONFIG.MIN_FIRE_GAP / multiplier, interval) then
		tool:Activate()
		state.lastFire = now
		state.shots = (state.shots or 0) + 1
	end
end

-- End of run: press Replay the way the end screen does, re-arming the hub for the next server.
---@param humanoid Humanoid?
---@return boolean
local function replay(humanoid)
	local dead = localPlayer:GetAttribute("Dead") == true or (humanoid and humanoid.Health <= 0)
	local ended = Game.waves:GetAttribute("Phase") == "Complete"
	if not dead and not ended then
		return false
	end
	if not enabled("AutoReplay") then
		return true
	end
	local endGui = localPlayer.PlayerGui:FindFirstChild("End")
	local gameOver = endGui and endGui:FindFirstChild("GameOver")
	if not ended and not (endGui and endGui.Enabled and gameOver and gameOver.Visible) then
		return true
	end
	if enabled("ReExecute") and not state.teleportQueued then
		local queue = queue_on_teleport or getgenv().queueonteleport
		if queue then
			queue(CONFIG.REEXEC_SOURCE)
			if writefile then
				pcall(writefile, CONFIG.INTRO_STAMP_FILE, tostring(os.time()))
			end
			state.teleportQueued = true
		end
	end
	Net.fire("Replay", "GameAction", Game.gameActionRemote, "Replay")
	return true
end

---@param value any
---@return string
local function formatNumber(value)
	local digits = string.format("%.0f", math.max(0, tonumber(value) or 0))
	return (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

---@param now number
local function updateStatus(now)
	if now - state.lastStatus < 0.5 or not state.statusLabel then
		return
	end
	state.lastStatus = now
	local ok, data = pcall(Game.data.GetData, Game.data)
	local gems = ok and data and data.Gems or 0
	state.statusLabel:SetText(string.format(
		"Gems %s | run +%s\nWave %s | kills %s | monkeys %s\nTarget %s | shots %d\nBoss %s\nRemotes sent %d (vote %d, upg %d, abil %d, act %d)",
		formatNumber(gems),
		formatNumber(localPlayer:GetAttribute("RunGems")),
		tostring(Game.waves:GetAttribute("Number") or "-"),
		formatNumber(localPlayer:GetAttribute("Kills")),
		tostring(state.liveEnemies or 0),
		state.enemyHealth and string.format("%.0f hp @ %.0f", state.enemyHealth, state.distance or 0) or "none",
		state.shots or 0,
		state.bossName and string.format("%s (%s hp)", state.bossName, tostring(state.bossHealth)) or "none",
		Net.total,
		Net.counts.Vote or 0,
		Net.counts.Upgrade or 0,
		Net.counts.Ability or 0,
		Net.counts.GameAction or 0
	))
end

-- Main tick: one pcall per tick, ten errors in a row unloads the hub.
local function update()
	local now = os.clock()
	local character, humanoid, root = getCharacter()
	updateStatus(now)
	if replay(humanoid) then
		state.targetPoint = nil
		Flight.stop()
		return
	end
	if not humanoid or not root or humanoid.Health <= 0 then
		state.targetPoint = nil
		Flight.stop()
		return
	end
	if Game.cinematic.Filming() or root.Anchored then
		state.targetPoint = nil
		Flight.stop()
		return
	end
	survival(root, humanoid, now)
	adaptiveSkip(root, humanoid, now)
	upgrades()
	useClassSkills(root, humanoid, now)
	useUltimate(root, humanoid, now)
	autoTurret(root, now)
	if enabled("FlightOrbit") then
		Flight.orbit(humanoid, root, now)
	else
		if Flight.root then
			Flight.stop()
		end
		if not Chest.step(humanoid, root, now) then
			kite(humanoid, root)
		end
	end
	combat(humanoid, character, root, now)
end

-- ESP: Drawing pool fed straight from UnitViewController.crowd, so it costs no instances.
local Esp = { dots = {} }

function Esp.init()
	if not Drawing then
		return
	end
	for i = 1, CONFIG.ESP_MAX do
		local dot = Drawing.new("Circle")
		dot.Filled = true
		dot.NumSides = 12
		dot.Thickness = 1
		dot.Transparency = 1
		dot.Visible = false
		Esp.dots[i] = maid:give(dot)
	end
	Esp.boss = maid:give(Drawing.new("Text"))
	Esp.boss.Center = true
	Esp.boss.Outline = true
	Esp.boss.Size = 18
	Esp.boss.Color = Color3.fromRGB(255, 80, 80)
	Esp.boss.Visible = false
end

function Esp.hide(from)
	for i = from, #Esp.dots do
		Esp.dots[i].Visible = false
	end
end

function Esp.render()
	if not Drawing or not Esp.boss then
		return
	end
	local camera = workspace.CurrentCamera
	if not enabled("MonkeyEsp") or not camera then
		Esp.hide(1)
	else
		local focus = camera.CFrame.Position
		local count = Game.units.crowd(focus.X, focus.Z, CONFIG.ESP_RADIUS, CONFIG.ESP_MAX, espCrowd)
		local color = Options.EspColor and Options.EspColor.Value or Color3.fromRGB(255, 200, 60)
		local used = 0
		for i = 1, count do
			if espCrowd.hp[i] <= 0 then
				continue
			end
			local screen, onScreen = camera:WorldToViewportPoint(crowdPoint(espCrowd, i))
			if not onScreen then
				continue
			end
			used += 1
			local dot = Esp.dots[used]
			dot.Position = Vector2.new(screen.X, screen.Y)
			dot.Radius = math.clamp(300 / math.max(screen.Z, 1), 2, 9)
			dot.Color = espCrowd.id[i] == state.bossId and Color3.fromRGB(255, 60, 60) or color
			dot.Visible = true
		end
		Esp.hide(used + 1)
	end
	if not enabled("BossEsp") or not camera or not state.bossPoint then
		Esp.boss.Visible = false
		return
	end
	local screen, onScreen = camera:WorldToViewportPoint(state.bossPoint + Vector3.new(0, 8, 0))
	Esp.boss.Visible = onScreen
	Esp.boss.Position = Vector2.new(screen.X, screen.Y)
	Esp.boss.Text = string.format("%s  %s hp", tostring(state.bossName), tostring(state.bossHealth))
end

-- Local-only quality of life: fullbright, anti-AFK, walk speed, infinite jump.
local Misc = { lighting = nil }

---@param on boolean
function Misc.setFullbright(on)
	if on and not Misc.lighting then
		Misc.lighting = {
			Brightness = lightingService.Brightness,
			ClockTime = lightingService.ClockTime,
			FogEnd = lightingService.FogEnd,
			GlobalShadows = lightingService.GlobalShadows,
		}
		lightingService.Brightness = 3
		lightingService.ClockTime = 14
		lightingService.FogEnd = 1000000
		lightingService.GlobalShadows = false
	elseif not on and Misc.lighting then
		for property, value in Misc.lighting do
			lightingService[property] = value
		end
		Misc.lighting = nil
	end
end

function Misc.init()
	maid:give(localPlayer.Idled:Connect(function()
		if not enabled("AntiAfk") then
			return
		end
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new(0, 0))
	end))
	maid:give(userInputService.JumpRequest:Connect(function()
		if not enabled("InfiniteJump") then
			return
		end
		local _, humanoid = getCharacter()
		if humanoid then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end))
	maid:give(runService.Heartbeat:Connect(function()
		local _, humanoid = getCharacter()
		if not humanoid then
			return
		end
		if enabled("WalkSpeed") then
			Misc.baseSpeed = Misc.baseSpeed or humanoid.WalkSpeed
			humanoid.WalkSpeed = Options.WalkSpeedValue.Value
		elseif Misc.baseSpeed then
			humanoid.WalkSpeed = Misc.baseSpeed
			Misc.baseSpeed = nil
		end
	end))
end

-- Monkey colors offered by the ESP dropdown (replaces the Obsidian color picker).
local ESP_COLORS = {
	Gold = Color3.fromRGB(255, 200, 60),
	Red = Color3.fromRGB(255, 70, 90),
	Cyan = Color3.fromRGB(0, 212, 255),
	Purple = Color3.fromRGB(124, 92, 255),
	Green = Color3.fromRGB(80, 230, 130),
}

---@return table
local function readSettings()
	if not (isfile and readfile and isfile(CONFIG.SETTINGS_FILE)) then
		return {}
	end
	local ok, data = pcall(function()
		return game:GetService("HttpService"):JSONDecode(readfile(CONFIG.SETTINGS_FILE))
	end)
	return ok and type(data) == "table" and data or {}
end

-- The hypercar intro only plays when it hasn't been seen recently (the replay re-run skips it).
---@return boolean
local function shouldPlayIntro()
	if not (isfile and readfile and isfile(CONFIG.INTRO_STAMP_FILE)) then
		return true
	end
	local ok, stamp = pcall(function()
		return tonumber(readfile(CONFIG.INTRO_STAMP_FILE))
	end)
	return not ok or not stamp or os.time() - stamp > CONFIG.INTRO_COOLDOWN
end

-- Downloads ui.lua from the repo, falling back to a copy in the workspace.
local function loadUiLibrary()
	local ok, body = pcall(game.HttpGet, game, CONFIG.RAW_BASE .. CONFIG.UI_LIBRARY_FILE)
	if ok and type(body) == "string" and #body > 0 then
		return loadstring(body)()
	end
	assert(isfile and isfile(CONFIG.UI_LIBRARY_FILE), "could not download ui.lua and no local copy exists")
	return loadstring(readfile(CONFIG.UI_LIBRARY_FILE))()
end

local function buildUi()
	local ui = loadUiLibrary()
	local saved = readSettings()
	local introWanted = shouldPlayIntro()

	Toggles, Options = {}, {}
	local window = ui:CreateWindow({
		Title = "Monkey Hub",
		Subtitle = "Survive a Million Monkeys",
		Intro = introWanted,
	})

	-- Same surface the rest of the hub already uses (Library:Notify / Library.Unload).
	Library = {
		Notify = function(_, message, duration)
			window:Notify({ Title = "Monkey Hub", Text = tostring(message), Duration = duration or 4 })
		end,
		Unload = function()
			ui:Destroy()
		end,
	}

	-- Settings persist across the replay re-run (debounced write).
	local persistQueued = false
	local function persist()
		if persistQueued then
			return
		end
		persistQueued = true
		task.delay(1, function()
			persistQueued = false
			local data = {}
			for idx, toggle in Toggles do
				data[idx] = toggle.Value
			end
			for idx, option in Options do
				data[idx] = option.Raw
			end
			if makefolder then
				pcall(makefolder, "MonkeyHub")
				pcall(makefolder, "MonkeyHub/settings")
			end
			pcall(function()
				writefile(CONFIG.SETTINGS_FILE, game:GetService("HttpService"):JSONEncode(data))
			end)
		end)
	end

	local function addToggle(tab, idx, cfg)
		local entry = { Value = cfg.Default == true, Text = cfg.Text }
		Toggles[idx] = entry
		local control = tab:AddToggle({
			Text = cfg.Risky and (cfg.Text .. " (risky)") or cfg.Text,
			Default = entry.Value,
			Callback = function(on)
				entry.Value = on
				persist()
				if cfg.Callback then
					cfg.Callback(on)
				end
			end,
		})
		if type(saved[idx]) == "boolean" and saved[idx] ~= entry.Value then
			control:Set(saved[idx])
		end
	end

	local function addSlider(tab, idx, cfg)
		local entry = { Value = cfg.Default, Raw = cfg.Default }
		Options[idx] = entry
		local control = tab:AddSlider({
			Text = cfg.Text,
			Min = cfg.Min,
			Max = cfg.Max,
			Increment = cfg.Increment,
			Default = cfg.Default,
			Callback = function(value)
				entry.Value, entry.Raw = value, value
				persist()
			end,
		})
		if type(saved[idx]) == "number" and saved[idx] ~= entry.Value then
			control:Set(saved[idx])
		end
	end

	-- Values may be a list of names or a name -> Color3 map (read back as a Color3).
	local function addDropdown(tab, idx, cfg)
		local names = cfg.Values
		local entry = { Value = names[cfg.Default or 1], Raw = names[cfg.Default or 1] }
		Options[idx] = entry
		local control = tab:AddDropdown({
			Text = cfg.Text,
			Options = names,
			Default = entry.Raw,
			Callback = function(name)
				entry.Raw = name
				entry.Value = cfg.Map and cfg.Map[name] or name
				persist()
			end,
		})
		if cfg.Map then
			entry.Value = cfg.Map[entry.Raw]
		end
		if type(saved[idx]) == "string" and saved[idx] ~= entry.Raw and table.find(names, saved[idx]) then
			control:Set(saved[idx])
		end
	end

	window:CreateCategory("Gameplay")

	local combatTab = window:CreateTab("Combat")
	combatTab:AddSection("Targeting")
	addToggle(combatTab, "AutoFight", { Text = "Auto fight", Default = false })
	addToggle(combatTab, "AimAssist", { Text = "Aim assist (manual fire)", Default = false })
	addDropdown(combatTab, "AimMode", { Text = "Aim mode", Values = { "Game assist", "Override (risky)" }, Default = 1 })
	addSlider(combatTab, "AssistCone", { Text = "Assist cone (deg)", Default = 180, Min = 20, Max = 180 })
	addDropdown(combatTab, "TargetMode", { Text = "Target priority (override)", Values = { "Nearest", "Boss first", "Lowest HP" }, Default = 2 })
	addToggle(combatTab, "RequireSight", { Text = "Only through clear line of sight", Default = true })
	combatTab:AddSection("Skills")
	addToggle(combatTab, "AutoSkills", { Text = "Auto class skills", Default = false })
	addToggle(combatTab, "AutoUltimate", { Text = "Auto ultimate", Default = false })
	addToggle(combatTab, "AutoTurret", { Text = "Auto turret", Default = false })
	combatTab:AddSection("Fire rate")
	addToggle(combatTab, "RapidFire", { Text = "Rapid fire", Default = false, Risky = true })
	addSlider(combatTab, "RapidFireMult", { Text = "Fire rate multiplier", Default = 2, Min = 1, Max = 5, Increment = 0.5 })

	local survivalTab = window:CreateTab("Survival")
	survivalTab:AddSection("Dodging")
	addToggle(survivalTab, "AvoidHazards", { Text = "Dodge boss attacks / acid", Default = false })
	addToggle(survivalTab, "Kite", { Text = "Kite the swarm (walk)", Default = false })
	addSlider(survivalTab, "KiteDistance", { Text = "Kite distance", Default = 22, Min = 8, Max = 60 })
	survivalTab:AddSection("Flight")
	addToggle(survivalTab, "FlightOrbit", { Text = "Flight orbit farm", Default = false, Risky = true })
	addToggle(survivalTab, "FlightNoclip", { Text = "Noclip while flying", Default = false, Risky = true })
	addSlider(survivalTab, "FlightSpeed", { Text = "Flight speed", Default = 40, Min = 16, Max = 64 })

	local progressTab = window:CreateTab("Progress")
	progressTab:AddSection("Upgrades")
	addToggle(progressTab, "AutoUpgrade", { Text = "Auto upgrade (gun, then health)", Default = false })
	addToggle(progressTab, "AutoSkip", { Text = "Smart wave skip", Default = false })
	progressTab:AddSection("Loot")
	addToggle(progressTab, "AutoChest", { Text = "Auto open chests (walks there)", Default = false })
	addSlider(progressTab, "ChestReserve", { Text = "Keep cash reserve", Default = 0, Min = 0, Max = 2000 })
	progressTab:AddSection("Runs")
	addToggle(progressTab, "AutoReplay", { Text = "Auto replay", Default = false })
	addToggle(progressTab, "ReExecute", { Text = "Re-run hub after replay teleport", Default = true })

	local statusTab = window:CreateTab("Status")
	statusTab:AddSection("Run")
	state.statusLabel = statusTab:AddLabel("Loading...")

	window:CreateCategory("Visuals")

	local espTab = window:CreateTab("ESP")
	espTab:AddSection("Monkeys")
	addToggle(espTab, "MonkeyEsp", { Text = "Monkey ESP", Default = false })
	addDropdown(espTab, "EspColor", {
		Text = "Monkey color",
		Values = { "Gold", "Red", "Cyan", "Purple", "Green" },
		Default = 1,
		Map = ESP_COLORS,
	})
	espTab:AddSection("Bosses")
	addToggle(espTab, "BossEsp", { Text = "Boss ESP", Default = true })

	local worldTab = window:CreateTab("World")
	worldTab:AddSection("Lighting")
	addToggle(worldTab, "Fullbright", { Text = "Fullbright", Default = false, Callback = Misc.setFullbright })

	window:CreateCategory("Player")

	local moveTab = window:CreateTab("Movement")
	moveTab:AddSection("Utility")
	addToggle(moveTab, "AntiAfk", { Text = "Anti-AFK", Default = true })
	moveTab:AddSection("Movement")
	addToggle(moveTab, "WalkSpeed", { Text = "Walk speed", Default = false, Risky = true })
	addSlider(moveTab, "WalkSpeedValue", { Text = "Speed", Default = 22, Min = 16, Max = 40 })
	addToggle(moveTab, "InfiniteJump", { Text = "Infinite jump", Default = false, Risky = true })

	window:CreateCategory("System")

	local settingsTab = window:CreateTab("Settings")
	settingsTab:AddSection("Menu")
	settingsTab:AddLabel("RightCtrl opens and closes the menu.")
	settingsTab:AddButton({
		Text = "Unload",
		Callback = function()
			MonkeyHub.detach()
		end,
	})

	-- RightCtrl shows / hides the window.
	maid:give(userInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.RightControl and not userInputService:GetFocusedTextBox() then
			window:Toggle()
		end
	end))
end

-- Aim override is registered once per session; the game keeps it, so it reads the live hub.
local function hookAim()
	if MonkeyHub.aimHooked then
		return
	end
	MonkeyHub.aimHooked = true
	Game.gun.AddAimOverride(function()
		local hub = shared.MonkeyHub
		if not hub or not hub.running or not hub.aimPoint then
			return nil
		end
		return hub.aimPoint()
	end)
	-- Same hook Ricochet uses: returning a cone cosine makes the game's AimAssist pick the target.
	Game.gun.AddAutoTarget(function()
		local hub = shared.MonkeyHub
		if not hub or not hub.running or not hub.autoCone then
			return nil
		end
		return hub.autoCone()
	end)
end

---@return Vector3?
function MonkeyHub.aimPoint()
	return state.skillAimPoint or state.targetPoint
end

---@return number?
function MonkeyHub.autoCone()
	if not Options or Options.AimMode.Value ~= "Game assist" then
		return nil
	end
	if not enabled("AutoFight") and not enabled("AimAssist") then
		return nil
	end
	return math.cos(math.rad(Options.AssistCone.Value))
end

local function waitForClient()
	local deadline = os.clock() + CONFIG.READY_TIMEOUT
	while localPlayer:GetAttribute("ClientReady") ~= true do
		assert(os.clock() < deadline, "ClientReady never set")
		task.wait(0.2)
	end
end

---@param message any
local function onInitError(message)
	warn("[MonkeyHub] init failed:", message, debug.traceback())
	pcall(MonkeyHub.detach)
end

function MonkeyHub.detach()
	if not MonkeyHub.running then
		return
	end
	MonkeyHub.running = false
	if state.skipOwned and Game.voteRemote and localPlayer:GetAttribute("AutoSkip") == true then
		pcall(Game.voteRemote.FireServer, Game.voteRemote, "Auto", false)
	end
	if state.tool then
		pcall(state.tool.Deactivate, state.tool)
	end
	state.targetPoint, state.skillAimPoint = nil, nil
	pcall(Flight.stop)
	pcall(Misc.setFullbright, false)
	if state.buffs and state.originalFireRate then
		pcall(function()
			state.buffs.fireRate = state.originalFireRate
		end)
		state.originalFireRate = false
	end
	maid:clean()
	if Library then
		pcall(Library.Unload, Library)
	end
end

function MonkeyHub.init()
	assert(game.PlaceId == MATCH_PLACE_ID, game.PlaceId == LOBBY_PLACE_ID and "start a run first; the hub runs inside a match" or "wrong game")
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	waitForClient()
	loadGame()
	MonkeyHub.running = true
	hookHazards()
	hookAim()
	hookRapidFire()
	buildUi()
	Esp.init()
	Misc.init()
	maid:give(runService.RenderStepped:Connect(Esp.render))
	local elapsed = 0
	maid:give(runService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < (state.bossId and CONFIG.BOSS_TICK_RATE or CONFIG.TICK_RATE) then
			return
		end
		elapsed = 0
		local ok, err = pcall(update)
		if ok then
			state.errors = 0
			return
		end
		state.errors += 1
		if state.errors <= 3 then
			warn("[MonkeyHub]", err)
		end
		if state.errors >= 10 then
			Library:Notify("Monkey Hub stopped after repeated errors: " .. tostring(err), 8)
			MonkeyHub.detach()
		end
	end))
	Library:Notify("Monkey Hub loaded. RightCtrl toggles the menu.", 5)
end

-- Singleton: unload any previous copy and keep its one-time aim hook.
if shared.MonkeyHub then
	MonkeyHub.aimHooked = shared.MonkeyHub.aimHooked
	pcall(shared.MonkeyHub.detach)
end
shared.MonkeyHub = MonkeyHub

xpcall(MonkeyHub.init, onInitError)
