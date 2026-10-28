--[[
	ui.lua - premium UI library: hypercar intro -> loading screen -> main window.
	Single file, no require(). Returns the library table.

	Executor functions used (all optional, all pcall'd): gethui, getcustomasset, getsynasset, isfile.
	Audio: workspace/intro.mp3 (missing file or missing functions = intro plays silently).
]]

-- Services.
local tweenService = game:GetService("TweenService")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")
local playersService = game:GetService("Players")
local coreGuiService = game:GetService("CoreGui")
local soundService = game:GetService("SoundService")

-- Constants.
local GUI_NAME = "PremiumUI"
local INTRO_GUI_NAME = "PremiumUI_Intro"
local LOADING_GUI_NAME = "PremiumUI_Loading"
local AUDIO_FILE = "intro.mp3"
local FONT_FAMILY = "rbxasset://fonts/families/GothamSSm.json"

local COLORS = {
	accent = Color3.fromHex("#7C5CFF"),
	cyan = Color3.fromHex("#00D4FF"),
	background = Color3.fromHex("#0E0E12"),
	surface = Color3.fromHex("#17171D"),
	raised = Color3.fromHex("#1F1F27"),
	text = Color3.fromHex("#F2F2F5"),
	muted = Color3.fromHex("#8A8A99"),
	white = Color3.new(1, 1, 1),
	black = Color3.new(0, 0, 0),
}

local ACCENT_SEQUENCE = ColorSequence.new(COLORS.accent, COLORS.cyan)

local TEXT_TITLE = 22
local TEXT_HEADING = 16
local TEXT_BODY = 14

local RADIUS_CARD = 12
local RADIUS_CONTROL = 8
local RADIUS_PILL = 999

local STROKE_THICKNESS = 1.5
local STROKE_IDLE = 0.7

local WINDOW_WIDTH = 640
local WINDOW_HEIGHT = 420
local SIDEBAR_WIDTH = 170
local HEADER_HEIGHT = 64
local SIDEBAR_FOOTER = 56
-- Far above any game interface: lower values let the game's own layers swallow clicks on the window.
local DISPLAY_MAIN = 100000
local DISPLAY_LOADING = 100900
local DISPLAY_INTRO = 101000

local fontBold = Font.new(FONT_FAMILY, Enum.FontWeight.Bold)
local fontMedium = Font.new(FONT_FAMILY, Enum.FontWeight.Medium)

local TWEEN_UI = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TWEEN_POP = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TWEEN_PRESS = TweenInfo.new(0.1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- State.
local UI = {
	Version = "1.0.0",
	_windows = {},
	_cleanups = {},
	_connections = {},
	Flags = {},
	_capturing = false,
	_ready = false,
	_destroyed = false,
	_pendingNotifications = {},
}
local Window = {}
Window.__index = Window
local Tab = {}
Tab.__index = Tab

local guiParent = nil
local mainGui = nil
local notificationHolder = nil
local notificationOrder = 0

---@param err any
local function onError(err)
	warn("[PremiumUI] " .. tostring(err) .. "\n" .. debug.traceback())
end

---@param fn function|nil
local function safeCall(fn, ...)
	if type(fn) ~= "function" then
		return
	end

	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[PremiumUI] callback error: " .. tostring(err))
	end
end

-- Registers a global signal connection so UI:Destroy can always disconnect it.
---@return RBXScriptConnection
local function connect(signal, fn)
	local connection = signal:Connect(fn)
	UI._connections[connection] = true
	return connection
end

---@param connection RBXScriptConnection
local function disconnect(connection)
	if not connection then
		return
	end

	UI._connections[connection] = nil
	connection:Disconnect()
end

-- Registers a component in UI.Flags. The flag defaults to "<Tab>_<Text>"; config.NoFlag skips registration.
---@return table
local function registerFlag(tab, config, kind, initial)
	if config.NoFlag then
		return { Type = kind, Value = initial }
	end

	local base = tostring(config.Flag or (tab.Name .. "_" .. tostring(config.Text or kind)))
	local flag, suffix = base, 1
	while UI.Flags[flag] do
		suffix += 1
		flag = base .. "_" .. suffix
	end

	local entry = { Flag = flag, Type = kind, Value = initial }
	UI.Flags[flag] = entry
	return entry
end

-- KeyCode, KeyCode name or nil ("None") -> KeyCode or nil.
---@return EnumItem?
local function resolveKey(value)
	if typeof(value) == "EnumItem" then
		return value
	end
	if type(value) == "string" and value ~= "None" then
		local ok, key = pcall(function()
			return Enum.KeyCode[value]
		end)
		if ok then
			return key
		end
	end
	return nil
end

-- File functions are executor-only: all six must exist or configs are unsupported.
---@return table?
local function resolveFileApi()
	local api = {}
	pcall(function()
		api.makefolder, api.isfolder, api.writefile = makefolder, isfolder, writefile
		api.readfile, api.listfiles, api.delfile = readfile, listfiles, delfile
	end)

	for _, name in ipairs({ "makefolder", "isfolder", "writefile", "readfile", "listfiles", "delfile" }) do
		if type(api[name]) ~= "function" then
			return nil
		end
	end
	return api
end

-- Snapshot of every flag as JSON-safe values (KeyCodes become their .Name).
---@return table
local function encodeFlags()
	local data = {}
	for flag, entry in pairs(UI.Flags) do
		local value = entry.Value
		if typeof(value) == "EnumItem" then
			value = value.Name
		elseif value == nil and entry.Type == "Keybind" then
			value = "None"
		end
		if value ~= nil then
			data[flag] = value
		end
	end
	return data
end

-- Builds an instance from a property table, parenting last.
---@return Instance
local function create(className, props, children)
	local object = Instance.new(className)
	local parent = nil

	for key, value in pairs(props or {}) do
		if key == "Parent" then
			parent = value
			continue
		end

		object[key] = value
	end

	for _, child in ipairs(children or {}) do
		child.Parent = object
	end

	if parent then
		object.Parent = parent
	end

	return object
end

---@return Tween
local function tween(object, info, props)
	local playing = tweenService:Create(object, info, props)
	playing:Play()
	return playing
end

---@return Color3
local function brighten(color, amount)
	return color:Lerp(COLORS.white, amount)
end

local function addCorner(parent, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

-- Accent outline: 1.5 px UIStroke with a purple -> cyan UIGradient.
---@return UIStroke, UIGradient
local function addStroke(parent, transparency)
	local stroke = create("UIStroke", {
		Thickness = STROKE_THICKNESS,
		Color = COLORS.white,
		Transparency = transparency or STROKE_IDLE,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = parent,
	})
	local gradient = create("UIGradient", { Color = ACCENT_SEQUENCE, Rotation = 45, Parent = stroke })
	return stroke, gradient
end

local function addAccentGradient(parent, rotation)
	return create("UIGradient", { Color = ACCENT_SEQUENCE, Rotation = rotation or 0, Parent = parent })
end

---@return TextLabel
local function newLabel(props)
	local merged = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		FontFace = fontMedium,
		TextSize = TEXT_BODY,
		TextColor3 = COLORS.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}

	for key, value in pairs(props) do
		merged[key] = value
	end

	return create("TextLabel", merged)
end

---@param value number|function
local function resolve(value)
	if type(value) == "function" then
		return value()
	end

	return value
end

-- 4% brighter background and a fully opaque stroke while hovered.
local function bindHover(object, stroke, idle, getBase)
	local base = object.BackgroundColor3
	getBase = getBase or function()
		return base
	end

	object.MouseEnter:Connect(function()
		tween(object, TWEEN_UI, { BackgroundColor3 = brighten(getBase(), 0.04) })
		if stroke then
			tween(stroke, TWEEN_UI, { Transparency = 0 })
		end
	end)

	object.MouseLeave:Connect(function()
		tween(object, TWEEN_UI, { BackgroundColor3 = getBase() })
		if stroke then
			tween(stroke, TWEEN_UI, { Transparency = resolve(idle) })
		end
	end)
end

-- Click scales to 0.96 and springs back.
---@return UIScale
local function bindPress(button, target)
	local scale = create("UIScale", { Parent = target or button })

	local function release()
		tween(scale, TWEEN_POP, { Scale = 1 })
	end

	button.MouseButton1Down:Connect(function()
		tween(scale, TWEEN_PRESS, { Scale = 0.96 })
	end)
	button.MouseButton1Up:Connect(release)
	button.MouseLeave:Connect(release)

	return scale
end

-- Parents the GUI to gethui(), else CoreGui, else PlayerGui.
---@return Instance
local function getGuiParent()
	if guiParent then
		return guiParent
	end

	local okHui, hui = pcall(function()
		return gethui()
	end)
	if okHui and typeof(hui) == "Instance" then
		guiParent = hui
		return guiParent
	end

	local okCore = pcall(function()
		local probe = Instance.new("Folder")
		probe.Parent = coreGuiService
		probe:Destroy()
	end)
	if okCore then
		guiParent = coreGuiService
		return guiParent
	end

	if not playersService.LocalPlayer then
		playersService:GetPropertyChangedSignal("LocalPlayer"):Wait()
	end
	guiParent = playersService.LocalPlayer:WaitForChild("PlayerGui")
	return guiParent
end

-- Removes leftovers from an earlier load before anything is created.
local function destroyPrevious()
	local containers = {}

	local okHui, hui = pcall(function()
		return gethui()
	end)
	if okHui and typeof(hui) == "Instance" then
		table.insert(containers, hui)
	end

	table.insert(containers, coreGuiService)

	local player = playersService.LocalPlayer
	local playerGui = player and player:FindFirstChild("PlayerGui")
	if playerGui then
		table.insert(containers, playerGui)
	end

	for _, container in ipairs(containers) do
		pcall(function()
			for _, child in ipairs(container:GetChildren()) do
				if child.Name == GUI_NAME or child.Name == INTRO_GUI_NAME or child.Name == LOADING_GUI_NAME then
					child:Destroy()
				end
			end
		end)
	end
end

---@return ScreenGui
local function newScreenGui(name, displayOrder)
	return create("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = displayOrder,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = getGuiParent(),
	})
end

---@return Vector2
local function getViewport(gui)
	local size = gui.AbsoluteSize
	if size.X >= 100 and size.Y >= 100 then
		return size
	end

	local camera = workspace.CurrentCamera
	if camera then
		return camera.ViewportSize
	end

	return Vector2.new(1280, 720)
end

---@return string|nil
local function resolveAudio()
	local okFile, exists = pcall(function()
		return isfile(AUDIO_FILE)
	end)
	if okFile and exists == false then
		return nil
	end

	local ok, asset = pcall(function()
		return getcustomasset(AUDIO_FILE)
	end)
	if ok and type(asset) == "string" and asset ~= "" then
		return asset
	end

	ok, asset = pcall(function()
		return getsynasset(AUDIO_FILE)
	end)
	if ok and type(asset) == "string" and asset ~= "" then
		return asset
	end

	return nil
end

-- Parents the Sound before anything else, waits off the timeline for it to load, then plays and fades it in over 0.5 s.
-- If it never loads (bad asset) the intro simply stays silent.
local function startMusic(sound, assetId, isCancelled, play)
	local okSet = pcall(function()
		sound.SoundId = assetId
		sound.Parent = soundService
	end)
	if not okSet then
		return
	end

	task.spawn(function()
		local started = os.clock()
		while not sound.IsLoaded and os.clock() - started < 3 do
			if isCancelled() then
				return
			end
			task.wait()
		end
		if isCancelled() or not sound.IsLoaded then
			return
		end

		pcall(function()
			sound:Play()
		end)
		play(sound, TweenInfo.new(0.5, Enum.EasingStyle.Linear), { Volume = 0.7 })
	end)
end

-- Panel: a rounded CanvasGroup surface with a sibling stroke border (so the stroke is not clipped),
-- an optional stacked-frame drop shadow, and a UIScale for the pop-in.
local function makePanel(parent, name, size, color, withShadow)
	local holder = create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = size,
		BackgroundTransparency = 1,
		Parent = parent,
	})
	local pop = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	local scale = create("UIScale", { Parent = pop })

	local shadow = nil
	if withShadow then
		local pad = 48
		shadow = create("CanvasGroup", {
			Name = "Shadow",
			Position = UDim2.fromOffset(-pad, -pad),
			Size = UDim2.new(1, pad * 2, 1, pad * 2),
			BackgroundTransparency = 1,
			Parent = pop,
		})

		-- Stacked transparent frames fake a blurred shadow.
		for layer = 1, 8 do
			local grow = layer * 4
			local inset = pad * 2 - grow * 2
			local frame = create("Frame", {
				Position = UDim2.fromOffset(pad - grow, pad - grow + 10),
				Size = UDim2.new(1, -inset, 1, -inset),
				BackgroundColor3 = COLORS.black,
				BackgroundTransparency = 0.93,
				BorderSizePixel = 0,
				Parent = shadow,
			})
			addCorner(frame, RADIUS_CARD + grow)
		end
	end

	local group = create("CanvasGroup", {
		Name = "Surface",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = pop,
	})
	addCorner(group, RADIUS_CARD)

	local border = create("Frame", {
		Name = "Border",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = pop,
	})
	addCorner(border, RADIUS_CARD)
	local stroke, gradient = addStroke(border, 0.15)

	return {
		holder = holder,
		scale = scale,
		group = group,
		shadow = shadow,
		stroke = stroke,
		gradient = gradient,
	}
end

local function panelIn(panel)
	panel.scale.Scale = 0.88
	panel.group.GroupTransparency = 1
	panel.stroke.Transparency = 1
	if panel.shadow then
		panel.shadow.GroupTransparency = 1
		tween(panel.shadow, TWEEN_UI, { GroupTransparency = 0 })
	end

	tween(panel.scale, TWEEN_POP, { Scale = 1 })
	tween(panel.group, TWEEN_UI, { GroupTransparency = 0 })
	tween(panel.stroke, TWEEN_UI, { Transparency = 0.15 })
end

local function panelOut(panel)
	tween(panel.scale, TWEEN_UI, { Scale = 0.94 })
	tween(panel.group, TWEEN_UI, { GroupTransparency = 1 })
	tween(panel.stroke, TWEEN_UI, { Transparency = 1 })
	if panel.shadow then
		tween(panel.shadow, TWEEN_UI, { GroupTransparency = 1 })
	end
end

-- Two thin rotated bars make a close "x".
local function drawCross(parent, color)
	for _, rotation in ipairs({ 45, -45 }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(14, 2),
			Rotation = rotation,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = parent,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	end
end

-- Two rotated bars make a down chevron (Gotham has no arrow glyph).
---@return Frame
local function drawChevron(parent, color)
	local chevron = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(14, 14),
		BackgroundTransparency = 1,
		Parent = parent,
	})

	for _, arm in ipairs({ { 4.2, 45 }, { 9.8, -45 } }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(arm[1], 6),
			Size = UDim2.fromOffset(8, 2),
			Rotation = arm[2],
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = chevron,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	end

	return chevron
end

-- ---------------------------------------------------------------------------
-- Hypercar built only from Frames, rotated Frames and UICorner.
-- ---------------------------------------------------------------------------

local CAR_WIDTH = 400
local CAR_HEIGHT = 120

---@return table
local function buildCar(parent)
	local root = create("Frame", {
		Name = "Hypercar",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(CAR_WIDTH, CAR_HEIGHT),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = parent,
	})
	local scale = create("UIScale", { Parent = root })
	local chassis = create("Frame", {
		Name = "Chassis",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = root,
	})

	local bodyTop = Color3.fromRGB(58, 58, 82)
	local bodyBottom = Color3.fromRGB(14, 14, 20)

	-- One body panel: dark vertical gradient so the silhouette reads on black.
	local function part(name, x, y, w, h, radius, z, rotation, rimmed)
		local frame = create("Frame", {
			Name = name,
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(w, h),
			Rotation = rotation or 0,
			BackgroundColor3 = COLORS.white,
			BorderSizePixel = 0,
			ZIndex = z,
			Parent = chassis,
		})
		addCorner(frame, radius)
		create("UIGradient", {
			Color = ColorSequence.new(bodyTop, bodyBottom),
			Rotation = 90,
			Parent = frame,
		})

		if rimmed then
			addStroke(frame, 0.55)
		end

		return frame
	end

	local function plain(name, x, y, w, h, color, radius, z, rotation)
		local frame = create("Frame", {
			Name = name,
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(w, h),
			Rotation = rotation or 0,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = z,
			Parent = chassis,
		})
		if radius then
			addCorner(frame, radius)
		end
		return frame
	end

	-- Underglow on the road.
	local glow = plain("Underglow", 40, 102, 320, 14, COLORS.accent, RADIUS_PILL, 1)
	create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = glow,
	})

	-- Rear wing: strut, blade, endplate.
	part("WingStrut", 38, 30, 7, 26, 3, 1)
	local blade = plain("WingBlade", 4, 22, 96, 7, COLORS.white, 3, 4, -2)
	addAccentGradient(blade, 0)
	part("WingEndplate", 6, 12, 6, 24, 3, 4, 0, true)

	-- Cabin bubble sits behind the body so only the dome shows.
	part("Cabin", 118, 22, 136, 40, RADIUS_PILL, 2, 0, true)
	local glass = plain("Glass", 134, 29, 104, 24, COLORS.cyan, RADIUS_PILL, 3)
	create("UIGradient", {
		Color = ColorSequence.new(COLORS.cyan, COLORS.accent),
		Transparency = NumberSequence.new(0.55, 0.8),
		Rotation = 20,
		Parent = glass,
	})

	-- Body slab, low wedge nose, skirt.
	part("Body", 10, 52, 290, 40, 12, 4, 0, true)
	part("Nose", 235, 59, 140, 26, 10, 4, 7, true)
	part("Skirt", 40, 86, 320, 12, 6, 3)

	-- Accent stripe along the flank.
	local stripe = plain("Stripe", 58, 66, 280, 3, COLORS.white, 2, 6, 3)
	addAccentGradient(stripe, 0)

	-- Taillight.
	plain("Taillight", 8, 58, 8, 14, Color3.fromRGB(255, 50, 90), 4, 6)

	-- Wheels: wheel arch cut-out, tyre, rim, spinning spokes, hub.
	local spokes = {}
	local function wheel(cx, cy)
		plain("Arch", cx - 30, cy - 30, 60, 60, COLORS.black, RADIUS_PILL, 5)

		local tyre = plain("Tyre", cx - 24, cy - 24, 48, 48, Color3.fromRGB(10, 10, 13), RADIUS_PILL, 6)
		create("UIStroke", {
			Thickness = 3,
			Color = Color3.fromRGB(70, 70, 86),
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = tyre,
		})

		plain("Rim", cx - 16, cy - 16, 32, 32, Color3.fromRGB(34, 34, 46), RADIUS_PILL, 7)

		local spin = create("Frame", {
			Name = "Spokes",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(cx, cy),
			Size = UDim2.fromOffset(32, 32),
			BackgroundTransparency = 1,
			ZIndex = 8,
			Parent = chassis,
		})
		for index = 0, 4 do
			create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(30, 3),
				Rotation = index * 36,
				BackgroundColor3 = Color3.fromRGB(205, 205, 220),
				BorderSizePixel = 0,
				ZIndex = 8,
				Parent = spin,
			}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		end

		plain("Hub", cx - 4, cy - 4, 8, 8, COLORS.accent, RADIUS_PILL, 9)
		table.insert(spokes, spin)
	end
	wheel(84, 90)
	wheel(296, 90)

	-- Headlight: lens, glow (two crossed gradients), anamorphic flare, beam.
	plain("Lens", 364, 74, 26, 7, COLORS.white, RADIUS_PILL, 10, 7)

	local glowSequence = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	local glowA = plain("HeadGlowA", 352, 54, 52, 52, COLORS.white, RADIUS_PILL, 9)
	create("UIGradient", { Transparency = glowSequence, Parent = glowA })
	local glowB = plain("HeadGlowB", 352, 54, 52, 52, COLORS.white, RADIUS_PILL, 9)
	create("UIGradient", { Transparency = glowSequence, Rotation = 90, Parent = glowB })

	local flare = plain("Flare", 248, 76, 300, 3, COLORS.white, 2, 10, 7)
	create("UIGradient", { Transparency = glowSequence, Parent = flare })

	local beam = plain("Beam", 388, 52, 520, 58, COLORS.white, 28, 1, 5)
	create("UIGradient", { Transparency = NumberSequence.new(0.55, 1), Parent = beam })

	-- Nitro flame out of the rear.
	local flame = create("Frame", {
		Name = "Flame",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromOffset(12, 80),
		Size = UDim2.fromOffset(0, 14),
		BackgroundColor3 = COLORS.white,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = chassis,
	})
	addCorner(flame, 7)
	create("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, COLORS.accent),
			ColorSequenceKeypoint.new(0.5, COLORS.cyan),
			ColorSequenceKeypoint.new(1, COLORS.white),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.6, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = flame,
	})

	return {
		root = root,
		scale = scale,
		chassis = chassis,
		spokes = spokes,
		glowA = glowA,
		glowB = glowB,
		flare = flare,
		beam = beam,
		flame = flame,
	}
end

-- ---------------------------------------------------------------------------
-- Intro
-- ---------------------------------------------------------------------------

-- Plays the intro and returns a finish() closure that destroys everything. Blocks until the animation ends.
---@return function
local function playIntro()
	local connections = {}
	local tweens = {}
	local lines = {}
	local skipped = false
	local clock = 0
	local cleaned = false

	local gui = newScreenGui(INTRO_GUI_NAME, DISPLAY_INTRO)
	local viewport = getViewport(gui)
	local unit = math.clamp(viewport.X / 1100, 0.55, 1.4)

	local sound = Instance.new("Sound")
	sound.Name = "PremiumUI_IntroMusic"
	sound.Volume = 0
	sound.Looped = false

	local function play(object, info, props)
		local playing = tween(object, info, props)
		table.insert(tweens, playing)
		return playing
	end

	-- Idempotent: disconnects every connection, cancels tweens, destroys every intro object.
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true

		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		table.clear(connections)

		for _, running in ipairs(tweens) do
			pcall(function()
				running:Cancel()
			end)
		end
		table.clear(tweens)
		table.clear(lines)

		pcall(function()
			sound:Stop()
		end)
		sound:Destroy()
		gui:Destroy()
	end
	table.insert(UI._cleanups, cleanup)

	-- Layers: black backdrop, shaken stage, beat flash, launch flash, closing curtain.
	create("Frame", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.black,
		BorderSizePixel = 0,
		Parent = gui,
	})
	local stage = create("Frame", {
		Name = "Stage",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 1,
		Parent = gui,
	})
	local flashBeat = create("Frame", {
		Name = "FlashBeat",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.white,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = gui,
	})
	local flashKick = create("Frame", {
		Name = "FlashKick",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.white,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = gui,
	})
	local curtain = create("Frame", {
		Name = "Curtain",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 7,
		Parent = gui,
	})

	local lineLayer = create("Frame", {
		Name = "SpeedLines",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 1,
		Parent = stage,
	})

	-- Ground line under the wheels.
	local groundY = viewport.Y * 0.58 + 53 * unit
	local ground = create("Frame", {
		Name = "Ground",
		Position = UDim2.fromOffset(0, groundY),
		Size = UDim2.new(1, 0, 0, 2),
		BackgroundColor3 = COLORS.white,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = stage,
	})
	create("UIGradient", {
		Color = ACCENT_SEQUENCE,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = ground,
	})

	local car = buildCar(stage)
	car.scale.Scale = unit
	car.root.Position = UDim2.fromScale(-0.3, 0.58)

	-- Title: slam scale on the holder, beat pulse on the inner holder, chromatic copies inside.
	local titleSize = math.clamp(math.floor(viewport.X / 22), 26, 56)
	local titleText = "HYPERCAR"
	if UI._windows[1] and UI._windows[1].Title then
		titleText = string.upper(UI._windows[1].Title)
	end

	local titleHolder = create("Frame", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.27),
		Size = UDim2.new(0.92, 0, 0, 84),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = stage,
	})
	local slamScale = create("UIScale", { Scale = 1.4, Parent = titleHolder })
	local pulseHolder = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = titleHolder,
	})
	local pulseScale = create("UIScale", { Parent = pulseHolder })

	local function titleLabel(color, z)
		return newLabel({
			Size = UDim2.fromScale(1, 1),
			Text = titleText,
			FontFace = fontBold,
			TextSize = titleSize,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTransparency = 1,
			ZIndex = z,
			Parent = pulseHolder,
		})
	end
	local titleRed = titleLabel(Color3.fromRGB(255, 40, 80), 1)
	local titleCyan = titleLabel(COLORS.cyan, 2)
	local titleMain = titleLabel(COLORS.white, 3)
	titleRed.Position = UDim2.fromOffset(-2, 0)
	titleCyan.Position = UDim2.fromOffset(2, 0)

	local subtitle = newLabel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.27, titleSize * 0.8 + 10),
		Size = UDim2.new(0.8, 0, 0, 24),
		Text = UI._windows[1] and UI._windows[1].Subtitle or "",
		TextColor3 = COLORS.muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		ZIndex = 5,
		Parent = stage,
	})

	-- Skip button (bottom-right) and Space.
	local skipButton = create("TextButton", {
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -24),
		Size = UDim2.fromOffset(132, 38),
		AutoButtonColor = false,
		Text = "Skip  ·  Space",
		FontFace = fontMedium,
		TextSize = TEXT_BODY,
		TextColor3 = COLORS.text,
		BackgroundColor3 = COLORS.raised,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ZIndex = 8,
		Parent = gui,
	})
	addCorner(skipButton, RADIUS_CONTROL)
	local skipStroke = addStroke(skipButton, STROKE_IDLE)
	bindHover(skipButton, skipStroke, STROKE_IDLE)
	bindPress(skipButton)
	skipButton.Activated:Connect(function()
		skipped = true
	end)

	table.insert(
		connections,
		userInputService.InputBegan:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.Space and not userInputService:GetFocusedTextBox() then
				skipped = true
			end
		end)
	)

	-- Audio: silent fallback if there is no asset function or no file.
	local assetId = resolveAudio()
	if assetId then
		startMusic(sound, assetId, function()
			return cleaned
		end, play)
	end

	-- Frame loop state.
	local level = 0
	local kick = 0
	local shakeEnd = -1
	local lightTarget = 0.25
	local light = 0
	local flameTarget = 0
	local flameLength = 0
	local lineSpeed = 1500
	local lineTarget = 2800
	local spawnAccumulator = 0
	local wheelAngle = 0
	local lastCarX = nil
	local random = Random.new()

	local function spawnLine()
		local width = (80 + random:NextNumber() * 260) * unit * (0.5 + math.min(lineSpeed, 6000) / 3000)
		local height = random:NextInteger(1, 3)
		local y = random:NextNumber() * viewport.Y

		local mix = random:NextNumber()
		local color = mix < 0.5 and COLORS.white or (mix < 0.75 and COLORS.cyan or COLORS.accent)

		local line = create("Frame", {
			Size = UDim2.fromOffset(width, height),
			Position = UDim2.fromOffset(viewport.X + 20, y),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = lineLayer,
		})
		create("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.05),
				NumberSequenceKeypoint.new(0.4, 0.5),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = line,
		})

		table.insert(lines, {
			object = line,
			x = viewport.X + 20,
			y = y,
			width = width,
			factor = 0.7 + random:NextNumber() * 0.6,
		})
	end

	table.insert(
		connections,
		runService.RenderStepped:Connect(function(dt)
			clock += dt

			-- Beat: real loudness when audio plays, a soft synthetic pulse otherwise.
			local raw
			if assetId and sound.IsPlaying then
				raw = math.clamp(sound.PlaybackLoudness / 500, 0, 1)
			else
				local phase = (clock * 2) % 1
				raw = (clock > 0.4 and phase < 0.15) and (1 - phase / 0.15) * 0.7 or 0
			end
			level = math.max(raw, level - dt * 3)
			kick = math.max(0, kick - dt * 2.2)

			-- Visuals that hit on the beat (flash kept subtle: 10% on beat, 55% once at launch).
			pulseScale.Scale = 1 + level * 0.07
			flashBeat.BackgroundTransparency = 1 - level * 0.1
			flashKick.BackgroundTransparency = 1 - kick * 0.55
			ground.BackgroundTransparency = 0.5 - level * 0.4

			light += (lightTarget - light) * math.min(1, dt * 3)
			local intensity = math.clamp(light + level * 0.3, 0, 1)
			car.beam.BackgroundTransparency = 1 - intensity * 0.9
			car.flare.BackgroundTransparency = 1 - intensity
			car.glowA.BackgroundTransparency = 1 - intensity
			car.glowB.BackgroundTransparency = 1 - intensity

			flameLength += (flameTarget - flameLength) * math.min(1, dt * 8)
			car.flame.Size = UDim2.fromOffset(flameLength, 14 + level * 5)

			-- Screen shake on launch: 2 to 4 px.
			if clock < shakeEnd then
				local amount = 2 + random:NextNumber() * 2
				stage.Position = UDim2.fromOffset(
					(random:NextNumber() * 2 - 1) * amount,
					(random:NextNumber() * 2 - 1) * amount
				)
			else
				stage.Position = UDim2.fromOffset(0, 0)
			end

			-- Engine vibration.
			car.chassis.Position = UDim2.fromOffset(0, math.sin(clock * 40) * level * 1.5)

			-- Speed lines.
			lineSpeed += (lineTarget - lineSpeed) * math.min(1, dt * 5)
			spawnAccumulator += dt * (6 + lineSpeed / 90)
			while spawnAccumulator >= 1 do
				spawnAccumulator -= 1
				if #lines < 90 then
					spawnLine()
				end
			end
			for index = #lines, 1, -1 do
				local line = lines[index]
				line.x -= lineSpeed * line.factor * dt
				line.object.Position = UDim2.fromOffset(line.x, line.y)
				if line.x + line.width < -20 then
					line.object:Destroy()
					table.remove(lines, index)
				end
			end

			-- Wheels spin with road speed.
			local carX = car.root.AbsolutePosition.X
			local velocity = lastCarX and math.abs(carX - lastCarX) / math.max(dt, 1 / 240) or 0
			lastCarX = carX
			local rate = math.min((velocity + lineSpeed * 0.5) / (24 * unit) * 57.3, 2400)
			wheelAngle = (wheelAngle + rate * dt) % 360
			for _, spin in ipairs(car.spokes) do
				spin.Rotation = wheelAngle
			end
		end)
	)

	-- Waits for the timeline clock, returns false if skipped or destroyed.
	local function at(time)
		while clock < time and not skipped and not UI._destroyed do
			task.wait()
		end
		return not skipped and not UI._destroyed
	end

	local function fadeTitle(main, copies, seconds)
		local info = TweenInfo.new(seconds, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		play(titleMain, info, { TextTransparency = main })
		play(titleRed, info, { TextTransparency = copies })
		play(titleCyan, info, { TextTransparency = copies })
	end

	-- Red/cyan copies sit 2 px apart, then merge back together.
	local function chromaMerge()
		local info = TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		titleRed.Position = UDim2.fromOffset(-2, 0)
		titleCyan.Position = UDim2.fromOffset(2, 0)
		play(titleRed, info, { Position = UDim2.fromOffset(0, 0) })
		play(titleCyan, info, { Position = UDim2.fromOffset(0, 0) })
	end

	local function timeline()
		-- Drive in from the left and brake hard at center.
		if not at(0.25) then
			return
		end
		play(car.root, TweenInfo.new(2.1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(0.5, 0.58),
		})

		if not at(1.2) then
			return
		end
		lineTarget = 1300
		lightTarget = 0.5

		if not at(2.3) then
			return
		end
		lineTarget = 450
		play(car.chassis, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Rotation = 2.5 })

		-- Title slams in with a chromatic split that merges.
		if not at(2.5) then
			return
		end
		play(car.chassis, TWEEN_POP, { Rotation = 0 })
		play(slamScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		fadeTitle(0, 0.3, 0.15)
		chromaMerge()
		kick = 0.6
		lightTarget = 0.85

		if not at(3.0) then
			return
		end
		play(subtitle, TWEEN_UI, { TextTransparency = 0 })

		-- Launch: squat, then blast right with shake, flame, flash.
		if not at(4.7) then
			return
		end
		play(car.chassis, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Rotation = -4 })
		lightTarget = 1
		flameTarget = 200

		if not at(4.95) then
			return
		end
		lineTarget = 7500
		kick = 1
		shakeEnd = clock + 0.9
		chromaMerge()
		play(car.root, TweenInfo.new(1.1, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
			Position = UDim2.fromScale(1.5, 0.58),
		})
		play(car.chassis, TWEEN_POP, { Rotation = -1 })

		if not at(5.4) then
			return
		end
		fadeTitle(1, 1, 0.5)
		play(subtitle, TWEEN_UI, { TextTransparency = 1 })
		play(slamScale, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Scale = 1.15 })

		at(6.2)
	end

	local ok, err = xpcall(timeline, onError)
	if not ok then
		warn("[PremiumUI] intro timeline failed: " .. tostring(err))
	end

	-- Ending (also the skip path): black curtain while the music fades out over 1 s.
	skipButton.Active = false
	skipButton.Visible = false
	play(curtain, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0 })
	play(sound, TweenInfo.new(1, Enum.EasingStyle.Linear), { Volume = 0 })

	local fadeStart = os.clock()
	while os.clock() - fadeStart < 1 and not UI._destroyed do
		task.wait()
	end

	return cleanup
end

-- ---------------------------------------------------------------------------
-- Card intro (default): trembling glyph clusters, the name wipes in under a shine, a rule draws itself.
-- ---------------------------------------------------------------------------

-- Plays the card intro and returns a finish() closure. Blocks until it ends or is skipped.
---@return function
local function playCardIntro()
	local connections = {}
	local tweens = {}
	local skipped = false
	local clock = 0
	local cleaned = false

	local gui = newScreenGui(INTRO_GUI_NAME, DISPLAY_INTRO)
	local viewport = getViewport(gui)
	local unit = math.clamp(viewport.X / 1100, 0.55, 1.2)

	local sound = Instance.new("Sound")
	sound.Name = "PremiumUI_IntroMusic"
	sound.Volume = 0
	sound.Looped = false

	local function play(object, info, props)
		local playing = tween(object, info, props)
		table.insert(tweens, playing)
		return playing
	end

	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true

		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		table.clear(connections)

		for _, running in ipairs(tweens) do
			pcall(function()
				running:Cancel()
			end)
		end
		table.clear(tweens)

		pcall(function()
			sound:Stop()
		end)
		sound:Destroy()
		gui:Destroy()
	end
	table.insert(UI._cleanups, cleanup)

	local window = UI._windows[1]
	local titleText = window and window.Title or "Welcome"
	local subtitleText = window and window.Subtitle or ""

	-- Click anywhere (or Space) skips.
	local card = create("TextButton", {
		Name = "Card",
		Size = UDim2.fromScale(1, 1),
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = COLORS.background,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = gui,
	})
	play(card, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0 })
	card.Activated:Connect(function()
		skipped = true
	end)

	table.insert(
		connections,
		userInputService.InputBegan:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.Space and not userInputService:GetFocusedTextBox() then
				skipped = true
			end
		end)
	)

	local flashBeat = create("Frame", {
		Name = "FlashBeat",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.white,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 5,
		Active = false,
		Parent = gui,
	})

	local stage = create("Frame", {
		Name = "Stage",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(900, 420),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = gui,
	})
	create("UIScale", { Scale = unit, Parent = stage })

	-- Four glyph clusters drift in from the middle, then tremble.
	local glyphFont = Font.fromEnum(Enum.Font.Bangers)
	local spots = { { -330, -120, -12, 64 }, { 320, -150, 9, 52 }, { 290, 130, -5, 40 }, { -300, 140, 7, 36 } }
	local glyphs = {}
	for index, spot in ipairs(spots) do
		local glyph = newLabel({
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, spot[1] * 0.6, 0.5, spot[2] * 0.6),
			Size = UDim2.fromOffset(300, 90),
			Text = "ゴゴゴ",
			FontFace = glyphFont,
			TextSize = spot[4],
			TextColor3 = index % 2 == 1 and COLORS.accent or COLORS.cyan,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTransparency = 1,
			Rotation = spot[3],
			ZIndex = 3,
			Parent = stage,
		})
		create("UIStroke", { Color = COLORS.black, Thickness = 2, Parent = glyph })
		table.insert(glyphs, { object = glyph, base = spot })

		task.delay(0.08 * index, function()
			if cleaned then
				return
			end
			play(glyph, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { TextTransparency = 0.05 })
			play(glyph, TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
				Position = UDim2.new(0.5, spot[1], 0.5, spot[2]),
			})
		end)
	end

	-- Name: slam scale on the holder, beat pulse on the label, gold-to-cyan shine wipe.
	local nameHolder = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 12),
		Size = UDim2.fromOffset(900, 80),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = stage,
	})
	local slamScale = create("UIScale", { Scale = 1.25, Parent = nameHolder })
	local name = newLabel({
		Size = UDim2.fromScale(1, 1),
		Text = titleText,
		FontFace = fontBold,
		TextSize = 64,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		ZIndex = 4,
		Parent = nameHolder,
	})
	local pulseScale = create("UIScale", { Parent = name })
	local shine = create("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, COLORS.text),
			ColorSequenceKeypoint.new(0.42, COLORS.text),
			ColorSequenceKeypoint.new(0.5, COLORS.cyan),
			ColorSequenceKeypoint.new(0.58, COLORS.text),
			ColorSequenceKeypoint.new(1, COLORS.text),
		}),
		Offset = Vector2.new(-1, 0),
		Parent = name,
	})

	local rule = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 62),
		Size = UDim2.fromOffset(0, 2),
		BackgroundColor3 = COLORS.white,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = stage,
	})
	addAccentGradient(rule, 0)

	local tag = newLabel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 86),
		Size = UDim2.fromOffset(700, 24),
		Text = subtitleText,
		TextColor3 = COLORS.muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		ZIndex = 4,
		Parent = stage,
	})

	local hint = newLabel({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(400, 20),
		Text = "Click or press Space to skip",
		TextColor3 = COLORS.muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 0.5,
		ZIndex = 6,
		Parent = gui,
	})

	-- Audio: silent fallback if there is no asset function or no file.
	local assetId = resolveAudio()
	if assetId then
		startMusic(sound, assetId, function()
			return cleaned
		end, play)
	end

	local level = 0
	local tremble = 0
	local random = Random.new()

	table.insert(
		connections,
		runService.RenderStepped:Connect(function(dt)
			clock += dt

			-- Beat: real loudness when audio plays, a soft synthetic pulse otherwise.
			local raw
			if assetId and sound.IsPlaying then
				raw = math.clamp(sound.PlaybackLoudness / 500, 0, 1)
			else
				local phase = (clock * 2) % 1
				raw = (clock > 0.4 and phase < 0.15) and (1 - phase / 0.15) * 0.6 or 0
			end
			level = math.max(raw, level - dt * 3)

			pulseScale.Scale = 1 + level * 0.05
			flashBeat.BackgroundTransparency = 1 - level * 0.06
			shine.Offset = Vector2.new(math.clamp(-1 + (clock - 0.5) * 1.6, -1, 1), 0)

			-- Glyphs tremble at 30 fps once they have landed.
			tremble += dt
			if tremble >= 1 / 30 and clock > 0.8 then
				tremble = 0
				for _, glyph in ipairs(glyphs) do
					glyph.object.Position =
						UDim2.new(0.5, glyph.base[1] + random:NextInteger(-2, 2), 0.5, glyph.base[2] + random:NextInteger(-2, 2))
				end
			end
		end)
	)

	local function at(time)
		while clock < time and not skipped and not UI._destroyed do
			task.wait()
		end
		return not skipped and not UI._destroyed
	end

	local function timeline()
		if not at(0.25) then
			return
		end
		play(name, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { TextTransparency = 0 })
		play(slamScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })

		if not at(0.45) then
			return
		end
		play(rule, TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(520, 2) })

		if not at(0.65) then
			return
		end
		play(tag, TWEEN_UI, { TextTransparency = 0.2 })

		at(3.2)
	end

	local ok, err = xpcall(timeline, onError)
	if not ok then
		warn("[PremiumUI] intro timeline failed: " .. tostring(err))
	end

	-- Dissolve the text while the music fades out over 1 s; the dark card stays up for the loading screen.
	hint.Visible = false
	local fade = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	play(name, fade, { TextTransparency = 1 })
	play(tag, fade, { TextTransparency = 1 })
	play(rule, fade, { BackgroundTransparency = 1 })
	play(slamScale, fade, { Scale = 1.06 })
	for _, glyph in ipairs(glyphs) do
		play(glyph.object, fade, { TextTransparency = 1 })
	end
	play(sound, TweenInfo.new(1, Enum.EasingStyle.Linear), { Volume = 0 })

	local fadeStart = os.clock()
	while os.clock() - fadeStart < 1 and not UI._destroyed do
		task.wait()
	end

	return cleanup
end

-- ---------------------------------------------------------------------------
-- Loading screen
-- ---------------------------------------------------------------------------

---@return table
local function buildLoading()
	local gui = newScreenGui(LOADING_GUI_NAME, DISPLAY_LOADING)

	local backdrop = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.black,
		BorderSizePixel = 0,
		Parent = gui,
	})

	local panel = makePanel(gui, "Card", UDim2.fromOffset(340, 236), COLORS.surface, false)
	panel.holder.ZIndex = 2
	local surface = panel.group

	-- Rotating gradient ring: a hollow circle whose UIStroke carries a rotating tail gradient.
	local ringTrack = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 28),
		Size = UDim2.fromOffset(64, 64),
		BackgroundTransparency = 1,
		Parent = surface,
	})
	addCorner(ringTrack, RADIUS_PILL)
	create("UIStroke", {
		Thickness = 5,
		Color = COLORS.raised,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = ringTrack,
	})

	local ring = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 28),
		Size = UDim2.fromOffset(64, 64),
		BackgroundTransparency = 1,
		Parent = surface,
	})
	addCorner(ring, RADIUS_PILL)
	local ringStroke = create("UIStroke", {
		Thickness = 5,
		Color = COLORS.white,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = ring,
	})
	local ringGradient = create("UIGradient", {
		Color = ACCENT_SEQUENCE,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.4, 0.45),
			NumberSequenceKeypoint.new(0.75, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = ringStroke,
	})

	local status = newLabel({
		Position = UDim2.fromOffset(0, 114),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Initializing…",
		FontFace = fontBold,
		TextSize = TEXT_HEADING,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = surface,
	})

	local track = create("Frame", {
		Position = UDim2.fromOffset(30, 154),
		Size = UDim2.new(1, -60, 0, 8),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = surface,
	})
	addCorner(track, RADIUS_PILL)

	local fill = create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = COLORS.white,
		BorderSizePixel = 0,
		Parent = track,
	})
	addCorner(fill, RADIUS_PILL)
	addAccentGradient(fill, 0)

	local percent = newLabel({
		Position = UDim2.fromOffset(0, 174),
		Size = UDim2.new(1, 0, 0, 20),
		Text = "0%",
		TextColor3 = COLORS.muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = surface,
	})

	return {
		gui = gui,
		backdrop = backdrop,
		panel = panel,
		ringGradient = ringGradient,
		status = status,
		fill = fill,
		percent = percent,
	}
end

local function runLoading(parts)
	local connections = {}

	local function cleanup()
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		table.clear(connections)
		parts.gui:Destroy()
	end
	table.insert(UI._cleanups, cleanup)

	table.insert(
		connections,
		runService.RenderStepped:Connect(function(dt)
			parts.ringGradient.Rotation = (parts.ringGradient.Rotation + dt * 360) % 360
			parts.panel.gradient.Rotation = (parts.panel.gradient.Rotation + dt * 40) % 360
			parts.percent.Text = string.format("%d%%", math.floor(parts.fill.Size.X.Scale * 100 + 0.5))
		end)
	)

	panelIn(parts.panel)
	tween(parts.backdrop, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0.4,
	})

	-- Stepped progress: three tween segments, about 2 s in total.
	local function advance(target, seconds, text)
		if text then
			parts.status.Text = text
		end
		tween(parts.fill, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(target, 1),
		})
		task.wait(seconds)
	end

	advance(0.32, 0.5, "Initializing…")
	advance(0.88, 0.85, "Loading modules…")
	advance(1, 0.4, nil)
	parts.status.Text = "Ready"
	task.wait(0.3)

	panelOut(parts.panel)
	tween(parts.backdrop, TWEEN_UI, { BackgroundTransparency = 1 })
	task.wait(0.3)

	cleanup()
end

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

---@return ScreenGui
local function ensureMainGui()
	if mainGui and mainGui.Parent ~= nil then
		return mainGui
	end

	mainGui = newScreenGui(GUI_NAME, DISPLAY_MAIN)
	notificationHolder = create("Frame", {
		Name = "Notifications",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -20, 1, -20),
		Size = UDim2.new(0, 320, 1, -40),
		BackgroundTransparency = 1,
		ZIndex = 50,
		Parent = mainGui,
	}, {
		create("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
		}),
	})

	return mainGui
end

local function pushNotification(config)
	ensureMainGui()
	notificationOrder += 1

	local duration = tonumber(config.Duration) or 4

	-- Outer slot sits in the stack; the inner card slides in from the right.
	local slot = create("Frame", {
		LayoutOrder = notificationOrder,
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = notificationHolder,
	})
	local card = create("Frame", {
		Position = UDim2.fromOffset(340, 0),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = slot,
	})
	addCorner(card, RADIUS_CARD)
	addStroke(card, 0.35)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 14),
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		Parent = card,
	})
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = card })

	newLabel({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 20),
		Text = tostring(config.Title or "Notification"),
		FontFace = fontBold,
		TextSize = TEXT_HEADING,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = card,
	})
	newLabel({
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = tostring(config.Text or ""),
		TextColor3 = COLORS.muted,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})

	local timerTrack = create("Frame", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = card,
	})
	addCorner(timerTrack, RADIUS_PILL)
	local timerFill = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.white,
		BorderSizePixel = 0,
		Parent = timerTrack,
	})
	addCorner(timerFill, RADIUS_PILL)
	addAccentGradient(timerFill, 0)

	tween(card, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(0, 0),
	})
	tween(timerFill, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) })

	task.delay(duration, function()
		if not slot.Parent then
			return
		end

		local leave = tween(card, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
			Position = UDim2.fromOffset(340, 0),
		})
		leave.Completed:Wait()
		slot:Destroy()
	end)
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

---@param config table {Title, Subtitle}
---@return table
function UI:CreateWindow(config)
	config = config or {}

	local gui = ensureMainGui()
	local viewport = getViewport(gui)
	local width = math.min(WINDOW_WIDTH, viewport.X - 32)
	local height = math.min(WINDOW_HEIGHT, viewport.Y - 32)

	if config.Intro == false then
		UI._skipIntro = true
	end
	-- "card" (default) or "hypercar".
	UI._introStyle = config.IntroStyle or UI._introStyle

	local self = setmetatable({
		Title = tostring(config.Title or "Window"),
		Subtitle = tostring(config.Subtitle or ""),
		tabs = {},
		activeTab = nil,
		_connections = {},
		_opened = false,
		_closed = false,
		-- Open/close bind; RightShift unless the Settings keybind (or config.ToggleKey) says otherwise.
		toggleKey = resolveKey(config.ToggleKey) or Enum.KeyCode.RightShift,
	}, Window)

	local panel = makePanel(gui, "Window", UDim2.fromOffset(width, height), COLORS.background, true)
	panel.holder.Visible = false
	self.panel = panel

	local surface = panel.group

	-- Header (drag handle).
	local header = create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = surface,
	})
	newLabel({
		Position = UDim2.fromOffset(22, 9),
		Size = UDim2.new(1, -90, 0, 28),
		Text = self.Title,
		FontFace = fontBold,
		TextSize = TEXT_TITLE,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = header,
	})
	newLabel({
		Position = UDim2.fromOffset(22, 37),
		Size = UDim2.new(1, -90, 0, 18),
		Text = self.Subtitle,
		TextColor3 = COLORS.muted,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = header,
	})
	create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = header,
	})

	local closeButton = create("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(34, 34),
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = header,
	})
	addCorner(closeButton, RADIUS_CONTROL)
	local closeStroke = addStroke(closeButton, STROKE_IDLE)
	drawCross(closeButton, COLORS.text)
	bindHover(closeButton, closeStroke, STROKE_IDLE)
	bindPress(closeButton)
	closeButton.Activated:Connect(function()
		self:_close()
	end)

	-- Sidebar and content.
	local body = create("Frame", {
		Name = "Body",
		Position = UDim2.fromOffset(0, HEADER_HEIGHT),
		Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT),
		BackgroundTransparency = 1,
		Parent = surface,
	})
	-- Scrolls so long tab lists with category headers still fit.
	local sidebar = create("ScrollingFrame", {
		Name = "Sidebar",
		Size = UDim2.new(0, SIDEBAR_WIDTH, 1, -SIDEBAR_FOOTER),
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = COLORS.accent,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = body,
	})
	create("Frame", {
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(SIDEBAR_WIDTH - 1, 0),
		Size = UDim2.new(0, 1, 1, 0),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = body,
	})
	create("UIPadding", {
		PaddingTop = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 13),
		Parent = sidebar,
	})
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = sidebar })

	-- Fixed footer: the Settings tab lives here so it is always reachable, however long the tab list is.
	local footer = create("Frame", {
		Name = "SidebarFooter",
		Position = UDim2.new(0, 0, 1, -SIDEBAR_FOOTER),
		Size = UDim2.new(0, SIDEBAR_WIDTH, 0, SIDEBAR_FOOTER),
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = body,
	})
	create("Frame", {
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = footer,
	})
	create("UIPadding", {
		PaddingTop = UDim.new(0, 9),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 13),
		Parent = footer,
	})
	self.sidebarFooter = footer

	local content = create("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(SIDEBAR_WIDTH, 0),
		Size = UDim2.new(1, -SIDEBAR_WIDTH, 1, 0),
		BackgroundTransparency = 1,
		Parent = body,
	})
	self.contentTitle = newLabel({
		Position = UDim2.fromOffset(20, 14),
		Size = UDim2.new(1, -40, 0, 24),
		Text = "",
		FontFace = fontBold,
		TextSize = TEXT_HEADING,
		Parent = content,
	})
	self.sidebar = sidebar
	self.content = content

	-- Drag by the header; global listeners exist only while dragging.
	header.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local origin = input.Position
		local start = panel.holder.Position
		local moveConnection, endConnection

		moveConnection = connect(userInputService.InputChanged, function(changed)
			if
				changed.UserInputType ~= Enum.UserInputType.MouseMovement
				and changed.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end

			local delta = changed.Position - origin
			panel.holder.Position =
				UDim2.new(start.X.Scale, start.X.Offset + delta.X, start.Y.Scale, start.Y.Offset + delta.Y)
		end)
		endConnection = connect(userInputService.InputEnded, function(ended)
			if ended.UserInputType == Enum.UserInputType.MouseButton1 or ended.UserInputType == Enum.UserInputType.Touch then
				disconnect(moveConnection)
				disconnect(endConnection)
			end
		end)
	end)

	-- Slow border rotation.
	table.insert(
		self._connections,
		connect(runService.RenderStepped, function(dt)
			panel.gradient.Rotation = (panel.gradient.Rotation + dt * 40) % 360
		end)
	)
	-- Open/close bind. Works even when the game also binds the key (it arrives game-processed); ignored while typing or capturing.
	table.insert(
		self._connections,
		connect(userInputService.InputBegan, function(input)
			if UI._capturing or userInputService:GetFocusedTextBox() then
				return
			end
			if input.KeyCode == self.toggleKey then
				self:Toggle()
			end
		end)
	)

	self:_buildSettings()

	table.insert(UI._windows, self)
	if UI._ready then
		self:_open()
	end

	return self
end

-- Pop-in: scale + fade.
function Window:_open()
	if self._opened or self._closed then
		return
	end
	self._opened = true

	self.panel.holder.Visible = true
	panelIn(self.panel)

	-- With no user tabs, the Settings tab is the landing page.
	if not self.activeTab and self.settingsTab then
		self:_select(self.settingsTab)
	end

	-- Autoload runs once the window is open.
	if self._autoload then
		task.delay(0.5, self._autoload)
	end
end

-- Hides or shows the window with the same pop animation.
function Window:Toggle()
	if self._closed or not self._opened then
		return
	end

	if self.panel.holder.Visible then
		panelOut(self.panel)
		task.delay(0.3, function()
			if not self._closed then
				self.panel.holder.Visible = false
			end
		end)
	else
		self.panel.holder.Visible = true
		panelIn(self.panel)
	end
end

function Window:_close()
	if self._closed then
		return
	end
	self._closed = true

	panelOut(self.panel)
	for _, connection in ipairs(self._connections) do
		disconnect(connection)
	end
	table.clear(self._connections)

	task.delay(0.35, function()
		self.panel.holder:Destroy()
	end)
end

---@param config table {Title, Text, Duration}
function Window:Notify(config)
	config = config or {}

	if not UI._ready then
		table.insert(UI._pendingNotifications, config)
		return
	end

	pushNotification(config)
end

function Window:_nextSideOrder()
	self._sideOrder = (self._sideOrder or 0) + 1
	return self._sideOrder
end

-- Sidebar group header; tabs created after it sit under it.
---@param name string
function Window:CreateCategory(name)
	return newLabel({
		Name = "Category",
		LayoutOrder = self:_nextSideOrder(),
		Size = UDim2.new(1, 0, 0, self._hasUserTab and 30 or 22),
		Text = string.upper(tostring(name)),
		FontFace = fontBold,
		TextSize = 12,
		TextColor3 = COLORS.muted,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Parent = self.sidebar,
	})
end

---@param name string
---@return table
function Window:CreateTab(name, internal)
	local tab = setmetatable({ Name = tostring(name), window = self, active = false, order = 0 }, Tab)

	local button = create("TextButton", {
		Name = tab.Name,
		-- The built-in Settings tab sorts after everything else.
		LayoutOrder = internal and 1000000 or self:_nextSideOrder(),
		Size = UDim2.new(1, 0, 0, 38),
		AutoButtonColor = false,
		Text = tab.Name,
		FontFace = fontMedium,
		TextSize = TEXT_BODY,
		TextColor3 = COLORS.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = internal and self.sidebarFooter or self.sidebar,
	})
	addCorner(button, RADIUS_CONTROL)
	create("UIPadding", { PaddingLeft = UDim.new(0, 18), Parent = button })

	local stroke = addStroke(button, 0.92)
	bindHover(button, stroke, function()
		return tab.active and 0.5 or 0.92
	end, function()
		return tab.active and COLORS.raised or COLORS.surface
	end)
	bindPress(button)

	-- Active marker.
	local indicator = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -12, 0.5, 0),
		Size = UDim2.fromOffset(3, 0),
		BackgroundColor3 = COLORS.white,
		BorderSizePixel = 0,
		Parent = button,
	})
	addCorner(indicator, RADIUS_PILL)
	addAccentGradient(indicator, 90)

	local page = create("ScrollingFrame", {
		Name = tab.Name,
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -48),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = COLORS.accent,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
		Parent = self.content,
	})
	create("UIPadding", {
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 16),
		PaddingLeft = UDim.new(0, 20),
		PaddingRight = UDim.new(0, 20),
		Parent = page,
	})
	create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })

	tab.button = button
	tab.stroke = stroke
	tab.indicator = indicator
	tab.page = page

	button.Activated:Connect(function()
		self:_select(tab)
	end)

	table.insert(self.tabs, tab)
	if not internal and not self._hasUserTab then
		self._hasUserTab = true
		self:_select(tab)
	end

	return tab
end

-- Settings tab: always last in the sidebar. Toggle UI keybind plus the config manager.
function Window:_buildSettings()
	local tab = self:CreateTab("Settings", true)
	self.settingsTab = tab

	tab:AddSection("Interface")
	tab:AddKeybind({
		Text = "Toggle UI",
		Default = self.toggleKey,
		Callback = function(key)
			-- "None" would lock the window shut, so it falls back to the default bind.
			self.toggleKey = key or Enum.KeyCode.RightShift
		end,
	})

	tab:AddSection("Configs")

	local api = resolveFileApi()
	local hubName = tostring(self.Title):gsub("[^%w_%-]", "")
	if hubName == "" then
		hubName = "PremiumUI"
	end
	local configDir = hubName .. "/configs"
	local autoloadFile = hubName .. "/autoload.txt"

	local function say(title, text)
		self:Notify({ Title = title, Text = text, Duration = 3 })
	end

	local nameBox = tab:_addTextBox("Config name")
	local picker = tab:AddDropdown({ Text = "Saved configs", Options = {}, NoFlag = true })

	---@return string
	local function cleanName(text)
		return (tostring(text or ""):gsub("[^%w _%-]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
	end

	-- Typed name wins for Save; the picked config wins for Load / Delete.
	local function chosenName(preferTyped)
		local typed = cleanName(nameBox.Get())
		local picked = picker:Get()
		if preferTyped then
			return typed ~= "" and typed or picked
		end
		return picked or (typed ~= "" and typed or nil)
	end

	local function configPath(name)
		return configDir .. "/" .. name .. ".json"
	end

	local function ensureFolders()
		for _, folder in ipairs({ hubName, configDir }) do
			if not api.isfolder(folder) then
				api.makefolder(folder)
			end
		end
	end

	---@return string[]
	local function listConfigs()
		local names = {}
		local ok, files = pcall(function()
			ensureFolders()
			return api.listfiles(configDir)
		end)
		if ok and type(files) == "table" then
			for _, path in ipairs(files) do
				local name = tostring(path):match("([^/\\]+)%.json$")
				if name then
					table.insert(names, name)
				end
			end
		end
		table.sort(names)
		return names
	end

	-- Updates each element's visuals and fires its callback (every entry's Set does both).
	local function applyData(data)
		local applied = 0
		for flag, value in pairs(data) do
			local entry = UI.Flags[flag]
			if entry and entry.Set then
				if entry.Type == "Keybind" then
					value = resolveKey(value)
				end
				if pcall(entry.Set, value) then
					applied += 1
				end
			end
		end
		return applied
	end

	local autoloadToggle
	local suppressAutoload = false

	local function refresh(silent)
		local names = listConfigs()
		picker:SetOptions(names)
		if not silent then
			say("Configs", "Refreshed: " .. #names .. " saved")
		end
	end

	local function save()
		local name = chosenName(true)
		if not name or name == "" then
			return say("Save failed", "Type a config name first")
		end

		local ok, err = pcall(function()
			ensureFolders()
			api.writefile(configPath(name), game:GetService("HttpService"):JSONEncode(encodeFlags()))
		end)
		if not ok then
			return say("Save failed", tostring(err))
		end

		say("Saved", name)
		refresh(true)
		picker:Set(name)
	end

	local function loadConfig(name, quiet)
		if not name or name == "" then
			return say("Load failed", "Pick or type a config")
		end

		local ok, result = pcall(function()
			return game:GetService("HttpService"):JSONDecode(api.readfile(configPath(name)))
		end)
		if not ok or type(result) ~= "table" then
			return say("Load failed", ok and "Config is not valid JSON" or tostring(result))
		end

		local applied = applyData(result)
		if not quiet then
			say("Loaded", name .. " (" .. applied .. " settings)")
		end
	end

	local function delete()
		local name = chosenName(false)
		if not name or name == "" then
			return say("Delete failed", "Pick or type a config")
		end

		local ok, err = pcall(function()
			api.delfile(configPath(name))
		end)
		if not ok then
			return say("Delete failed", tostring(err))
		end

		-- Autoload pointing at a deleted config is dropped.
		pcall(function()
			if api.readfile(autoloadFile) == name then
				api.delfile(autoloadFile)
				suppressAutoload = true
				autoloadToggle:Set(false)
				suppressAutoload = false
			end
		end)

		say("Deleted", name)
		refresh(true)
	end

	local rowButtons = tab:_addButtonRow({
		{ Text = "Save", Callback = function() save() end },
		{ Text = "Load", Callback = function() loadConfig(chosenName(false)) end },
		{ Text = "Delete", Callback = function() delete() end },
		{ Text = "Refresh", Callback = function() refresh(false) end },
	})

	autoloadToggle = tab:AddToggle({
		Text = "Autoload this config",
		Default = false,
		NoFlag = true,
		Callback = function(on)
			if suppressAutoload then
				return
			end

			if not api then
				return
			end

			if on then
				local name = chosenName(false)
				if not name or name == "" then
					say("Autoload failed", "Pick or save a config first")
					suppressAutoload = true
					autoloadToggle:Set(false)
					suppressAutoload = false
					return
				end

				local ok, err = pcall(function()
					ensureFolders()
					api.writefile(autoloadFile, name)
				end)
				say(ok and "Autoload on" or "Autoload failed", ok and name or tostring(err))
			else
				local ok, err = pcall(function()
					api.delfile(autoloadFile)
				end)
				say(ok and "Autoload off" or "Autoload failed", ok and "Cleared" or tostring(err))
			end
		end,
	})

	if not api then
		-- No file functions: disable the config UI and say so once.
		tab:AddLabel("Configs not supported on this executor.")
		for _, button in ipairs(rowButtons) do
			button.Active = false
			button.TextTransparency = 0.6
		end
		self._autoload = function()
			say("Configs", "Configs not supported")
		end
		return
	end

	refresh(true)

	-- Reflects an existing autoload marker, then loads it once the window is open.
	self._autoload = function()
		local ok, name = pcall(api.readfile, autoloadFile)
		if not ok or type(name) ~= "string" or name == "" then
			return
		end

		suppressAutoload = true
		autoloadToggle:Set(true)
		suppressAutoload = false
		picker:Set(name)
		loadConfig(name, true)
		say("Autoload", name)
	end
end

function Window:_select(selected)
	self.activeTab = selected
	self.contentTitle.Text = selected.Name

	for _, tab in ipairs(self.tabs) do
		local active = tab == selected
		tab.active = active
		tab.page.Visible = active

		tween(tab.button, TWEEN_UI, {
			BackgroundColor3 = active and COLORS.raised or COLORS.surface,
			TextColor3 = active and COLORS.text or COLORS.muted,
		})
		tween(tab.stroke, TWEEN_UI, { Transparency = active and 0.5 or 0.92 })
		tween(tab.indicator, TWEEN_POP, { Size = UDim2.fromOffset(3, active and 18 or 0) })
	end
end

-- ---------------------------------------------------------------------------
-- Components
-- ---------------------------------------------------------------------------

---@return number
function Tab:_nextOrder()
	self.order += 1
	return self.order
end

-- Card row: a TextButton so the whole row is one hover/press target.
---@return TextButton, UIStroke
function Tab:_row(name, height)
	local row = create("TextButton", {
		Name = name,
		LayoutOrder = self:_nextOrder(),
		Size = UDim2.new(1, 0, 0, height),
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = self.page,
	})
	addCorner(row, RADIUS_CARD)
	local stroke = addStroke(row, STROKE_IDLE)
	bindHover(row, stroke, STROKE_IDLE)
	return row, stroke
end

-- Heading that starts a group of controls.
---@param text string
function Tab:AddSection(text)
	return newLabel({
		LayoutOrder = self:_nextOrder(),
		Size = UDim2.new(1, 0, 0, 26),
		Text = tostring(text),
		FontFace = fontBold,
		TextSize = TEXT_HEADING,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Parent = self.page,
	})
end

-- Wrapped read-only text card with :SetText.
---@param text string
function Tab:AddLabel(text)
	local card = create("Frame", {
		Name = "Label",
		LayoutOrder = self:_nextOrder(),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = self.page,
	})
	addCorner(card, RADIUS_CARD)
	addStroke(card, STROKE_IDLE)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		Parent = card,
	})
	local label = newLabel({
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = tostring(text),
		TextColor3 = COLORS.muted,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})

	local object = {}

	function object:SetText(newText)
		label.Text = tostring(newText)
	end

	return object
end

---@param config table {Text, Callback}
function Tab:AddButton(config)
	config = config or {}

	local button = create("TextButton", {
		Name = "Button",
		LayoutOrder = self:_nextOrder(),
		Size = UDim2.new(1, 0, 0, 42),
		AutoButtonColor = false,
		Text = tostring(config.Text or "Button"),
		FontFace = fontMedium,
		TextSize = TEXT_BODY,
		TextColor3 = COLORS.text,
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = self.page,
	})
	addCorner(button, RADIUS_CONTROL)
	local stroke = addStroke(button, STROKE_IDLE)
	bindHover(button, stroke, STROKE_IDLE)
	bindPress(button)

	button.Activated:Connect(function()
		safeCall(config.Callback)
	end)

	return button
end

-- Click, then press a key: Escape cancels, mouse buttons are ignored, and keys are ignored while a text box has focus.
-- Game-processed keys are accepted on purpose: games often bind RightShift/Control themselves.
-- Callback(key) fires when the bind changes; the optional Pressed() fires when the bound key is pressed.
---@param config table {Text, Default, Callback, Pressed}
function Tab:AddKeybind(config)
	config = config or {}
	local key = resolveKey(config.Default)
	local listening = false
	local captureConnection = nil

	local row = self:_row("Keybind", 48)

	newLabel({
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -150, 1, 0),
		Text = tostring(config.Text or "Keybind"),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})

	local button = create("TextButton", {
		Name = "Key",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(112, 30),
		AutoButtonColor = false,
		Text = "",
		FontFace = fontMedium,
		TextSize = TEXT_BODY,
		TextColor3 = COLORS.text,
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = row,
	})
	addCorner(button, RADIUS_CONTROL)
	local buttonStroke = addStroke(button, STROKE_IDLE)
	bindHover(button, buttonStroke, STROKE_IDLE)
	bindPress(button)

	local keybind = {}
	local entry = registerFlag(self, config, "Keybind", key)

	local function render()
		button.Text = listening and "..." or (key and key.Name or "None")
	end

	local function stopListening()
		listening = false
		UI._capturing = false
		if captureConnection then
			disconnect(captureConnection)
			captureConnection = nil
		end
		render()
	end

	function keybind:Set(value)
		key = resolveKey(value)
		entry.Value = key
		render()
		safeCall(config.Callback, key)
	end

	function keybind:Get()
		return key
	end

	entry.Set = function(value)
		keybind:Set(value)
	end

	button.Activated:Connect(function()
		if listening then
			return stopListening()
		end

		listening = true
		UI._capturing = true
		render()

		captureConnection = connect(userInputService.InputBegan, function(input)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return
			end

			-- Roblox marks Escape as game-processed (it opens the menu), so cancel is checked first.
			if input.KeyCode == Enum.KeyCode.Escape then
				return stopListening()
			end

			if userInputService:GetFocusedTextBox() then
				return
			end

			stopListening()
			keybind:Set(input.KeyCode)
		end)
	end)

	if type(config.Pressed) == "function" then
		connect(userInputService.InputBegan, function(input)
			if userInputService:GetFocusedTextBox() or listening or not key or input.KeyCode ~= key then
				return
			end
			safeCall(config.Pressed)
		end)
	end

	render()
	return keybind
end

-- Single-line input card (used by the config manager).
---@return table
function Tab:_addTextBox(placeholder)
	local row = create("Frame", {
		Name = "TextBox",
		LayoutOrder = self:_nextOrder(),
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = self.page,
	})
	addCorner(row, RADIUS_CARD)
	addStroke(row, STROKE_IDLE)

	local box = create("TextBox", {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 1, -16),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = tostring(placeholder or ""),
		PlaceholderColor3 = COLORS.muted,
		TextColor3 = COLORS.text,
		FontFace = fontMedium,
		TextSize = TEXT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Parent = row,
	})
	addCorner(box, RADIUS_CONTROL)
	create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = box })
	local boxStroke = addStroke(box, STROKE_IDLE)
	bindHover(box, boxStroke, STROKE_IDLE)

	local object = {}

	function object.Get()
		return box.Text
	end

	function object.Set(text)
		box.Text = tostring(text or "")
	end

	return object
end

-- A row of equal-width buttons inside one card; returns the buttons so callers can disable them.
---@param items table[] {{Text, Callback}, ...}
---@return TextButton[]
function Tab:_addButtonRow(items)
	local row = create("Frame", {
		Name = "ButtonRow",
		LayoutOrder = self:_nextOrder(),
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		Parent = self.page,
	})
	addCorner(row, RADIUS_CARD)
	addStroke(row, STROKE_IDLE)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		Parent = row,
	})
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = row,
	})

	local count = #items
	local buttons = {}
	for index, item in ipairs(items) do
		local button = create("TextButton", {
			LayoutOrder = index,
			Size = UDim2.new(1 / count, -math.ceil(8 * (count - 1) / count), 1, 0),
			AutoButtonColor = false,
			Text = tostring(item.Text),
			FontFace = fontMedium,
			TextSize = TEXT_BODY,
			TextColor3 = COLORS.text,
			BackgroundColor3 = COLORS.raised,
			BorderSizePixel = 0,
			Parent = row,
		})
		addCorner(button, RADIUS_CONTROL)
		local stroke = addStroke(button, STROKE_IDLE)
		bindHover(button, stroke, STROKE_IDLE)
		bindPress(button)
		button.Activated:Connect(function()
			if button.Active then
				safeCall(item.Callback)
			end
		end)
		table.insert(buttons, button)
	end

	return buttons
end

---@param config table {Text, Default, Callback}
function Tab:AddToggle(config)
	config = config or {}
	local state = config.Default == true

	local row = self:_row("Toggle", 48)
	bindPress(row)

	newLabel({
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -90, 1, 0),
		Text = tostring(config.Text or "Toggle"),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})

	-- Pill track, gradient fill that fades in, white knob.
	local track = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(44, 24),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = row,
	})
	addCorner(track, RADIUS_PILL)
	addStroke(track, 0.6)

	local fill = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.white,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = track,
	})
	addCorner(fill, RADIUS_PILL)
	addAccentGradient(fill, 0)

	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = COLORS.text,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = track,
	})
	addCorner(knob, RADIUS_PILL)

	local toggle = {}
	local entry = registerFlag(self, config, "Toggle", state)

	local function render(animate)
		entry.Value = state
		local info = animate and TWEEN_UI or TweenInfo.new(0)
		tween(knob, info, { Position = state and UDim2.new(1, -21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) })
		tween(fill, info, { BackgroundTransparency = state and 0 or 1 })
	end

	function toggle:Set(value)
		state = value == true
		render(true)
		safeCall(config.Callback, state)
	end

	function toggle:Get()
		return state
	end

	entry.Set = function(value)
		toggle:Set(value)
	end

	row.Activated:Connect(function()
		toggle:Set(not state)
	end)
	render(false)

	return toggle
end

---@param config table {Text, Min, Max, Default, Callback, Increment}
function Tab:AddSlider(config)
	config = config or {}
	local min = tonumber(config.Min) or 0
	local max = tonumber(config.Max) or 100
	if max <= min then
		max = min + 1
	end
	local increment = tonumber(config.Increment) or 1
	local value = math.clamp(tonumber(config.Default) or min, min, max)

	local row = self:_row("Slider", 62)

	newLabel({
		Position = UDim2.fromOffset(16, 9),
		Size = UDim2.new(1, -100, 0, 20),
		Text = tostring(config.Text or "Slider"),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	local valueLabel = newLabel({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 9),
		Size = UDim2.fromOffset(70, 20),
		TextColor3 = COLORS.muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})

	local track = create("Frame", {
		Position = UDim2.new(0, 16, 0, 42),
		Size = UDim2.new(1, -32, 0, 6),
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = row,
	})
	addCorner(track, RADIUS_PILL)
	addStroke(track, 0.7)

	local fill = create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = COLORS.white,
		BorderSizePixel = 0,
		Parent = track,
	})
	addCorner(fill, RADIUS_PILL)
	addAccentGradient(fill, 0)

	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = COLORS.text,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = track,
	})
	addCorner(knob, RADIUS_PILL)

	local slider = {}
	local entry = registerFlag(self, config, "Slider", value)

	local function render(animate)
		entry.Value = value
		local alpha = (value - min) / (max - min)
		local info = animate and TWEEN_UI or TweenInfo.new(0)
		tween(fill, info, { Size = UDim2.fromScale(alpha, 1) })
		tween(knob, info, { Position = UDim2.fromScale(alpha, 0.5) })
		valueLabel.Text = string.format("%.10g", value)
	end

	local function setFromAlpha(alpha)
		local raw = min + math.clamp(alpha, 0, 1) * (max - min)
		local snapped = math.clamp(math.floor(raw / increment + 0.5) * increment, min, max)
		if snapped == value then
			return
		end

		value = snapped
		render(false)
		safeCall(config.Callback, value)
	end

	function slider:Set(newValue)
		value = math.clamp(tonumber(newValue) or value, min, max)
		render(true)
		safeCall(config.Callback, value)
	end

	function slider:Get()
		return value
	end

	entry.Set = function(newValue)
		slider:Set(newValue)
	end

	-- Drag anywhere on the row; global move/end listeners exist only while dragging.
	row.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local function update(x)
			setFromAlpha((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1))
		end

		update(input.Position.X)
		tween(knob, TWEEN_UI, { Size = UDim2.fromOffset(18, 18) })

		local moveConnection, endConnection
		moveConnection = connect(userInputService.InputChanged, function(changed)
			if
				changed.UserInputType == Enum.UserInputType.MouseMovement
				or changed.UserInputType == Enum.UserInputType.Touch
			then
				update(changed.Position.X)
			end
		end)
		endConnection = connect(userInputService.InputEnded, function(ended)
			if ended.UserInputType == Enum.UserInputType.MouseButton1 or ended.UserInputType == Enum.UserInputType.Touch then
				disconnect(moveConnection)
				disconnect(endConnection)
				tween(knob, TWEEN_POP, { Size = UDim2.fromOffset(14, 14) })
			end
		end)
	end)
	render(false)

	return slider
end

---@param config table {Text, Options, Callback, Default}
function Tab:AddDropdown(config)
	config = config or {}
	local options = config.Options or {}
	local selected = config.Default ~= nil and tostring(config.Default) or nil
	local isOpen = false

	local listHeight = math.min(#options, 5) * 38
	local closedHeight = 52
	local openHeight = closedHeight + listHeight + 6

	-- Options expand inline so the window's rounded clip never cuts a floating list.
	local card = create("Frame", {
		Name = "Dropdown",
		LayoutOrder = self:_nextOrder(),
		Size = UDim2.new(1, 0, 0, closedHeight),
		BackgroundColor3 = COLORS.surface,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = self.page,
	})
	addCorner(card, RADIUS_CARD)
	addStroke(card, STROKE_IDLE)

	local head = create("TextButton", {
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 0, 40),
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = COLORS.raised,
		BorderSizePixel = 0,
		Parent = card,
	})
	addCorner(head, RADIUS_CONTROL)
	local headStroke = addStroke(head, STROKE_IDLE)
	bindHover(head, headStroke, STROKE_IDLE)
	bindPress(head)

	newLabel({
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.5, -12, 1, 0),
		Text = tostring(config.Text or "Dropdown"),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = head,
	})
	local valueLabel = newLabel({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -38, 0, 0),
		Size = UDim2.new(0.5, -44, 1, 0),
		Text = selected or "Select…",
		TextColor3 = COLORS.muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = head,
	})
	local chevron = drawChevron(head, COLORS.muted)
	chevron.Position = UDim2.new(1, -20, 0.5, 0)

	local list = create("ScrollingFrame", {
		Position = UDim2.fromOffset(6, closedHeight),
		Size = UDim2.new(1, -12, 0, listHeight),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = COLORS.accent,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = card,
	})
	create("UIPadding", {
		PaddingTop = UDim.new(0, 2),
		PaddingLeft = UDim.new(0, 2),
		PaddingRight = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 2),
		Parent = list,
	})
	create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })

	local dropdown = {}
	local optionButtons = {}
	local entry = registerFlag(self, config, "Dropdown", selected)

	local function refresh()
		entry.Value = selected
		valueLabel.Text = selected or "Select…"
		for name, optionButton in pairs(optionButtons) do
			tween(optionButton, TWEEN_UI, {
				TextColor3 = name == selected and COLORS.cyan or COLORS.text,
			})
		end
	end

	local function setOpen(open)
		isOpen = open
		tween(card, TWEEN_UI, { Size = UDim2.new(1, 0, 0, open and openHeight or closedHeight) })
		tween(chevron, TWEEN_UI, { Rotation = open and 180 or 0 })
	end

	-- Builds (or rebuilds) the option buttons and resizes the card for the new list.
	local function populate(newOptions)
		for _, optionButton in pairs(optionButtons) do
			optionButton:Destroy()
		end
		table.clear(optionButtons)

		listHeight = math.min(#newOptions, 5) * 38
		openHeight = closedHeight + listHeight + 6
		list.Size = UDim2.new(1, -12, 0, listHeight)
		if isOpen then
			tween(card, TWEEN_UI, { Size = UDim2.new(1, 0, 0, openHeight) })
		end

		for index, option in ipairs(newOptions) do
			local name = tostring(option)
			local optionButton = create("TextButton", {
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, 34),
				AutoButtonColor = false,
				Text = name,
				FontFace = fontMedium,
				TextSize = TEXT_BODY,
				TextColor3 = COLORS.text,
				BackgroundColor3 = COLORS.raised,
				BorderSizePixel = 0,
				Parent = list,
			})
			addCorner(optionButton, RADIUS_CONTROL)
			local optionStroke = addStroke(optionButton, 0.85)
			bindHover(optionButton, optionStroke, 0.85)
			bindPress(optionButton)
			optionButtons[name] = optionButton

			optionButton.Activated:Connect(function()
				selected = name
				refresh()
				setOpen(false)
				safeCall(config.Callback, name)
			end)
		end
	end
	populate(options)

	head.Activated:Connect(function()
		setOpen(not isOpen)
	end)
	refresh()

	entry.Set = function(name)
		dropdown:Set(name)
	end

	-- Replaces the option list (used by the config picker); keeps the selection if it still exists.
	function dropdown:SetOptions(newOptions)
		populate(newOptions)
		if selected and not optionButtons[selected] then
			selected = nil
		end
		refresh()
	end

	function dropdown:Set(name)
		selected = name ~= nil and tostring(name) or nil
		refresh()
		safeCall(config.Callback, selected)
	end

	function dropdown:Get()
		return selected
	end

	return dropdown
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function UI:Destroy()
	if UI._destroyed then
		return
	end
	UI._destroyed = true

	for _, cleanup in ipairs(UI._cleanups) do
		pcall(cleanup)
	end
	table.clear(UI._cleanups)

	for connection in pairs(UI._connections) do
		connection:Disconnect()
	end
	table.clear(UI._connections)

	if mainGui then
		mainGui:Destroy()
		mainGui = nil
	end
end

-- Intro -> loading -> windows open. Never errors: a failed stage is skipped.
local function openWindows()
	if UI._ready or UI._destroyed then
		return
	end

	UI._ready = true
	for _, window in ipairs(UI._windows) do
		pcall(window._open, window)
	end
	for _, pending in ipairs(UI._pendingNotifications) do
		pcall(pushNotification, pending)
	end
	table.clear(UI._pendingNotifications)
end

local function run()
	-- The caller's CreateWindow may run a moment after load; wait for it so Intro/IntroStyle/Title are honoured.
	local waited = os.clock()
	while #UI._windows == 0 and os.clock() - waited < 1.5 and not UI._destroyed do
		task.wait()
	end

	-- CreateWindow({Intro = false}) opens straight away.
	if UI._skipIntro then
		openWindows()
		return
	end

	local ok, finishIntro = xpcall(UI._introStyle == "hypercar" and playIntro or playCardIntro, onError)
	if not ok then
		for _, cleanup in ipairs(UI._cleanups) do
			pcall(cleanup)
		end
		table.clear(UI._cleanups)
		finishIntro = nil
	end

	if UI._destroyed then
		return
	end

	local okLoading, loading = xpcall(buildLoading, onError)
	if finishIntro then
		finishIntro()
	end

	if okLoading and not UI._destroyed then
		local okRun = xpcall(runLoading, onError, loading)
		if not okRun then
			-- A failed loading screen must not leave its gui or connections behind.
			for _, cleanup in ipairs(UI._cleanups) do
				pcall(cleanup)
			end
			table.clear(UI._cleanups)
		end
	end

	openWindows()
end

-- Replace any previous instance, then start on the next frame so CreateWindow can run first.
pcall(function()
	if shared.__PremiumUI and shared.__PremiumUI ~= UI then
		shared.__PremiumUI:Destroy()
	end
	shared.__PremiumUI = UI
end)
destroyPrevious()
task.defer(function()
	local ok = xpcall(run, onError)
	if not ok then
		-- Whatever failed, the UI must still open.
		for _, cleanup in ipairs(UI._cleanups) do
			pcall(cleanup)
		end
		table.clear(UI._cleanups)
		openWindows()
	end
end)

-- Watchdog: if the sequence is still stuck after 30 s, drop it and open the windows.
task.delay(30, function()
	if not UI._ready and not UI._destroyed then
		for _, cleanup in ipairs(UI._cleanups) do
			pcall(cleanup)
		end
		table.clear(UI._cleanups)
		openWindows()
	end
end)

return UI

--[[ Demo usage (copy into a separate script):

local UI = loadstring(readfile("ui.lua"))()

local Window = UI:CreateWindow({
	Title = "Premium UI", -- also names the config folder: PremiumUI/configs/<name>.json
	Subtitle = "Component showcase",
})

local Tab = Window:CreateTab("Demo")

-- Flagged toggle: the flag defaults to "Demo_Enable feature" and is saved/loaded with configs.
Tab:AddToggle({
	Text = "Enable feature",
	Default = false,
	Callback = function(on)
		print("toggle", on)
	end,
})

-- Same toggle with an explicit flag (read it back with UI.Flags.Feature.Value).
Tab:AddToggle({ Text = "Another feature", Flag = "Feature", Default = true })

-- Keybind: Callback fires when the bind changes, Pressed fires when the key is pressed.
Tab:AddKeybind({
	Text = "Fire action",
	Default = Enum.KeyCode.F,
	Callback = function(key)
		print("rebound to", key and key.Name or "None")
	end,
	Pressed = function()
		Window:Notify({ Title = "Keybind", Text = "Action fired", Duration = 2 })
	end,
})

Tab:AddSlider({ Text = "Intensity", Min = 0, Max = 100, Default = 40 })
Tab:AddDropdown({ Text = "Mode", Options = { "Fast", "Balanced", "Careful" }, Default = "Balanced" })
Tab:AddButton({
	Text = "Send notification",
	Callback = function()
		Window:Notify({ Title = "Hello", Text = "Notifications slide in and stack.", Duration = 4 })
	end,
})

-- RightShift opens/closes the window (rebind it under Settings > Toggle UI).
-- The Settings tab is added automatically and is always last.

]]
