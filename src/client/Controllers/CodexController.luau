--!strict
--[[
	CodexController
	StarterPlayerScripts/Client/Controllers/CodexController

	Hook 3 on the client: the Field Camera and the Cryptid Codex screen.

	Field Camera (the tool CodexService gives every spawn):
	  * While it's in your hand, a camcorder viewfinder covers the screen:
	    corner brackets, a blinking REC light, a battery that recharges
	    between shots, the in-game clock, and the name of the cryptid you're
	    aiming at (outlined in the world) or "No cryptid in view".
	  * Aiming: a ray through the mouse pointer (or the screen centre on
	    touch / gamepad) up to Config.Codex.MaxPhotoDistance; the nearest
	    tagged cryptid model it passes through wins. Cryptid parts aren't
	    raycastable (CanQuery off), so the ray is tested against each
	    model's bounding box, stopping at the first wall. If it misses, the
	    cryptid closest to the screen centre within FallbackConeDegrees
	    counts (forgiving on phones).
	  * Click / tap: white shutter flash + CameraShutter sound, then
	    TakePhoto(model). The server checks everything again.

	Celebrations (from the server's CodexDiscovered event, so hatches and
	claims celebrate too): a "NEW CODEX ENTRY" polaroid + CodexNew sound;
	a completed rarity page adds a "<Rarity> page complete!" banner +
	PageComplete sound. Several at once queue up.

	Codex screen (the kit's Index screen, renamed CODEX; HUD Index button):
	one card per creature in Config order, cloned from the kit's rarity
	sample cards. Each card is a ViewportFrame "evidence photo" — warm tint,
	thin border, faint scanlines — or a black silhouette with "???" until
	discovered. The Secret is always glitched. Side buttons filter by rarity
	and show progress; the search box filters by name; tapping a card opens
	its file (name, rarity, income, blurb from Config.Codex.Blurbs, status).
	Cards and their 3D photos are built the first time the screen opens.
	The HUD button shows a "!" when something new was logged since you last
	looked.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Kit = require(Components:WaitForChild("Kit"))
local ScreenScale = require(Components:WaitForChild("ScreenScale"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local HudController = require(script.Parent:WaitForChild("HudController"))

local CodexController = {}

local localPlayer = Players.LocalPlayer
local codexConfig = Config.Codex

-- Not designer-tunable: small visual details and a latency allowance.
local LATENCY_MARGIN = 0.15        -- client waits a hair longer than the server cooldown
local GLITCH_JITTER = 0.06         -- how far (fraction of the photo) the Secret jumps
local GLITCH_JUMP_CHANCE = 0.35
local GLITCH_FADE_CHANCE = 0.25
local GLITCH_LIT = { Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 70, 70), Color3.fromRGB(150, 150, 160) }
local GLITCH_DARK = { Color3.new(0, 0, 0), Color3.fromRGB(45, 0, 0), Color3.fromRGB(28, 28, 32) }
local SECRET_OUTLINE = Color3.fromRGB(255, 50, 50)
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local KIT_FONT = Font.fromEnum(Enum.Font.FredokaOne)
local BODY_FONT = Font.fromEnum(Enum.Font.GothamBold)
local HEAVY_FONT = Font.fromEnum(Enum.Font.GothamBlack)
local HAND_FONT = Font.fromEnum(Enum.Font.PermanentMarker)

local PHOTO_TAGS = { Config.Tags.Creature, Config.Tags.WildCryptid, Config.Tags.CarriedItem }

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

-- SoundController is written in parallel and may not exist yet: look it up
-- lazily and treat a missing one as silence.
local soundModule: any = nil
local function playSound(name: string)
	if not soundModule then
		local moduleScript = script.Parent:FindFirstChild("SoundController")
		if not moduleScript then
			return
		end
		local ok, loaded = pcall(require, moduleScript)
		if not ok then
			return
		end
		soundModule = loaded
	end
	if typeof(soundModule) == "table" and typeof(soundModule.Play) == "function" then
		pcall(soundModule.Play, name)
	end
end

local function getCodex(): { [string]: any }
	local snapshot = ProfileController.Get()
	local codex = snapshot and snapshot.Codex
	return if typeof(codex) == "table" then codex else {}
end

local function isDiscovered(creatureId: string): boolean
	return getCodex()[creatureId] == true
end

local function isSecret(rarity: string): boolean
	local def = Config.Rarities[rarity]
	return def ~= nil and def.NeverRenderClearly == true
end

--- (found, total) for one rarity, or every creature when rarity is nil.
local function progress(rarity: string?): (number, number)
	local codex = getCodex()
	local found, total = 0, 0
	for _, creature in ipairs(Config.Creatures) do
		if rarity == nil or creature.Rarity == rarity then
			total += 1
			if codex[creature.Id] == true then
				found += 1
			end
		end
	end
	return found, total
end

local function completePages(): number
	local pages = 0
	for _, rarity in ipairs(Config.RarityOrder) do
		local found, total = progress(rarity)
		if total > 0 and found == total then
			pages += 1
		end
	end
	return pages
end

local function corner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

local function textLabel(props: { [string]: any }): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.TextColor3 = WHITE
	label.FontFace = BODY_FONT
	label.TextScaled = true
	for key, value in pairs(props) do
		if key ~= "Parent" then
			(label :: any)[key] = value
		end
	end
	label.Parent = props.Parent
	return label
end

local function maxTextSize(label: TextLabel, size: number)
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = size
	constraint.Parent = label
end

local function outlineText(label: TextLabel, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = BLACK
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label
end

--------------------------------------------------------------------------
-- Evidence photos (ViewportFrames)
--------------------------------------------------------------------------

type GlitchState = { Base: UDim2, Lit: boolean }
local glitched: { [ViewportFrame]: GlitchState } = {}

--- A ViewportFrame showing the creature, framed by its own camera.
local function buildPhoto(creatureId: string, parent: Instance, zIndex: number): ViewportFrame
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Photo"
	viewport.BackgroundTransparency = 1
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.Position = UDim2.fromScale(0.5, 0.5)
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.ZIndex = zIndex
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)

	local ok, model = pcall(ItemVisuals.BuildCreature, creatureId, nil)
	if ok and model then
		model.Parent = viewport
		local camera = Instance.new("Camera")
		camera.FieldOfView = codexConfig.CardCameraFov
		local boxCf, boxSize = model:GetBoundingBox()
		local radius = boxSize.Magnitude / 2
		local distance = radius / math.tan(math.rad(codexConfig.CardCameraFov / 2)) * codexConfig.CardCameraPadding
		-- Creatures face -Z: look at them from the front, a little to the side and above.
		local direction = Vector3.new(0.5, 0.3, -1).Unit
		camera.CFrame = CFrame.lookAt(boxCf.Position + direction * distance, boxCf.Position)
		camera.Parent = viewport
		viewport.CurrentCamera = camera
	else
		warn("[SAC/Codex] couldn't build a photo of " .. creatureId .. ": " .. tostring(model))
	end
	viewport.Parent = parent
	return viewport
end

--- Full-colour "evidence" lighting, or a black silhouette.
local function setPhotoLit(viewport: ViewportFrame, creatureId: string, lit: boolean)
	if lit then
		viewport.Ambient = codexConfig.EvidenceAmbient
		viewport.LightColor = codexConfig.EvidenceLight
		viewport.ImageColor3 = codexConfig.EvidenceTint
	else
		viewport.Ambient = BLACK
		viewport.LightColor = BLACK
		viewport.ImageColor3 = BLACK
	end
	viewport.ImageTransparency = 0
	local def = Config.CreaturesById[creatureId]
	if def and isSecret(def.Rarity) then
		local state = glitched[viewport]
		if state then
			state.Lit = lit
		else
			glitched[viewport] = { Base = viewport.Position, Lit = lit }
		end
	end
end

--- Faint horizontal scanlines over a photo.
local function addScanlines(parent: Instance, zIndex: number): Frame
	local lines = Instance.new("Frame")
	lines.Name = "Scanlines"
	lines.BackgroundColor3 = BLACK
	lines.BorderSizePixel = 0
	lines.Size = UDim2.fromScale(1, 1)
	lines.ZIndex = zIndex
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	local keypoints = {}
	local count = 19 -- NumberSequence allows at most 20 keypoints
	for i = 0, count - 1 do
		local value = if i % 2 == 0 then codexConfig.ScanlineTransparency else 1
		table.insert(keypoints, NumberSequenceKeypoint.new(i / (count - 1), value))
	end
	gradient.Transparency = NumberSequence.new(keypoints)
	gradient.Parent = lines
	lines.Parent = parent
	return lines
end

--- A black "redacted" bar across a photo (the Secret only).
local function addRedactionBar(parent: Instance, zIndex: number)
	local bar = Instance.new("Frame")
	bar.Name = "Redacted"
	bar.BackgroundColor3 = BLACK
	bar.BorderSizePixel = 0
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(0.5, 0.36)
	bar.Size = UDim2.fromScale(0.78, 0.13)
	bar.Rotation = -6
	bar.ZIndex = zIndex
	bar.Parent = parent
end

local function startGlitchLoop()
	task.spawn(function()
		while true do
			task.wait(codexConfig.SecretGlitchInterval)
			for viewport, state in pairs(glitched) do
				if not viewport.Parent then
					glitched[viewport] = nil
					continue
				end
				if math.random() < GLITCH_JUMP_CHANCE then
					viewport.Position = state.Base + UDim2.fromScale(
						(math.random() - 0.5) * GLITCH_JITTER, (math.random() - 0.5) * GLITCH_JITTER * 0.5)
				else
					viewport.Position = state.Base
				end
				viewport.ImageTransparency = if math.random() < GLITCH_FADE_CHANCE then 0.3 + math.random() * 0.5 else 0
				local palette = if state.Lit then GLITCH_LIT else GLITCH_DARK
				viewport.ImageColor3 = palette[math.random(1, #palette)]
			end
		end
	end)
end

--------------------------------------------------------------------------
-- Codex screen
--------------------------------------------------------------------------

type Card = {
	Id: string,
	Def: any,
	Frame: GuiObject,
	Icon: GuiObject,
	NameLabel: TextLabel?,
	Viewport: ViewportFrame?,
	Scanlines: Frame?,
	Border: UIStroke?,
}

local popup: Kit.Popup? = nil
local gui: ScreenGui? = nil
local built = false
local cards: { Card } = {}
local filter = "All"
local query = ""

local counterLabel: TextLabel? = nil
local pageLabel: TextLabel? = nil
local filterButtons: { [string]: { Frame: Instance, Label: TextLabel?, Background: ImageLabel? } } = {}

-- Details panel
local details: Frame? = nil
local detailParts: { [string]: any } = {}

local function rarityGradient(rarity: string): ColorSequence
	if isSecret(rarity) then
		return ColorSequence.new(Color3.fromRGB(205, 205, 215), Color3.fromRGB(70, 70, 82))
	end
	local base = Config.Rarities[rarity].Color
	return ColorSequence.new(base:Lerp(WHITE, 0.35), base:Lerp(BLACK, 0.5))
end

local function renderCard(card: Card)
	local found = isDiscovered(card.Id)
	if card.NameLabel then
		card.NameLabel.Text = if found then card.Def.Name else "???"
	end
	if card.Viewport then
		setPhotoLit(card.Viewport, card.Id, found)
	end
	if card.Scanlines then
		card.Scanlines.Visible = found
	end
	if card.Border then
		card.Border.Enabled = found
	end
end

local function applyFilter()
	for _, card in ipairs(cards) do
		local rarityOk = filter == "All" or card.Def.Rarity == filter
		local nameOk = query == ""
			or string.find(string.lower(card.Def.Name), query, 1, true) ~= nil
			or string.find(card.Id, query, 1, true) ~= nil
		card.Frame.Visible = rarityOk and nameOk
	end
	for key, button in pairs(filterButtons) do
		if button.Background then
			button.Background.ImageColor3 = if key == filter then WHITE else Color3.fromRGB(140, 140, 150)
		end
	end
end

local function refreshCounters()
	local found, total = progress(nil)
	Kit.SetText(counterLabel, string.format("DISCOVERED: %d/%d", found, total))
	local pages = completePages()
	Kit.SetText(pageLabel, string.format("Pages %d/%d  ·  +%g%% luck", pages, #Config.RarityOrder,
		pages * Config.Luck.CodexPageCompletePercent))
	for key, button in pairs(filterButtons) do
		local f, t = progress(if key == "All" then nil else key)
		Kit.SetText(button.Label, string.format("%s %d/%d", key, f, t))
	end
end

local lastSignature: string? = nil

local function refreshScreen()
	if not built then
		return
	end
	-- Profile pushes happen all the time (cash); only redraw when the
	-- Codex itself changed.
	local codex = getCodex()
	local bits = table.create(#Config.Creatures, "0")
	for i, creature in ipairs(Config.Creatures) do
		if codex[creature.Id] == true then
			bits[i] = "1"
		end
	end
	local signature = table.concat(bits)
	if signature == lastSignature then
		return
	end
	lastSignature = signature
	for _, card in ipairs(cards) do
		renderCard(card)
	end
	refreshCounters()
	-- An open file follows changes too (e.g. you photograph it meanwhile).
	local open = details
	if open and open.Visible and detailParts.CurrentId then
		local showDetails = detailParts.Show
		if typeof(showDetails) == "function" then
			showDetails(detailParts.CurrentId)
		end
	end
end

local function buildDetails(content: GuiObject)
	local panel = Instance.new("Frame")
	panel.Name = "CodexFile"
	panel.BackgroundColor3 = Color3.fromRGB(26, 24, 34)
	panel.BackgroundTransparency = 0.02
	panel.Size = UDim2.fromScale(1, 1)
	panel.ZIndex = 50
	panel.Active = true
	panel.Visible = false
	corner(panel, UDim.new(0.04, 0))
	panel.Parent = content

	-- The polaroid.
	local polaroid = Instance.new("Frame")
	polaroid.Name = "Polaroid"
	polaroid.BackgroundColor3 = codexConfig.EvidenceBorder
	polaroid.AnchorPoint = Vector2.new(0, 0.5)
	polaroid.Position = UDim2.fromScale(0.04, 0.5)
	polaroid.Size = UDim2.fromScale(0.4, 0.86)
	polaroid.ZIndex = 51
	corner(polaroid, UDim.new(0.03, 0))
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 0.85
	aspect.Parent = polaroid
	polaroid.Parent = panel

	local photoHolder = Instance.new("Frame")
	photoHolder.Name = "PhotoHolder"
	photoHolder.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	photoHolder.BorderSizePixel = 0
	photoHolder.Position = UDim2.fromScale(0.07, 0.06)
	photoHolder.Size = UDim2.fromScale(0.86, 0.72)
	photoHolder.ClipsDescendants = true
	photoHolder.ZIndex = 52
	photoHolder.Parent = polaroid

	local caption = textLabel({
		Name = "Caption",
		FontFace = HAND_FONT,
		TextColor3 = Color3.fromRGB(44, 40, 52),
		Position = UDim2.fromScale(0.07, 0.8),
		Size = UDim2.fromScale(0.86, 0.15),
		ZIndex = 52,
		Parent = polaroid,
	})

	-- The file text.
	local nameLabel = textLabel({
		Name = "CreatureName",
		FontFace = KIT_FONT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.5, 0.07),
		Size = UDim2.fromScale(0.46, 0.15),
		ZIndex = 51,
		Parent = panel,
	})
	maxTextSize(nameLabel, 40)
	local rarityLabel = textLabel({
		Name = "Rarity",
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.5, 0.23),
		Size = UDim2.fromScale(0.46, 0.08),
		ZIndex = 51,
		Parent = panel,
	})
	maxTextSize(rarityLabel, 24)
	local incomeLabel = textLabel({
		Name = "Income",
		TextColor3 = Color3.fromRGB(170, 250, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.5, 0.32),
		Size = UDim2.fromScale(0.46, 0.07),
		ZIndex = 51,
		Parent = panel,
	})
	maxTextSize(incomeLabel, 22)
	local blurbLabel = textLabel({
		Name = "Blurb",
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		TextColor3 = Color3.fromRGB(226, 220, 208),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.46, 0.3),
		ZIndex = 51,
		Parent = panel,
	})
	maxTextSize(blurbLabel, 20)

	local statusIcon = Instance.new("ImageLabel")
	statusIcon.Name = "StatusIcon"
	statusIcon.BackgroundTransparency = 1
	statusIcon.Image = Config.Icons.CheckMark or ""
	statusIcon.ScaleType = Enum.ScaleType.Fit
	statusIcon.Position = UDim2.fromScale(0.5, 0.75)
	statusIcon.Size = UDim2.fromScale(0.05, 0.08)
	statusIcon.ZIndex = 51
	statusIcon.Parent = panel
	local statusLabel = textLabel({
		Name = "Status",
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.56, 0.75),
		Size = UDim2.fromScale(0.4, 0.08),
		ZIndex = 51,
		Parent = panel,
	})
	maxTextSize(statusLabel, 20)

	local back = Instance.new("TextButton")
	back.Name = "Back"
	back.AutoButtonColor = true
	back.BackgroundColor3 = Color3.fromRGB(72, 64, 96)
	back.TextColor3 = WHITE
	back.FontFace = KIT_FONT
	back.TextScaled = true
	back.Text = "BACK"
	back.AnchorPoint = Vector2.new(1, 1)
	back.Position = UDim2.fromScale(0.96, 0.95)
	back.Size = UDim2.fromScale(0.2, 0.12)
	back.ZIndex = 52
	corner(back, UDim.new(0.25, 0))
	local backPadding = Instance.new("UIPadding")
	backPadding.PaddingTop = UDim.new(0.18, 0)
	backPadding.PaddingBottom = UDim.new(0.18, 0)
	backPadding.Parent = back
	back.Parent = panel
	back.Activated:Connect(function()
		panel.Visible = false
		detailParts.CurrentId = nil
	end)

	local function show(creatureId: string)
		local def = Config.CreaturesById[creatureId]
		if not def then
			return
		end
		local rarity = Config.Rarities[def.Rarity]
		local found = isDiscovered(creatureId)
		detailParts.CurrentId = creatureId

		-- Rebuild the photo only when the creature changes.
		if detailParts.PhotoId ~= creatureId then
			photoHolder:ClearAllChildren()
			detailParts.Viewport = buildPhoto(creatureId, photoHolder, 53)
			detailParts.Scanlines = addScanlines(photoHolder, 54)
			if isSecret(def.Rarity) then
				addRedactionBar(photoHolder, 55)
			end
			detailParts.PhotoId = creatureId
		end
		setPhotoLit(detailParts.Viewport, creatureId, found)
		detailParts.Scanlines.Visible = found

		caption.Text = if found then def.Name else "???"
		nameLabel.Text = def.Name
		rarityLabel.Text = string.upper(def.Rarity)
		rarityLabel.TextColor3 = if isSecret(def.Rarity) then SECRET_OUTLINE else rarity.Color
		incomeLabel.Text = string.format("Earns $%s/s", Config.FormatNumber(rarity.IncomePerSecond))
		if found then
			blurbLabel.Text = codexConfig.Blurbs[creatureId] or "No field notes yet."
			statusIcon.Visible = true
			statusLabel.Position = UDim2.fromScale(0.56, 0.75)
			statusLabel.Size = UDim2.fromScale(0.4, 0.08)
			statusLabel.TextColor3 = Color3.fromRGB(140, 235, 150)
			statusLabel.Text = "Photographed"
		else
			blurbLabel.Text = "No file yet. Photograph one with your Field Camera, or hatch or capture one, to unlock its notes."
			statusIcon.Visible = false
			statusLabel.Position = UDim2.fromScale(0.5, 0.75)
			statusLabel.Size = UDim2.fromScale(0.46, 0.08)
			statusLabel.TextColor3 = Color3.fromRGB(255, 214, 120)
			statusLabel.Text = "Not seen yet — photograph one to log it"
		end
		panel.Visible = true
	end
	detailParts.Show = show

	details = panel
end

local function closeDetails()
	if details then
		details.Visible = false
	end
	detailParts.CurrentId = nil
end

--- Turns the kit's Index screen into the Codex. Runs on first open.
local function buildScreen()
	if built or not gui then
		return
	end
	built = true
	local root = gui :: ScreenGui

	local navBar = Kit.Deep(root, "NavBar")
	local content = Kit.Deep(root, "Content")
	local list = content and content:FindFirstChildOfClass("ScrollingFrame")
	if not navBar or not content or not list then
		warn("[SAC/Codex] the kit's Index screen isn't the shape we expect; Codex screen not built")
		return
	end

	-- Header: title, page luck, counter, search.
	local title = navBar:FindFirstChild("Title")
	Kit.SetText(title, "CODEX")
	if title and title:IsA("TextLabel") then
		local luck = title:Clone()
		luck.Name = "PageLuck"
		luck.AnchorPoint = Vector2.new(0, 0.5)
		luck.Position = UDim2.fromScale(0.37, 0.5)
		luck.Size = UDim2.fromScale(0.52, 0.48)
		luck.TextXAlignment = Enum.TextXAlignment.Right
		luck.Parent = navBar
		pageLabel = luck
	end
	local top = content:FindFirstChild("TopContents")
	if top then
		local counter = top:FindFirstChild("TextLabel")
		if counter and counter:IsA("TextLabel") then
			counterLabel = counter
		end
		local box = Kit.Deep(top, "TextBox")
		if box and box:IsA("TextBox") then
			box.PlaceholderText = "Search cryptids..."
			box.Text = ""
			box:GetPropertyChangedSignal("Text"):Connect(function()
				query = string.lower(box.Text)
				closeDetails()
				applyFilter()
			end)
		end
	end

	-- Sample cards: one per rarity name, then clear the kit's list.
	local samples: { [string]: GuiObject } = {}
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("GuiObject") then
			if not samples[child.Name] and child:FindFirstChild("ItemButton") then
				samples[child.Name] = child
			end
			child.Parent = nil
		end
	end
	local function sampleFor(rarity: string): GuiObject?
		if samples[rarity] then
			return samples[rarity]
		end
		-- Closest kit sample for rarities it doesn't have.
		local fallback = if rarity == "Epic" then samples.Rare or samples.Mythic
			elseif rarity == "Secret" then samples.Mythic or samples.Legendary
			else nil
		if fallback then
			return fallback
		end
		for _, sample in pairs(samples) do
			return sample
		end
		return nil
	end

	-- A grid sized in pixels: the kit's scale-sized cards would shrink with
	-- the canvas when a filter shows only one row.
	local oldLayout = list:FindFirstChildWhichIsA("UIGridStyleLayout")
	if oldLayout then
		oldLayout:Destroy()
	end
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.FillDirectionMaxCells = codexConfig.CardsPerRow
	grid.Parent = list
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	local function sizeGrid()
		local perRow = codexConfig.CardsPerRow
		local width = list.AbsoluteSize.X - list.ScrollBarThickness - 2
		if width <= perRow then
			return
		end
		local gap = math.max(2, math.floor(width * 0.012))
		local cell = math.max(4, math.floor((width - gap * (perRow - 1)) / perRow))
		grid.CellSize = UDim2.fromOffset(cell, cell)
		grid.CellPadding = UDim2.fromOffset(gap, gap)
	end
	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeGrid)
	sizeGrid()

	-- One card per creature, in Config order.
	for index, def in ipairs(Config.Creatures) do
		local sample = sampleFor(def.Rarity)
		if not sample then
			break
		end
		local frame = sample:Clone()
		frame.Name = "Card_" .. def.Id
		frame.LayoutOrder = index
		frame.Visible = true
		for _, d in ipairs(frame:GetChildren()) do
			if d:IsA("UIAspectRatioConstraint") or d:IsA("UISizeConstraint") then
				d:Destroy()
			end
		end

		-- Rarity tag (recoloured for rarities the kit has no sample for).
		local rarityText = frame:FindFirstChildOfClass("TextLabel")
		if rarityText then
			rarityText.Text = string.upper(def.Rarity)
			if not samples[def.Rarity] then
				local gradient = rarityText:FindFirstChildOfClass("UIGradient")
				if gradient then
					gradient.Color = rarityGradient(def.Rarity)
				end
			end
		end

		-- Name along the bottom, styled like the rarity tag.
		local nameLabel: TextLabel? = nil
		if rarityText then
			local copy = rarityText:Clone()
			copy.Name = "CreatureName"
			copy.AnchorPoint = Vector2.new(0.5, 1)
			copy.Position = UDim2.fromScale(0.5, 0.96)
			copy.Size = UDim2.fromScale(0.9, 0.15)
			local gradient = copy:FindFirstChildOfClass("UIGradient")
			if gradient then
				gradient.Color = ColorSequence.new(WHITE, Color3.fromRGB(205, 205, 205))
			end
			copy.Parent = frame
			nameLabel = copy
		end

		-- The photo goes where the kit's sample icon was.
		local button = frame:FindFirstChild("ItemButton")
		local icon = button and button:FindFirstChild("Icon")
		local iconFrame: GuiObject = if icon and icon:IsA("GuiObject") then icon else frame
		if icon and icon:IsA("ImageLabel") then
			icon.Image = ""
			icon.ImageTransparency = 1
		end
		iconFrame.ClipsDescendants = true

		local card: Card = {
			Id = def.Id,
			Def = def,
			Frame = frame,
			Icon = iconFrame,
			NameLabel = nameLabel,
		}
		table.insert(cards, card)

		if button and button:IsA("GuiButton") then
			button.Activated:Connect(function()
				playSound("UIClick")
				local show = detailParts.Show
				if typeof(show) == "function" then
					show(def.Id)
				end
			end)
		end
		frame.Parent = list
	end

	-- Photos: built now, the first time the screen opens.
	for _, card in ipairs(cards) do
		local photo = buildPhoto(card.Id, card.Icon, card.Icon.ZIndex + 1)
		card.Viewport = photo
		card.Scanlines = addScanlines(card.Icon, card.Icon.ZIndex + 2)
		local border = Instance.new("UIStroke")
		border.Color = codexConfig.EvidenceBorder
		border.Thickness = 2
		border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		border.Parent = card.Icon
		card.Border = border
		if isSecret(card.Def.Rarity) then
			addRedactionBar(card.Icon, card.Icon.ZIndex + 3)
		end
	end
	for _, sample in pairs(samples) do
		sample:Destroy()
	end
	Kit.FitCanvas(list)

	-- Side buttons become rarity filters: All, then every rarity.
	local side = Kit.Deep(root, "SideButtons")
	if side then
		local kitButtons = Kit.ChildrenNamed(side, "SideButton")
		local template: any = nil
		for _, b in ipairs(kitButtons) do
			local label = Kit.Deep(b, "TextLabel")
			if label and label:IsA("TextLabel") and not label:FindFirstChildOfClass("UIGradient") then
				template = b -- the plain one ("Normal")
				break
			end
		end
		template = template or kitButtons[1]
		if template then
			template.Parent = nil
			for _, b in ipairs(kitButtons) do
				if b ~= template then
					b:Destroy()
				end
			end
			local keys = { "All" }
			for _, rarity in ipairs(Config.RarityOrder) do
				table.insert(keys, rarity)
			end
			local gap = 0.01
			local height = (1 - gap * (#keys - 1)) / #keys
			local listLayout = side:FindFirstChildOfClass("UIListLayout")
			if listLayout then
				listLayout.Padding = UDim.new(gap, 0)
				listLayout.SortOrder = Enum.SortOrder.LayoutOrder
			end
			for i, key in ipairs(keys) do
				local b: any = template:Clone()
				b.Name = "Filter_" .. key
				b.LayoutOrder = i
				if b:IsA("GuiObject") then
					b.Size = UDim2.fromScale(1, height)
				end
				local label = Kit.Deep(b, "TextLabel")
				if label and label:IsA("TextLabel") and key ~= "All" then
					local gradient = Instance.new("UIGradient")
					gradient.Rotation = 90
					gradient.Color = rarityGradient(key)
					gradient.Parent = label
				end
				local background = Kit.Deep(b, "StudBackground")
				filterButtons[key] = {
					Frame = b,
					Label = if label and label:IsA("TextLabel") then label else nil,
					Background = if background and background:IsA("ImageLabel") then background else nil,
				}
				local container = b:FindFirstChild("Container")
				if container and container:IsA("GuiButton") then
					container.Activated:Connect(function()
						playSound("UIClick")
						filter = key
						closeDetails()
						list.CanvasPosition = Vector2.zero
						applyFilter()
					end)
				end
				b.Parent = side
			end
			template:Destroy()
		end
	end

	buildDetails(content)
	refreshScreen()
	applyFilter()
end

function CodexController.Open()
	local p = popup
	if not p then
		return
	end
	HudController.SetAlert("IndexBtn", false)
	playSound("UIOpen")
	p:Open()
end

--------------------------------------------------------------------------
-- Celebrations
--------------------------------------------------------------------------

local celebrateGui: ScreenGui? = nil
type Celebration = { Id: string, Page: string?, Delay: number }
local celebrationQueue: { Celebration } = {}
local celebrating = false

local function showPageBanner(rarity: string)
	local parent = celebrateGui
	if not parent then
		return
	end
	playSound("PageComplete")
	local color = if isSecret(rarity) then SECRET_OUTLINE else Config.Rarities[rarity].Color

	local banner = Instance.new("Frame")
	banner.Name = "PageBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, -120)
	banner.Size = UDim2.fromOffset(560, 70)
	banner.BackgroundColor3 = color:Lerp(BLACK, 0.55)
	banner.BackgroundTransparency = 0.05
	corner(banner, UDim.new(0, 14))
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 220, 120)
	stroke.Thickness = 3
	stroke.Parent = banner
	local label = textLabel({
		FontFace = KIT_FONT,
		Text = string.format("%s page complete! +%g%% luck forever", rarity, Config.Luck.CodexPageCompletePercent),
		Position = UDim2.fromScale(0.04, 0.12),
		Size = UDim2.fromScale(0.92, 0.76),
		Parent = banner,
	})
	outlineText(label, 2)
	banner.Parent = parent
	ScreenScale.Apply(banner)

	TweenService:Create(banner, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 0.12) }):Play()
	task.delay(codexConfig.PageBannerTime, function()
		local out = TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 0, -120) })
		out:Play()
		out.Completed:Wait()
		banner:Destroy()
	end)
end

--- The "NEW CODEX ENTRY" polaroid. Yields while it's on screen.
local function showPolaroid(creatureId: string)
	local parent = celebrateGui
	local def = Config.CreaturesById[creatureId]
	if not parent or not def then
		return
	end
	playSound("CodexNew")
	local rarity = Config.Rarities[def.Rarity]

	local holder = Instance.new("Frame")
	holder.Name = "NewEntry"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, -0.5)
	holder.Size = UDim2.fromOffset(240, 300)
	holder.Parent = parent
	ScreenScale.Apply(holder)

	local header = textLabel({
		FontFace = KIT_FONT,
		Text = "NEW CODEX ENTRY",
		TextColor3 = Color3.fromRGB(255, 226, 120),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -10),
		Size = UDim2.fromOffset(380, 44),
		Parent = holder,
	})
	outlineText(header, 3)

	local card = Instance.new("Frame")
	card.Name = "Polaroid"
	card.BackgroundColor3 = codexConfig.EvidenceBorder
	card.Size = UDim2.fromScale(1, 1)
	corner(card, UDim.new(0, 6))
	card.Parent = holder

	local photo = Instance.new("Frame")
	photo.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	photo.BorderSizePixel = 0
	photo.Position = UDim2.fromScale(0.06, 0.05)
	photo.Size = UDim2.fromScale(0.88, 0.72)
	photo.ClipsDescendants = true
	photo.Parent = card
	local viewport = buildPhoto(creatureId, photo, 2)
	setPhotoLit(viewport, creatureId, true)
	addScanlines(photo, 3)
	if isSecret(def.Rarity) then
		addRedactionBar(photo, 4)
	end

	textLabel({
		FontFace = HAND_FONT,
		Text = def.Name,
		TextColor3 = Color3.fromRGB(44, 40, 52),
		Position = UDim2.fromScale(0.06, 0.8),
		Size = UDim2.fromScale(0.88, 0.16),
		Parent = card,
	})

	local tag = textLabel({
		FontFace = KIT_FONT,
		Text = string.upper(def.Rarity),
		TextColor3 = if isSecret(def.Rarity) then SECRET_OUTLINE else rarity.Color,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 10),
		Size = UDim2.fromOffset(260, 32),
		Parent = holder,
	})
	outlineText(tag, 2)

	TweenService:Create(holder, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 0.48) }):Play()
	task.wait(codexConfig.NewEntryBannerTime)
	local out = TweenService:Create(holder, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = UDim2.fromScale(0.5, 1.6) })
	out:Play()
	out.Completed:Wait()
	holder:Destroy()
end

local function runCelebrations()
	if celebrating then
		return
	end
	celebrating = true
	while #celebrationQueue > 0 do
		local item = table.remove(celebrationQueue, 1) :: Celebration
		if item.Delay > 0 then
			task.wait(item.Delay)
		end
		-- Let a hatch reveal (FeedbackController) finish first, so the two
		-- celebrations don't pile on top of each other.
		local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local waitUntil = os.clock() + 10
		while playerGui and playerGui:FindFirstChild("HatchReveal") and os.clock() < waitUntil do
			task.wait(0.2)
		end
		local page = item.Page
		if page then
			task.delay(0.6, showPageBanner, page)
		end
		showPolaroid(item.Id)
	end
	celebrating = false
end

local function celebrate(creatureId: string, page: string?, delay: number)
	if #celebrationQueue >= codexConfig.MaxQueuedCelebrations then
		-- Too many at once (e.g. a debug bulk add): keep it short.
		local def = Config.CreaturesById[creatureId]
		NotificationController.Show(string.format("Codex: %s logged!", def and def.Name or "a cryptid"), "Success")
		if page then
			showPageBanner(page)
		end
		return
	end
	table.insert(celebrationQueue, { Id = creatureId, Page = page, Delay = delay })
	task.spawn(runCelebrations)
end

--------------------------------------------------------------------------
-- Field Camera: aiming
--------------------------------------------------------------------------

--- The creature id a photographable model shows (mirrors CodexService).
local function creatureIdOf(model: Instance): string?
	if not model:IsA("Model") then
		return nil
	end
	local id: any = nil
	if CollectionService:HasTag(model, Config.Tags.Creature) or CollectionService:HasTag(model, Config.Tags.WildCryptid) then
		id = model:GetAttribute("CreatureId")
	elseif CollectionService:HasTag(model, Config.Tags.CarriedItem) and model:GetAttribute("Kind") == "Creature" then
		id = model:GetAttribute("CreatureId")
	end
	if typeof(id) == "string" and Config.CreaturesById[id] then
		return id
	end
	return nil
end

local function taggedAncestor(instance: Instance?): Model?
	local current = instance
	while current and current ~= Workspace do
		if current:IsA("Model") and creatureIdOf(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function getRoot(): BasePart?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

--- Every photographable model near enough, except one you carry yourself.
local function candidates(root: BasePart): { Model }
	local list: { Model } = {}
	local character = localPlayer.Character
	for _, tag in ipairs(PHOTO_TAGS) do
		for _, instance in ipairs(CollectionService:GetTagged(tag)) do
			if instance:IsA("Model") and instance:IsDescendantOf(Workspace) and creatureIdOf(instance)
				and not (character and instance:IsDescendantOf(character)) then
				local model = instance :: Model
				if (model:GetPivot().Position - root.Position).Magnitude <= codexConfig.MaxPhotoDistance then
					table.insert(list, model)
				end
			end
		end
	end
	return list
end

--- Distance along a ray (unit direction) to where it enters a box, or nil.
local function rayBoxDistance(origin: Vector3, direction: Vector3, boxCf: CFrame, boxSize: Vector3): number?
	local o = boxCf:PointToObjectSpace(origin)
	local d = boxCf:VectorToObjectSpace(direction)
	local half = boxSize / 2
	local tMin, tMax = -math.huge, math.huge
	local function slab(oa: number, da: number, h: number): boolean
		if math.abs(da) < 1e-6 then
			return oa >= -h and oa <= h
		end
		local t1 = (-h - oa) / da
		local t2 = (h - oa) / da
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		return tMin <= tMax
	end
	if not slab(o.X, d.X, half.X) or not slab(o.Y, d.Y, half.Y) or not slab(o.Z, d.Z, half.Z) then
		return nil
	end
	if tMax < 0 then
		return nil
	end
	return math.max(tMin, 0)
end

local function usingMouse(): boolean
	if not UserInputService.MouseEnabled then
		return false
	end
	local last = UserInputService:GetLastInputType()
	return last == Enum.UserInputType.MouseMovement or last == Enum.UserInputType.MouseButton1
		or last == Enum.UserInputType.MouseButton2 or last == Enum.UserInputType.MouseButton3
		or last == Enum.UserInputType.MouseWheel or last == Enum.UserInputType.Keyboard
end

--- The first thing along a ray that really blocks the view, using the same
--- lenient rule as the server (CodexService): parts you can walk through or
--- mostly see through (leaves, glass, invisible barriers, trigger zones)
--- are skipped. Skipped parts are added to `params` for later rays too.
local function solidHit(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
	for _ = 1, codexConfig.LosMaxPierce do
		local result = Workspace:Raycast(origin, direction, params)
		if not result then
			return nil
		end
		local hit = result.Instance
		if hit:IsA("BasePart") and not taggedAncestor(hit)
			and (not hit.CanCollide or hit.Transparency >= codexConfig.LosIgnoreTransparency) then
			params:AddToFilter(hit)
		else
			return result
		end
	end
	return nil -- lots of see-through clutter: let the server decide
end

--- The cryptid the camera is pointing at, or nil.
local function pickTarget(): Model?
	local camera = Workspace.CurrentCamera
	local root = getRoot()
	if not camera or not root then
		return nil
	end
	local point = if usingMouse() then UserInputService:GetMouseLocation() else camera.ViewportSize / 2
	local ray = camera:ViewportPointToRay(point.X, point.Y)
	local origin, direction = ray.Origin, ray.Direction.Unit
	local reach = codexConfig.MaxPhotoDistance + (origin - root.Position).Magnitude

	-- People never block a photo (the server ignores every character too).
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local list = candidates(root)

	-- 1. Straight through the pointer, stopping at the first wall.
	local hit = solidHit(origin, direction * reach, params)
	local direct = hit and taggedAncestor(hit.Instance)
	if direct and table.find(list, direct) then
		return direct
	end
	local wall = if hit then hit.Distance else reach
	local best: Model? = nil
	local bestDistance = math.huge
	for _, model in ipairs(list) do
		local boxCf, boxSize = model:GetBoundingBox()
		local t = rayBoxDistance(origin, direction, boxCf, boxSize)
		if t and t <= wall + 1 and t < bestDistance then
			best, bestDistance = model, t
		end
	end
	if best then
		return best
	end

	-- 2. Forgiving fallback: closest to the screen centre, in view.
	local look = camera.CFrame.LookVector
	local eye = camera.CFrame.Position
	local bestDot = math.cos(math.rad(codexConfig.FallbackConeDegrees))
	for _, model in ipairs(list) do
		local boxCf, boxSize = model:GetBoundingBox()
		local offset = boxCf.Position - eye
		local distance = offset.Magnitude
		if distance > 0 then
			local dot = look:Dot(offset / distance)
			if dot > bestDot then
				local block = solidHit(eye, offset, params)
				if not block or block.Distance >= distance - boxSize.Magnitude / 2
					or taggedAncestor(block.Instance) == model then
					best, bestDot = model, dot
				end
			end
		end
	end
	return best
end

--------------------------------------------------------------------------
-- Field Camera: viewfinder
--------------------------------------------------------------------------

local viewGui: ScreenGui? = nil
local flashFrame: Frame? = nil
local viewParts: { [string]: any } = {}
local bracketBars: { Frame } = {}
local batteryBars: { Frame } = {}
local targetHighlight: Highlight? = nil
local currentTarget: Model? = nil
local equippedTool: Tool? = nil
local stepConnection: RBXScriptConnection? = nil
local readyAt = 0
local busy = false
local recordStart = 0

local function buildViewfinder()
	local screen = Instance.new("ScreenGui")
	screen.Name = "FieldCamera"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 0 -- under the HUD (1) so its buttons stay readable
	screen.Enabled = false

	-- Darkened edges.
	local function edge(anchor: Vector2, position: UDim2, size: UDim2, rotation: number)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = BLACK
		f.BorderSizePixel = 0
		f.AnchorPoint = anchor
		f.Position = position
		f.Size = size
		local g = Instance.new("UIGradient")
		g.Rotation = rotation
		g.Transparency = NumberSequence.new(0.45, 1)
		g.Parent = f
		f.Parent = screen
	end
	edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.18), 90)
	edge(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.18), -90)
	edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.12, 1), 0)
	edge(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.12, 1), 180)

	-- Corner brackets.
	for _, c in ipairs({ Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = c
		holder.Position = UDim2.fromScale(0.07 + 0.86 * c.X, 0.1 + 0.8 * c.Y)
		holder.Size = UDim2.fromOffset(48, 48)
		holder.Parent = screen
		ScreenScale.Apply(holder)
		local across = Instance.new("Frame")
		across.BorderSizePixel = 0
		across.BackgroundColor3 = WHITE
		across.AnchorPoint = Vector2.new(0, c.Y)
		across.Position = UDim2.fromScale(0, c.Y)
		across.Size = UDim2.new(1, 0, 0, 5)
		across.Parent = holder
		local down = across:Clone()
		down.AnchorPoint = Vector2.new(c.X, 0)
		down.Position = UDim2.fromScale(c.X, 0)
		down.Size = UDim2.new(0, 5, 1, 0)
		down.Parent = holder
		table.insert(bracketBars, across)
		table.insert(bracketBars, down)
	end

	-- Centre reticle.
	local reticle = Instance.new("Frame")
	reticle.BackgroundTransparency = 1
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(36, 36)
	reticle.Parent = screen
	ScreenScale.Apply(reticle)
	for _, spec in ipairs({
		{ UDim2.fromScale(0.5, 0), UDim2.fromOffset(3, 11) },
		{ UDim2.fromScale(0.5, 1), UDim2.fromOffset(3, 11) },
		{ UDim2.fromScale(0, 0.5), UDim2.fromOffset(11, 3) },
		{ UDim2.fromScale(1, 0.5), UDim2.fromOffset(11, 3) },
	}) do
		local tick = Instance.new("Frame")
		tick.BorderSizePixel = 0
		tick.BackgroundColor3 = WHITE
		tick.BackgroundTransparency = 0.15
		tick.AnchorPoint = Vector2.new(spec[1].X.Scale, spec[1].Y.Scale)
		tick.Position = spec[1]
		tick.Size = spec[2]
		tick.Parent = reticle
		table.insert(bracketBars, tick)
	end

	-- REC + clock, top left.
	local rec = Instance.new("Frame")
	rec.BackgroundTransparency = 1
	rec.Position = UDim2.new(0.07, 62, 0.1, 4)
	rec.Size = UDim2.fromOffset(200, 54)
	rec.Parent = screen
	ScreenScale.Apply(rec)
	local dot = Instance.new("Frame")
	dot.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	dot.BorderSizePixel = 0
	dot.Position = UDim2.fromOffset(0, 5)
	dot.Size = UDim2.fromOffset(16, 16)
	corner(dot, UDim.new(1, 0))
	dot.Parent = rec
	viewParts.RecDot = dot
	local recText = textLabel({
		Text = "REC",
		TextScaled = false,
		TextSize = 22,
		FontFace = HEAVY_FONT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(24, 0),
		Size = UDim2.fromOffset(80, 26),
		Parent = rec,
	})
	outlineText(recText, 1.5)
	local timecode = textLabel({
		Text = "00:00:00",
		TextScaled = false,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.fromOffset(200, 22),
		Parent = rec,
	})
	outlineText(timecode, 1.5)
	viewParts.Timecode = timecode

	-- Battery (recharges between shots), top right.
	local battery = Instance.new("Frame")
	battery.BackgroundTransparency = 1
	battery.AnchorPoint = Vector2.new(1, 0)
	battery.Position = UDim2.new(0.93, -62, 0.1, 6)
	battery.Size = UDim2.fromOffset(52, 22)
	battery.Parent = screen
	ScreenScale.Apply(battery)
	local shell = Instance.new("Frame")
	shell.BackgroundTransparency = 1
	shell.Size = UDim2.fromOffset(46, 22)
	local shellStroke = Instance.new("UIStroke")
	shellStroke.Color = WHITE
	shellStroke.Thickness = 2
	shellStroke.Parent = shell
	shell.Parent = battery
	local nub = Instance.new("Frame")
	nub.BorderSizePixel = 0
	nub.BackgroundColor3 = WHITE
	nub.Position = UDim2.fromOffset(47, 6)
	nub.Size = UDim2.fromOffset(4, 10)
	nub.Parent = battery
	for i = 1, 3 do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = WHITE
		bar.Position = UDim2.fromOffset(4 + (i - 1) * 14, 4)
		bar.Size = UDim2.fromOffset(11, 14)
		bar.Parent = battery
		table.insert(batteryBars, bar)
	end

	-- Night clock, bottom left (camcorder date stamp style).
	local stamp = textLabel({
		Text = "",
		TextScaled = false,
		TextSize = 18,
		FontFace = HEAVY_FONT,
		TextColor3 = Color3.fromRGB(255, 214, 120),
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.07, 62, 0.9, -4),
		Size = UDim2.fromOffset(200, 24),
		Parent = screen,
	})
	outlineText(stamp, 1.5)
	ScreenScale.Apply(stamp)
	viewParts.Stamp = stamp

	-- What you're aiming at, bottom centre.
	local info = Instance.new("Frame")
	info.BackgroundTransparency = 1
	info.AnchorPoint = Vector2.new(0.5, 1)
	info.Position = UDim2.fromScale(0.5, 0.86)
	info.Size = UDim2.fromOffset(460, 84)
	info.Parent = screen
	ScreenScale.Apply(info)
	local targetName = textLabel({
		Text = "No cryptid in view",
		TextScaled = false,
		TextSize = 28,
		FontFace = KIT_FONT,
		Size = UDim2.fromOffset(460, 34),
		Parent = info,
	})
	outlineText(targetName, 2)
	local targetSub = textLabel({
		Text = "",
		TextScaled = false,
		TextSize = 17,
		Position = UDim2.fromOffset(0, 36),
		Size = UDim2.fromOffset(460, 22),
		Parent = info,
	})
	outlineText(targetSub, 1.5)
	local hint = textLabel({
		Text = if UserInputService.TouchEnabled and not UserInputService.MouseEnabled
			then "Tap to take a photo" else "Click to take a photo",
		TextScaled = false,
		TextSize = 15,
		TextColor3 = Color3.fromRGB(205, 205, 210),
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.fromOffset(460, 20),
		Parent = info,
	})
	outlineText(hint, 1)
	viewParts.TargetName = targetName
	viewParts.TargetSub = targetSub
	viewParts.Hint = hint

	screen.Parent = localPlayer:WaitForChild("PlayerGui")
	viewGui = screen

	-- Shutter flash, above everything.
	local flashGui = Instance.new("ScreenGui")
	flashGui.Name = "CameraFlash"
	flashGui.ResetOnSpawn = false
	flashGui.IgnoreGuiInset = true
	flashGui.DisplayOrder = 30
	local flash = Instance.new("Frame")
	flash.BackgroundColor3 = WHITE
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.Parent = flashGui
	flashGui.Parent = localPlayer:WaitForChild("PlayerGui")
	flashFrame = flash

	local highlight = Instance.new("Highlight")
	highlight.Name = "CodexTarget"
	highlight.FillColor = WHITE
	highlight.FillTransparency = 0.85
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	targetHighlight = highlight
end

local function setTarget(model: Model?)
	currentTarget = model
	local highlight = targetHighlight
	local id = model and creatureIdOf(model)
	local def = id and Config.CreaturesById[id]
	local color = WHITE
	if model and def then
		color = if isSecret(def.Rarity) then SECRET_OUTLINE else Config.Rarities[def.Rarity].Color
		viewParts.TargetName.Text = def.Name
		local rarityName = string.upper(def.Rarity)
		if isDiscovered(def.Id) then
			viewParts.TargetSub.Text = rarityName .. "  ·  already in your Codex"
			viewParts.TargetSub.TextColor3 = Color3.fromRGB(200, 200, 205)
		else
			viewParts.TargetSub.Text = rarityName .. "  ·  NEW! Not in your Codex yet"
			viewParts.TargetSub.TextColor3 = Color3.fromRGB(255, 220, 110)
		end
		if highlight then
			highlight.OutlineColor = color
			highlight.Adornee = model
			highlight.Parent = Workspace.CurrentCamera
		end
	else
		viewParts.TargetName.Text = "No cryptid in view"
		viewParts.TargetSub.Text = ""
		if highlight then
			highlight.Adornee = nil
			highlight.Parent = nil
		end
	end
	for _, bar in ipairs(bracketBars) do
		bar.BackgroundColor3 = color
	end
end

local function formatGameClock(): string
	local minutes = math.floor(Lighting:GetMinutesAfterMidnight()) % (24 * 60)
	local hours = minutes // 60
	local suffix = if hours < 12 then "AM" else "PM"
	local shown = hours % 12
	if shown == 0 then
		shown = 12
	end
	return string.format("%s %d:%02d", suffix, shown, minutes % 60)
end

local function stopViewfinder()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end
	equippedTool = nil
	setTarget(nil)
	if viewGui then
		viewGui.Enabled = false
	end
end

local function startViewfinder(tool: Tool)
	equippedTool = tool
	recordStart = os.clock()
	if viewGui then
		viewGui.Enabled = true
	end
	if stepConnection then
		stepConnection:Disconnect()
	end
	local sinceCheck = math.huge
	stepConnection = RunService.Heartbeat:Connect(function(dt)
		sinceCheck += dt
		local now = os.clock()
		if sinceCheck >= codexConfig.TargetRefreshInterval then
			sinceCheck = 0
			local ok, target = pcall(pickTarget)
			setTarget(if ok then target else nil)
		end
		local elapsed = math.floor(now - recordStart)
		viewParts.Timecode.Text = string.format("%02d:%02d:%02d", elapsed // 3600, (elapsed // 60) % 60, elapsed % 60)
		viewParts.RecDot.Visible = (now - recordStart) % 1 < 0.6
		viewParts.Stamp.Text = formatGameClock()
		-- Battery recharges during the photo cooldown.
		local charge = 1
		if now < readyAt then
			charge = 1 - (readyAt - now) / (codexConfig.PhotoCooldown + LATENCY_MARGIN)
		end
		for i, bar in ipairs(batteryBars) do
			bar.Visible = charge >= i / #batteryBars - 0.001
		end
	end)
end

local function flash()
	local frame = flashFrame
	if not frame then
		return
	end
	frame.BackgroundTransparency = 0.05
	TweenService:Create(frame, TweenInfo.new(codexConfig.ShutterFlashTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }):Play()
end

local function snap()
	if busy or not equippedTool or os.clock() < readyAt then
		return
	end
	local ok0, picked = pcall(pickTarget)
	local target = if ok0 then picked else nil
	readyAt = os.clock() + codexConfig.PhotoCooldown + LATENCY_MARGIN
	flash()
	playSound("CameraShutter")
	if not target then
		NotificationController.Show("No cryptid in that shot. Aim at one and try again.", "Info")
		return
	end

	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("TakePhoto") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer(target)
	end)
	busy = false
	if not ok or typeof(result) ~= "table" then
		NotificationController.Show("Couldn't reach the server.", "Error")
		return
	end
	if not result.Ok then
		-- A failed shot didn't start the server cooldown: let them retry soon.
		readyAt = math.min(readyAt, os.clock() + LATENCY_MARGIN)
		-- (An "Error" toast plays the Error sound itself.)
		NotificationController.Show(tostring(result.Message or "That photo didn't come out."), "Error")
	elseif not result.IsNew then
		local def = Config.CreaturesById[tostring(result.CreatureId)]
		NotificationController.Show(string.format("%s is already in your Codex.", def and def.Name or "That cryptid"), "Info")
	end
	-- A new entry celebrates through CodexDiscovered (same path as hatches).
end

local hookedTools: { [Tool]: boolean } = {}

local function hookTool(instance: Instance)
	if not instance:IsA("Tool") or instance.Name ~= codexConfig.CameraToolName then
		return
	end
	local tool = instance :: Tool
	if hookedTools[tool] then
		return
	end
	hookedTools[tool] = true
	tool.Equipped:Connect(function()
		startViewfinder(tool)
	end)
	tool.Unequipped:Connect(function()
		if equippedTool == tool then
			stopViewfinder()
		end
	end)
	tool.Activated:Connect(snap)
	tool.Destroying:Connect(function()
		hookedTools[tool] = nil
		if equippedTool == tool then
			stopViewfinder()
		end
	end)
	if localPlayer.Character and tool.Parent == localPlayer.Character then
		startViewfinder(tool)
	end
end

local function watchContainer(container: Instance)
	for _, child in ipairs(container:GetChildren()) do
		hookTool(child)
	end
	container.ChildAdded:Connect(hookTool)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function CodexController.Start()
	if not Config.Codex.Enabled then
		return
	end

	-- Codex screen (built on first open).
	local screen = Kit.Mount("Index")
	gui = screen
	local p = Kit.Popup(screen)
	p.OnOpen = function()
		buildScreen()
		refreshScreen()
		applyFilter()
		HudController.SetAlert("IndexBtn", false)
	end
	popup = p
	HudController.Bind("IndexBtn", CodexController.Open, "Codex", "Book")

	ProfileController.Changed:Connect(function()
		refreshScreen()
	end)

	-- Celebrations.
	local celebration = Instance.new("ScreenGui")
	celebration.Name = "CodexCelebration"
	celebration.ResetOnSpawn = false
	celebration.IgnoreGuiInset = true
	celebration.DisplayOrder = 15
	celebration.Parent = localPlayer:WaitForChild("PlayerGui")
	celebrateGui = celebration

	local discovered = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CodexDiscovered") :: RemoteEvent
	discovered.OnClientEvent:Connect(function(creatureId: any, info: any)
		if typeof(creatureId) ~= "string" or not Config.CreaturesById[creatureId] then
			return
		end
		local data = if typeof(info) == "table" then info else {}
		local page = if typeof(data.PageCompleted) == "string" and Config.Rarities[data.PageCompleted]
			then data.PageCompleted :: string else nil
		local delay = if data.Source == "Hatch" then codexConfig.HatchCelebrationDelay else 0
		if not (popup and popup:IsOpen()) then
			HudController.SetAlert("IndexBtn", true)
		end
		celebrate(creatureId, page, delay)
	end)

	startGlitchLoop()

	-- Field Camera.
	buildViewfinder()
	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		watchContainer(backpack)
	end
	localPlayer.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watchContainer(child)
		end
	end)
	if localPlayer.Character then
		watchContainer(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(watchContainer)
	localPlayer.CharacterRemoving:Connect(function()
		stopViewfinder()
	end)
end

return CodexController
