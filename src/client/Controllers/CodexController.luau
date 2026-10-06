--!strict
--[[
	CodexController
	StarterPlayerScripts/Client/Controllers/CodexController

	Hook 3 on the client: the Field Camera and the Cryptid Codex screen, in
	the "campfire field kit" look (Components/Theme, UI, Window). Sizes and
	colour choices: Config.UI.Codex; feature tunables: Config.Codex.

	Field Camera (the tool CodexService gives every spawn):
	  * While it's in your hand, a camcorder viewfinder covers the screen
	    (layer World, under the HUD): darkened edges, corner brackets, a
	    reticle and, top right, a blinking REC light, a battery that
	    recharges between shots, the running time and the in-game clock.
	    Under the reticle: the name of the cryptid you're aiming at
	    (outlined in the world, brackets in its rarity colour; "NEW!" if it
	    isn't in your Codex yet) or "No cryptid in view".
	  * Aiming: a ray through the mouse pointer (or the screen centre on
	    touch / gamepad) up to Config.Codex.MaxPhotoDistance; the nearest
	    tagged cryptid model it passes through wins. Cryptid parts aren't
	    raycastable (CanQuery off), so the ray is tested against each
	    model's bounding box, stopping at the first wall. If it misses, the
	    cryptid closest to the screen centre within FallbackConeDegrees
	    counts (forgiving on phones).
	  * Click / tap: shutter flash (layer Flash) + CameraShutter sound,
	    then TakePhoto(model). The server checks everything again.
	  * The tool is followed through Tool.Equipped / Unequipped, so it works
	    with Roblox's backpack and with a custom hotbar (Humanoid:EquipTool).

	Celebrations (from the server's CodexDiscovered event, so hatches and
	claims celebrate too; layer Celebration): a "NEW CODEX ENTRY" polaroid
	+ CodexNew sound, after any hatch reveal; a completed rarity page adds a
	"<Rarity> page complete!" banner + PageComplete sound. Several at once
	queue up; too many at once collapse into a toast.

	Codex screen (Window "Codex", HUD Codex button): a field journal.
	  * Left: filter tabs — All, then one per rarity — each with its found /
	    total count and a progress strip.
	  * Top: "DISCOVERED: x/y" with a progress bar, and a search box (by
	    name or id). The header shows "Pages n/7 · +N% luck".
	  * One paper evidence card per cryptid in Config order: its photo (a
	    ViewportFrame with a warm tint and faint scanlines) or a black
	    silhouette with "???", its rarity tag, its exhibit number, and a
	    "NEW" tag for entries logged since you last looked. The Secret's
	    photo is always glitched and redacted.
	  * Tapping a card opens its file: a big polaroid, name, rarity, income,
	    the field note from Config.Codex.Blurbs (once discovered) and its
	    status. Back (or a filter / search change) returns to the cards.
	  * Cards and their 3D photos are built the first time the screen opens.
	  * The HUD button shows a "!" when something new was logged since you
	    last looked.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local HudLayout = require(Components:WaitForChild("HudLayout"))
local Window = require(Components:WaitForChild("Window"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local HudController = require(script.Parent:WaitForChild("HudController"))

local CodexController = {}

local localPlayer = Players.LocalPlayer
local codexConfig = Config.Codex
local tuning = Config.UI.Codex
local layers = Config.UI.Layers
local C = Theme.Colors
local T = Theme.Tuning

-- Not designer-tunable: small visual details and a latency allowance.
local LATENCY_MARGIN = 0.15        -- client waits a hair longer than the server cooldown
local GLITCH_JITTER = 0.06         -- how far (fraction of the photo) the Secret jumps
local GLITCH_JUMP_CHANCE = 0.35
local GLITCH_FADE_CHANCE = 0.25
local REVEAL_POLL = 0.2            -- s between checks for a running hatch reveal
local NO_LIGHT = Color3.new(0, 0, 0) -- a silhouette: the model gets no light at all
local NO_TINT = Color3.new(1, 1, 1)  -- leaves a gradient's own colours as they are
local LIST_PADDING = 4             -- inner padding of the card list (UI.ScrollList)
local LIST_SCROLLBAR = 5
-- UI.ScrollList pads its right side 4 px more than the left for the bar.
local LIST_CHROME = LIST_PADDING * 2 + 4 + LIST_SCROLLBAR + 2
local BODY_PADDING = 16            -- Components/Window pads its Body by this much

local PHOTO_TAGS = { Config.Tags.Creature, Config.Tags.WildCryptid, Config.Tags.CarriedItem }

-- Exhibit numbers (position in Config.Creatures).
local exhibitIndex: { [string]: number } = {}
for index, creature in ipairs(Config.Creatures) do
	exhibitIndex[creature.Id] = index
end

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

-- SoundController is looked up lazily (and pcalled) so a sound problem can
-- never break the Codex; a missing one is silence.
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

--- Accent for a rarity in the world-facing overlays (viewfinder brackets,
--- outline): its colour, or blood red for the Secret.
local function worldAccent(rarity: string): Color3
	return if isSecret(rarity) then C.BloodBright else Theme.RarityColor(rarity)
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

local function exhibitText(creatureId: string): string
	return string.format(tuning.ExhibitFormat, exhibitIndex[creatureId] or 0)
end

--- A dark outline so text reads over the 3D world.
local function outline(label: TextLabel, thickness: number)
	UI.Stroke({
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Color = C.Shadow,
		Thickness = thickness,
		Parent = label,
	})
end

local function maxTextSize(label: TextLabel, size: number)
	UI.new("UITextSizeConstraint", { MaxTextSize = size, Parent = label })
end

--- Hover and press feedback for a plain button (the evidence cards) —
--- the same feel as Components/UI's buttons.
local function pressable(button: GuiButton, onHover: (boolean) -> ())
	local scale = UI.new("UIScale", { Name = "Press", Parent = button }) :: UIScale
	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end
	button.MouseEnter:Connect(function()
		onHover(true)
	end)
	button.MouseLeave:Connect(function()
		onHover(false)
		UI.Tween(scale, T.HoverTime, { Scale = 1 })
	end)
	button.InputBegan:Connect(function(input)
		if isPress(input) then
			UI.Tween(scale, T.HoverTime * 0.6, { Scale = T.ButtonPressScale })
		end
	end)
	button.InputEnded:Connect(function(input)
		if isPress(input) then
			UI.Tween(scale, T.HoverTime, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end)
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
		viewport.Ambient = NO_LIGHT
		viewport.LightColor = NO_LIGHT
		viewport.ImageColor3 = NO_LIGHT
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
	local keypoints = {}
	local count = 19 -- NumberSequence allows at most 20 keypoints
	for i = 0, count - 1 do
		local value = if i % 2 == 0 then codexConfig.ScanlineTransparency else 1
		table.insert(keypoints, NumberSequenceKeypoint.new(i / (count - 1), value))
	end
	return UI.new("Frame", {
		Name = "Scanlines",
		BackgroundColor3 = C.Shadow,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = parent,
	}, {
		UI.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(keypoints) }),
	})
end

--- A black "redacted" bar across a photo (the Secret only).
local function addRedactionBar(parent: Instance, zIndex: number)
	UI.new("Frame", {
		Name = "Redacted",
		BackgroundColor3 = C.Shadow,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromScale(0.78, 0.13),
		Rotation = -6,
		ZIndex = zIndex,
		Parent = parent,
	})
end

--- A dark photo well with the creature's photo, scanlines and (Secret)
--- redaction bar. Returns (well, viewport, scanlines).
local function buildPhotoWell(creatureId: string, props: { [string]: any }): (Frame, ViewportFrame, Frame)
	local well = UI.new("Frame", {
		Name = "PhotoWell",
		BackgroundColor3 = C.Inset,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, {
		UI.Stroke({ Color = C.Ink, Transparency = 0.5 }),
	}) :: Frame
	local viewport = buildPhoto(creatureId, well, 1)
	local scanlines = addScanlines(well, 2)
	local def = Config.CreaturesById[creatureId]
	if def and isSecret(def.Rarity) then
		addRedactionBar(well, 3)
	end
	for key, value in pairs(props) do
		if key ~= "Parent" then
			(well :: any)[key] = value
		end
	end
	well.Parent = props.Parent
	return well, viewport, scanlines
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
				local palette = if state.Lit then tuning.GlitchLit else tuning.GlitchDark
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
	Frame: GuiButton,
	Paper: Frame,
	Caption: TextLabel,
	Viewport: ViewportFrame,
	Scanlines: Frame,
	NewTag: Frame,
}

type FilterTab = {
	Tab: TextButton,
	Count: TextLabel,
	Bar: Frame,
}

local window: Window.Window? = nil
local built = false
local cards: { Card } = {}
local filter = "All"
local query = ""
-- Entries logged since the Codex was last looked at ("NEW" tags).
local unseen: { [string]: boolean } = {}

local discoveredLabel: TextLabel? = nil
local discoveredBar: Frame? = nil
local cardList: ScrollingFrame? = nil
local emptyLabel: TextLabel? = nil
local filterTabs: { [string]: FilterTab } = {}

-- A cryptid's file (the details view).
type FileParts = {
	Frame: Frame,
	Polaroid: Frame,
	PhotoSlot: Frame,
	Caption: TextLabel,
	Exhibit: TextLabel,
	Name: TextLabel,
	Rarity: Frame,
	Income: TextLabel,
	Blurb: TextLabel,
	StatusIcon: ImageLabel,
	Status: TextLabel,
}
local file: FileParts? = nil
local fileCurrentId: string? = nil
local filePhotoId: string? = nil
local fileViewport: ViewportFrame? = nil
local fileScanlines: Frame? = nil

local function paperTint(found: boolean): Color3
	return if found then NO_TINT else Theme.Mix(NO_TINT, C.Shadow, tuning.UnknownPaperDim)
end

local function renderCard(card: Card)
	local found = isDiscovered(card.Id)
	card.Caption.Text = if found then card.Def.Name else "???"
	card.Paper.BackgroundColor3 = paperTint(found)
	setPhotoLit(card.Viewport, card.Id, found)
	card.Scanlines.Visible = found
end

local function refreshNewTags()
	for _, card in ipairs(cards) do
		card.NewTag.Visible = unseen[card.Id] == true
	end
end

local function applyFilter()
	local shown = 0
	for _, card in ipairs(cards) do
		local rarityOk = filter == "All" or card.Def.Rarity == filter
		local nameOk = query == ""
			or string.find(string.lower(card.Def.Name), query, 1, true) ~= nil
			or string.find(card.Id, query, 1, true) ~= nil
		card.Frame.Visible = rarityOk and nameOk
		if card.Frame.Visible then
			shown += 1
		end
	end
	for key, entry in pairs(filterTabs) do
		UI.SetTabSelected(entry.Tab, key == filter)
	end
	local empty = emptyLabel
	if empty then
		local parts = file
		empty.Visible = shown == 0 and not (parts and parts.Frame.Visible)
	end
end

local function refreshCounters()
	local found, total = progress(nil)
	if discoveredLabel then
		discoveredLabel.Text = string.format("DISCOVERED: %d/%d", found, total)
	end
	UI.SetProgress(discoveredBar, if total > 0 then found / total else 0, T.Window.OpenTime)
	local pages = completePages()
	local w = window
	if w then
		w:SetInfo(string.format("Pages %d/%d  ·  +%g%% luck", pages, #Config.RarityOrder,
			pages * Config.Luck.CodexPageCompletePercent))
	end
	for key, entry in pairs(filterTabs) do
		local f, t = progress(if key == "All" then nil else key)
		entry.Count.Text = string.format("%d/%d", f, t)
		entry.Count.TextColor3 = if t > 0 and f == t then C.MossBright else C.TextDim
		UI.SetProgress(entry.Bar, if t > 0 then f / t else 0)
	end
end

--- Shows (or refreshes) a cryptid's file.
local function showFile(creatureId: string)
	local parts = file
	local def = Config.CreaturesById[creatureId]
	if not parts or not def then
		return
	end
	local rarity = Config.Rarities[def.Rarity]
	local found = isDiscovered(creatureId)
	fileCurrentId = creatureId

	-- Rebuild the photo only when the creature changes.
	if filePhotoId ~= creatureId then
		parts.PhotoSlot:ClearAllChildren()
		local _, viewport, scanlines = buildPhotoWell(creatureId, {
			Size = UDim2.fromScale(1, 1),
			Parent = parts.PhotoSlot,
		})
		fileViewport = viewport
		fileScanlines = scanlines
		filePhotoId = creatureId
	end
	if fileViewport then
		setPhotoLit(fileViewport, creatureId, found)
	end
	if fileScanlines then
		fileScanlines.Visible = found
	end
	parts.Polaroid.BackgroundColor3 = paperTint(found)

	parts.Caption.Text = if found then def.Name else "???"
	parts.Exhibit.Text = exhibitText(creatureId)
	parts.Name.Text = def.Name
	UI.SetPill(parts.Rarity, def.Rarity, Theme.RarityColor(def.Rarity))
	parts.Income.Text = string.format("Earns $%s/s", Config.FormatNumber(rarity.IncomePerSecond))
	if found then
		parts.Blurb.Text = codexConfig.Blurbs[creatureId] or "No field notes yet."
		parts.StatusIcon.Visible = true
		parts.Status.TextColor3 = C.MossDeep
		parts.Status.Text = "Photographed"
	else
		parts.Blurb.Text = "No file yet. Photograph one with your Field Camera, or hatch or capture one, to unlock its notes."
		parts.StatusIcon.Visible = false
		parts.Status.TextColor3 = C.EmberDeep
		parts.Status.Text = "Not seen yet — photograph one to log it"
	end
	parts.Frame.Visible = true
	-- The cards hide behind the file (so they can't scroll or click through).
	if cardList then
		cardList.Visible = false
	end
	if emptyLabel then
		emptyLabel.Visible = false
	end
end

--- Back to the cards (also re-applies the filter, which shows the "no
--- match" note if nothing is left).
local function closeDetails()
	if file then
		file.Frame.Visible = false
	end
	fileCurrentId = nil
	if cardList then
		cardList.Visible = true
	end
	applyFilter()
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
	local openId = fileCurrentId
	if openId and file and file.Frame.Visible then
		showFile(openId)
	end
end

--- One paper evidence card in the grid.
local function buildCard(def: any, index: number, parent: Instance): Card
	local size = tuning.CardSize
	local margin = tuning.CardPhotoMargin
	local photoSize = size.X - margin * 2
	local exhibitHeight = 12
	local captionTop = margin + photoSize + 2
	local captionHeight = math.max(12, size.Y - captionTop - exhibitHeight - margin - 2)

	local cell = UI.new("TextButton", {
		Name = "Card_" .. def.Id,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size.X, size.Y),
		LayoutOrder = index,
	}) :: TextButton
	local paper = UI.Paper({ Name = "Paper", Size = UDim2.fromScale(1, 1), Parent = cell })
	local edge = paper:FindFirstChildOfClass("UIStroke") :: UIStroke?
	local restColor = if edge then edge.Color else C.Ink
	local restTransparency = if edge then edge.Transparency else 0

	local _, viewport, scanlines = buildPhotoWell(def.Id, {
		Position = UDim2.fromOffset(margin, margin),
		Size = UDim2.fromOffset(photoSize, photoSize),
		Parent = paper,
	})
	-- Rarity tag top left of the photo, "NEW" bottom right (so even a long
	-- rarity name never runs into it).
	UI.Pill({
		Name = "RarityTag",
		Text = def.Rarity,
		Color = Theme.RarityColor(def.Rarity),
		Filled = true,
		TextSize = 12,
		Height = 18,
		Position = UDim2.fromOffset(margin + 4, margin + 4),
		ZIndex = 2,
		Parent = paper,
	})
	local newTag = UI.Pill({
		Name = "NewTag",
		Text = "New",
		Color = C.Ember,
		Filled = true,
		TextSize = 12,
		Height = 18,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromOffset(margin + photoSize - 4, margin + photoSize - 4),
		ZIndex = 2,
		Visible = false,
		Parent = paper,
	})
	local caption = UI.Text({
		Name = "Caption",
		Role = "Notes",
		Text = "???",
		TextColor3 = C.Ink,
		TextScaled = true,
		TextWrapped = true,
		Position = UDim2.fromOffset(margin, captionTop),
		Size = UDim2.new(1, -margin * 2, 0, captionHeight),
		Parent = paper,
	})
	maxTextSize(caption, 15)
	UI.Text({
		Name = "Exhibit",
		Role = "Mono",
		Text = exhibitText(def.Id),
		TextSize = 11,
		TextColor3 = C.Ink,
		TextTransparency = 0.45,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, margin, 1, -margin + 2),
		Size = UDim2.new(1, -margin * 2, 0, exhibitHeight),
		Parent = paper,
	})

	pressable(cell, function(hovering)
		if edge then
			edge.Color = if hovering then C.Ember else restColor
			edge.Transparency = if hovering then 0 else restTransparency
		end
	end)
	cell.Activated:Connect(function()
		showFile(def.Id)
	end)
	cell.Parent = parent

	return {
		Id = def.Id,
		Def = def,
		Frame = cell,
		Paper = paper,
		Caption = caption,
		Viewport = viewport,
		Scanlines = scanlines,
		NewTag = newTag,
	}
end

--- The file view: a big polaroid and a journal page, over the cards.
local function buildFile(parent: Instance): FileParts
	local frame = UI.new("Frame", {
		Name = "CodexFile",
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Active = true,
		Visible = false,
		Parent = parent,
	}, { UI.Corner(T.CornerSmall) }) :: Frame

	-- The polaroid.
	local polaroidSize = tuning.FilePolaroidSize
	local margin = 12
	local photoSize = polaroidSize.X - margin * 2
	local polaroid = UI.Paper({
		Name = "Polaroid",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.fromOffset(polaroidSize.X, polaroidSize.Y),
		Parent = frame,
	})
	local photoSlot = UI.new("Frame", {
		Name = "PhotoSlot",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(margin, margin),
		Size = UDim2.fromOffset(photoSize, photoSize),
		Parent = polaroid,
	}) :: Frame
	local captionTop = margin + photoSize + 6
	local caption = UI.Text({
		Name = "Caption",
		Role = "Notes",
		TextColor3 = C.Ink,
		TextScaled = true,
		TextWrapped = true,
		Position = UDim2.fromOffset(margin, captionTop),
		Size = UDim2.new(1, -margin * 2, 0, math.max(16, polaroidSize.Y - captionTop - 30)),
		Parent = polaroid,
	})
	maxTextSize(caption, 24)
	local exhibit = UI.Text({
		Name = "Exhibit",
		Role = "Mono",
		TextSize = 13,
		TextColor3 = C.Ink,
		TextTransparency = 0.45,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, margin, 1, -8),
		Size = UDim2.new(1, -margin * 2, 0, 14),
		Parent = polaroid,
	})

	-- Back to the cards.
	local backSize = tuning.BackButtonSize
	UI.Button({
		Name = "Back",
		Text = "Back",
		Variant = "Secondary",
		Icon = "ChevronLeft",
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -4, 1, -2),
		Size = UDim2.fromOffset(backSize.X, backSize.Y),
		Parent = frame,
		OnClick = closeDetails,
	})

	-- The journal page.
	local pageLeft = 6 + polaroidSize.X + 16
	local page = UI.Paper({
		Name = "Journal",
		Position = UDim2.fromOffset(pageLeft, 4),
		Size = UDim2.new(1, -(pageLeft + 4), 1, -(backSize.Y + 16)),
		Parent = frame,
	})
	UI.Padding(16).Parent = page
	local name = UI.Text({
		Name = "CreatureName",
		Role = "Heading",
		TextColor3 = C.Ink,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 36),
		Parent = page,
	})
	maxTextSize(name, 30)
	local rarityPill = UI.Pill({
		Name = "Rarity",
		Text = "",
		Filled = true,
		TextSize = 13,
		Height = 24,
		Position = UDim2.fromOffset(0, 44),
		Parent = page,
	})
	local income = UI.Text({
		Name = "Income",
		Role = "Heading",
		Weight = "SemiBold",
		TextSize = 18,
		TextColor3 = C.MossDeep,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 44),
		Size = UDim2.new(0.6, 0, 0, 24),
		Parent = page,
	})
	UI.Divider({ Color = C.Ink, Position = UDim2.fromOffset(0, 78), Parent = page })
	UI.Text({
		Name = "NotesHeading",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "FIELD NOTES",
		TextSize = 13,
		TextColor3 = C.Ink,
		TextTransparency = 0.35,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 86),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = page,
	})
	local blurb = UI.Text({
		Name = "Blurb",
		Role = "Notes",
		TextColor3 = C.Ink,
		TextScaled = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(0, 108),
		Size = UDim2.new(1, 0, 1, -(108 + 34)),
		Parent = page,
	})
	maxTextSize(blurb, 17)
	local statusRow = UI.new("Frame", {
		Name = "StatusRow",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = page,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 6,
		}),
	})
	local statusIcon = UI.Icon("CheckMark", 22, {
		Name = "StatusIcon",
		ImageColor3 = C.MossDeep,
		LayoutOrder = 1,
		Parent = statusRow,
	})
	local status = UI.Text({
		Name = "Status",
		Role = "Heading",
		Weight = "SemiBold",
		TextSize = 17,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -28, 1, 0),
		LayoutOrder = 2,
		Parent = statusRow,
	})
	maxTextSize(status, 17)

	return {
		Frame = frame,
		Polaroid = polaroid,
		PhotoSlot = photoSlot,
		Caption = caption,
		Exhibit = exhibit,
		Name = name,
		Rarity = rarityPill,
		Income = income,
		Blurb = blurb,
		StatusIcon = statusIcon,
		Status = status,
	}
end

--- Fills the Codex window. Runs on first open.
local function buildScreen()
	local w = window
	if built or not w then
		return
	end
	built = true
	local body = w.Body
	local tabSize = tuning.TabSize
	local columnLeft = tabSize.X + tuning.ColumnGap

	-- Left: filter tabs, All then every rarity.
	local tabColumn = UI.new("Frame", {
		Name = "Filters",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, tabSize.X, 1, 0),
		Parent = body,
	}, { UI.List({ Padding = tuning.TabGap }) })
	local keys = { "All" }
	for _, rarity in ipairs(Config.RarityOrder) do
		table.insert(keys, rarity)
	end
	for i, key in ipairs(keys) do
		local accent = if key == "All" then C.Ember else Theme.RarityColor(key)
		local tab = UI.Tab({
			Name = "Filter_" .. key,
			Text = key,
			Bar = "Left",
			Color = accent,
			TextSize = 16,
			Size = UDim2.new(1, 0, 0, tabSize.Y),
			LayoutOrder = i,
			Parent = tabColumn,
			OnClick = function()
				filter = key
				if cardList then
					cardList.CanvasPosition = Vector2.zero
				end
				closeDetails() -- (applies the filter)
			end,
		})
		local count = UI.Text({
			Name = "Count",
			Role = "Heading",
			Weight = "SemiBold",
			Text = "0/0",
			TextSize = 15,
			TextColor3 = C.TextDim,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, -2),
			Size = UDim2.fromOffset(56, 20),
			Parent = tab,
		})
		local bar = UI.ProgressBar({
			Name = "Progress",
			Color = accent,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 12, 1, -5),
			Size = UDim2.new(1, -22, 0, 4),
			Parent = tab,
		})
		filterTabs[key] = { Tab = tab, Count = count, Bar = bar }
	end

	-- Right: summary + search, then the cards.
	local right = UI.new("Frame", {
		Name = "Evidence",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(columnLeft, 0),
		Size = UDim2.new(1, -columnLeft, 1, 0),
		Parent = body,
	}) :: Frame

	local topHeight = tuning.TopRowHeight
	local searchWidth = tuning.SearchWidth
	local summary = UI.new("Frame", {
		Name = "Summary",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(searchWidth + 16), 0, topHeight),
		Parent = right,
	}) :: Frame
	discoveredLabel = UI.Text({
		Name = "Discovered",
		Role = "Heading",
		Text = "DISCOVERED: 0/0",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 24),
		Parent = summary,
	})
	discoveredBar = UI.ProgressBar({
		Name = "DiscoveredBar",
		Color = C.Ember,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 10),
		Parent = summary,
	})
	local _, box = UI.Input({
		Name = "Search",
		PlaceholderText = "Search cryptids...",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(searchWidth, topHeight),
		Parent = right,
	})
	box:GetPropertyChangedSignal("Text"):Connect(function()
		query = string.lower(box.Text)
		closeDetails() -- (applies the filter)
	end)

	local listTop = topHeight + 8
	local cardSize = tuning.CardSize
	local list = UI.ScrollList({
		Name = "Cards",
		Layout = "Grid",
		CellSize = UDim2.fromOffset(cardSize.X, cardSize.Y),
		Gap = tuning.CardGap,
		Padding = LIST_PADDING,
		ScrollBarThickness = LIST_SCROLLBAR,
		Position = UDim2.fromOffset(0, listTop),
		Size = UDim2.new(1, 0, 1, -listTop),
		Parent = right,
	})
	local grid = list:FindFirstChildOfClass("UIGridLayout")
	if grid then
		grid.FillDirectionMaxCells = codexConfig.CardsPerRow
	end
	cardList = list

	emptyLabel = UI.Text({
		Name = "Empty",
		Role = "Notes",
		Text = tuning.EmptyText,
		TextSize = 18,
		TextColor3 = C.TextDim,
		TextWrapped = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, math.floor(listTop / 2)),
		Size = UDim2.new(1, -40, 0, 48),
		ZIndex = 2,
		Visible = false,
		Parent = right,
	})

	-- One card per creature, in Config order (photos built now).
	for index, def in ipairs(Config.Creatures) do
		table.insert(cards, buildCard(def, index, list))
	end

	file = buildFile(right)
	refreshScreen()
	applyFilter()
	refreshNewTags()
end

--- The window's design size: the filter column plus CardsPerRow cards.
local function windowSize(): Vector2
	local perRow = codexConfig.CardsPerRow
	local listWidth = perRow * tuning.CardSize.X + (perRow - 1) * tuning.CardGap + LIST_CHROME
	return Vector2.new(BODY_PADDING * 2 + tuning.TabSize.X + tuning.ColumnGap + listWidth, tuning.WindowHeight)
end

function CodexController.Open()
	local w = window
	if not w then
		return
	end
	HudController.SetAlert("IndexBtn", false)
	-- (SoundController plays the open sound when the window shows.)
	w:Open()
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
	local size = tuning.PageBannerSize
	local hidden = UDim2.new(0.5, 0, 0, -size.Y * 2)

	local banner = UI.Panel({
		Name = "PageBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = hidden,
		Size = UDim2.fromOffset(size.X, size.Y),
	})
	local stroke = banner:FindFirstChildOfClass("UIStroke") :: UIStroke?
	if stroke then
		stroke.Color = Theme.RarityColor(rarity)
	end
	UI.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = banner,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 10,
		}),
		UI.Icon("Luck", 30, { ImageColor3 = C.EmberBright, LayoutOrder = 1 }),
		UI.Text({
			Name = "Label",
			Role = "Heading",
			Text = string.format("%s page complete! +%g%% luck forever", rarity, Config.Luck.CodexPageCompletePercent),
			TextSize = 24,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			LayoutOrder = 2,
		}),
	})
	banner.Parent = parent
	local bannerScale = UI.Scale(banner)
	-- Top centre like the other banners: under the top bar and Base/Eggs,
	-- and under the camp panel on narrow screens.
	local top = HudLayout.TopCentreTop(parent, bannerScale.Scale, size.X * bannerScale.Scale)

	UI.Tween(banner, tuning.PageBannerInTime, { Position = UDim2.new(0.5, 0, 0, top) },
		Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	task.delay(codexConfig.PageBannerTime, function()
		local out = UI.Tween(banner, tuning.SlideOutTime, { Position = hidden }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
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
	local size = tuning.PolaroidSize
	local margin = 12
	local photoSize = size.X - margin * 2

	local holder = UI.Paper({
		Name = "NewEntry",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, -0.5),
		Size = UDim2.fromOffset(size.X, size.Y),
	})
	UI.Title("NEW CODEX ENTRY", 34, {
		Name = "Header",
		TextColor3 = C.EmberBright,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -8),
		Size = UDim2.fromOffset(380, 40),
		Parent = holder,
	})

	local _, viewport = buildPhotoWell(creatureId, {
		Position = UDim2.fromOffset(margin, margin),
		Size = UDim2.fromOffset(photoSize, photoSize),
		Parent = holder,
	})
	setPhotoLit(viewport, creatureId, true)

	local captionTop = margin + photoSize + 4
	local caption = UI.Text({
		Name = "Caption",
		Role = "Notes",
		Text = def.Name,
		TextColor3 = C.Ink,
		TextScaled = true,
		TextWrapped = true,
		Position = UDim2.fromOffset(margin, captionTop),
		Size = UDim2.new(1, -margin * 2, 0, math.max(16, size.Y - captionTop - 24)),
		Parent = holder,
	})
	maxTextSize(caption, 24)
	UI.Text({
		Name = "Exhibit",
		Role = "Mono",
		Text = exhibitText(creatureId),
		TextSize = 12,
		TextColor3 = C.Ink,
		TextTransparency = 0.45,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, margin, 1, -6),
		Size = UDim2.new(1, -margin * 2, 0, 14),
		Parent = holder,
	})

	UI.Pill({
		Name = "RarityTag",
		Text = def.Rarity,
		Color = Theme.RarityColor(def.Rarity),
		Filled = true,
		TextSize = 16,
		Height = 28,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 10),
		Parent = holder,
	})

	holder.Parent = parent
	local holderScale = UI.Scale(holder)

	-- Centre the whole stack (header, paper, rarity pill) in the free band
	-- between the top banners / camp panel and the HUD's cash cluster,
	-- shrinking it a little on short screens so it covers neither.
	local headerReach, pillReach = 48, 38 -- px above / below the paper
	local stackHeight = headerReach + size.Y + pillReach
	local screenScale = holderScale.Scale
	local camera = workspace.CurrentCamera
	local settleY: UDim2 = UDim2.fromScale(0.5, 0.5)
	if camera then
		local gap = tuning.PolaroidGap * screenScale
		local bandTop = HudLayout.TopCentreTop(parent, screenScale, 380 * screenScale)
		local bandBottom = camera.ViewportSize.Y - HudLayout.BottomReserve() - gap
		local fit = math.clamp((bandBottom - bandTop) / (stackHeight * screenScale), 0.5, 1)
		local finalScale = screenScale * fit
		holderScale.Scale = finalScale
		local centre = (bandTop + bandBottom) / 2 + (headerReach - pillReach) / 2 * finalScale
		settleY = UDim2.new(0.5, 0, 0, centre)
	end

	UI.Tween(holder, tuning.PolaroidInTime, { Position = settleY },
		Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	task.wait(codexConfig.NewEntryBannerTime)
	local out = UI.Tween(holder, tuning.SlideOutTime, { Position = UDim2.fromScale(0.5, 1.6) },
		Enum.EasingStyle.Quad, Enum.EasingDirection.In)
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
		local waitUntil = os.clock() + tuning.RevealWaitMax
		while playerGui and playerGui:FindFirstChild("HatchReveal") and os.clock() < waitUntil do
			task.wait(REVEAL_POLL)
		end
		local page = item.Page
		if page then
			task.delay(tuning.PageBannerDelay, showPageBanner, page)
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

type ViewParts = {
	RecDot: Frame,
	Timecode: TextLabel,
	Stamp: TextLabel,
	TargetName: TextLabel,
	TargetSub: TextLabel,
}

local viewGui: ScreenGui? = nil
local flashFrame: Frame? = nil
local viewParts: ViewParts? = nil
local bracketBars: { Frame } = {}
local batteryBars: { Frame } = {}
local targetHighlight: Highlight? = nil
local equippedTool: Tool? = nil
local stepConnection: RBXScriptConnection? = nil
local readyAt = 0
local busy = false
local recordStart = 0

local function buildViewfinder()
	local vf = tuning.Viewfinder
	local screen = UI.new("ScreenGui", {
		Name = "FieldCamera",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = layers.World, -- under the HUD so its buttons stay readable
		Enabled = false,
	}) :: ScreenGui

	-- Darkened edges.
	local function edge(anchor: Vector2, position: UDim2, size: UDim2, rotation: number)
		UI.new("Frame", {
			BackgroundColor3 = C.Shadow,
			BorderSizePixel = 0,
			AnchorPoint = anchor,
			Position = position,
			Size = size,
			Parent = screen,
		}, {
			UI.new("UIGradient", { Rotation = rotation, Transparency = NumberSequence.new(vf.EdgeShade, 1) }),
		})
	end
	local depth = vf.EdgeDepth
	edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, depth.Y), 90)
	edge(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, depth.Y), -90)
	edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(depth.X, 1), 0)
	edge(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(depth.X, 1), 180)

	-- Corner brackets.
	local inset = vf.FrameInset
	local bracket = vf.BracketSize
	local thickness = vf.BracketThickness
	for _, c in ipairs({ Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local holder = UI.new("Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = c,
			Position = UDim2.fromScale(inset.X + (1 - 2 * inset.X) * c.X, inset.Y + (1 - 2 * inset.Y) * c.Y),
			Size = UDim2.fromOffset(bracket, bracket),
			Parent = screen,
		}) :: Frame
		UI.Scale(holder)
		local across = UI.new("Frame", {
			BorderSizePixel = 0,
			BackgroundColor3 = C.Text,
			AnchorPoint = Vector2.new(0, c.Y),
			Position = UDim2.fromScale(0, c.Y),
			Size = UDim2.new(1, 0, 0, thickness),
			Parent = holder,
		}) :: Frame
		local down = UI.new("Frame", {
			BorderSizePixel = 0,
			BackgroundColor3 = C.Text,
			AnchorPoint = Vector2.new(c.X, 0),
			Position = UDim2.fromScale(c.X, 0),
			Size = UDim2.new(0, thickness, 1, 0),
			Parent = holder,
		}) :: Frame
		table.insert(bracketBars, across)
		table.insert(bracketBars, down)
	end

	-- Centre reticle.
	local reticle = UI.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(36, 36),
		Parent = screen,
	}) :: Frame
	UI.Scale(reticle)
	for _, spec in ipairs({
		{ UDim2.fromScale(0.5, 0), UDim2.fromOffset(3, 11) },
		{ UDim2.fromScale(0.5, 1), UDim2.fromOffset(3, 11) },
		{ UDim2.fromScale(0, 0.5), UDim2.fromOffset(11, 3) },
		{ UDim2.fromScale(1, 0.5), UDim2.fromOffset(11, 3) },
	}) do
		local tick = UI.new("Frame", {
			BorderSizePixel = 0,
			BackgroundColor3 = C.Text,
			BackgroundTransparency = 0.15,
			AnchorPoint = Vector2.new(spec[1].X.Scale, spec[1].Y.Scale),
			Position = spec[1],
			Size = spec[2],
			Parent = reticle,
		}) :: Frame
		table.insert(bracketBars, tick)
	end

	-- Camcorder status, top right inside the brackets (the camp panel owns
	-- the top left): REC + battery, running time, in-game clock.
	local status = UI.new("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1 - inset.X, -(bracket + 14), inset.Y, 4),
		Size = UDim2.fromOffset(220, 80),
		Parent = screen,
	}) :: Frame
	UI.Scale(status)

	local battery = UI.new("Frame", {
		Name = "Battery",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 2),
		Size = UDim2.fromOffset(52, 22),
		Parent = status,
	}) :: Frame
	UI.new("Frame", {
		Name = "Shell",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(46, 22),
		Parent = battery,
	}, {
		UI.Stroke({ Color = C.Text, Thickness = 2 }),
	})
	UI.new("Frame", {
		Name = "Nub",
		BorderSizePixel = 0,
		BackgroundColor3 = C.Text,
		Position = UDim2.fromOffset(47, 6),
		Size = UDim2.fromOffset(4, 10),
		Parent = battery,
	})
	for i = 1, 3 do
		local bar = UI.new("Frame", {
			BorderSizePixel = 0,
			BackgroundColor3 = C.Text,
			Position = UDim2.fromOffset(4 + (i - 1) * 14, 4),
			Size = UDim2.fromOffset(11, 14),
			Parent = battery,
		}) :: Frame
		table.insert(batteryBars, bar)
	end

	local recWidth = 44
	local recRight = 52 + 12 -- battery width + gap
	local dot = UI.new("Frame", {
		Name = "RecDot",
		BackgroundColor3 = C.BloodBright,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(recRight + recWidth + 6), 0, 5),
		Size = UDim2.fromOffset(16, 16),
		Parent = status,
	}, { UI.Corner(8) }) :: Frame
	local recText = UI.Text({
		Name = "Rec",
		Role = "Heading",
		Text = "REC",
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -recRight, 0, 0),
		Size = UDim2.fromOffset(recWidth, 26),
		Parent = status,
	})
	outline(recText, 1.5)
	local timecode = UI.Text({
		Name = "Timecode",
		Role = "Mono",
		Weight = "Bold",
		Text = "00:00:00",
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 30),
		Size = UDim2.fromOffset(200, 22),
		Parent = status,
	})
	outline(timecode, 1.5)
	local stamp = UI.Text({
		Name = "Clock",
		Role = "Mono",
		Weight = "Bold",
		Text = "",
		TextSize = 18,
		TextColor3 = C.EmberBright,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 54),
		Size = UDim2.fromOffset(200, 24),
		Parent = status,
	})
	outline(stamp, 1.5)

	-- What you're aiming at, just under the reticle (or just above it when
	-- the HUD's cash and buff timers would cover it, on short screens).
	local info = UI.new("Frame", {
		Name = "Target",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, vf.InfoOffset),
		Size = UDim2.fromOffset(460, 84),
		Parent = screen,
	}) :: Frame
	local infoScale = UI.Scale(info)
	local function placeInfo()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local height = camera.ViewportSize.Y
		local infoBottom = height / 2 + vf.InfoOffset + info.Size.Y.Offset * infoScale.Scale
		local limit = height - HudLayout.BottomReserve() - vf.InfoOffset * infoScale.Scale
		if infoBottom > limit then
			info.AnchorPoint = Vector2.new(0.5, 1)
			info.Position = UDim2.new(0.5, 0, 0.5, -vf.InfoOffset)
		else
			info.AnchorPoint = Vector2.new(0.5, 0)
			info.Position = UDim2.new(0.5, 0, 0.5, vf.InfoOffset)
		end
	end
	HudLayout.Changed:Connect(placeInfo)
	infoScale:GetPropertyChangedSignal("Scale"):Connect(placeInfo)
	placeInfo()
	local targetName = UI.Text({
		Name = "TargetName",
		Role = "Heading",
		Text = "No cryptid in view",
		TextSize = 28,
		Size = UDim2.fromOffset(460, 34),
		Parent = info,
	})
	outline(targetName, 2)
	local targetSub = UI.Text({
		Name = "TargetSub",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		TextSize = 17,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(0, 36),
		Size = UDim2.fromOffset(460, 22),
		Parent = info,
	})
	outline(targetSub, 1.5)
	local hint = UI.Text({
		Name = "Hint",
		Role = "Body",
		Text = if UserInputService.TouchEnabled and not UserInputService.MouseEnabled
			then "Tap to take a photo" else "Click to take a photo",
		TextSize = 15,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.fromOffset(460, 20),
		Parent = info,
	})
	outline(hint, 1)
	viewParts = {
		RecDot = dot,
		Timecode = timecode,
		Stamp = stamp,
		TargetName = targetName,
		TargetSub = targetSub,
	}

	screen.Parent = localPlayer:WaitForChild("PlayerGui")
	viewGui = screen

	-- Shutter flash, above everything.
	local flashGui = UI.new("ScreenGui", {
		Name = "CameraFlash",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = layers.Flash,
	}) :: ScreenGui
	flashFrame = UI.new("Frame", {
		Name = "Flash",
		BackgroundColor3 = tuning.FlashColor,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = flashGui,
	})
	flashGui.Parent = localPlayer:WaitForChild("PlayerGui")

	targetHighlight = UI.new("Highlight", {
		Name = "CodexTarget",
		FillColor = C.Text,
		FillTransparency = vf.HighlightFill,
		DepthMode = Enum.HighlightDepthMode.Occluded,
	})
end

local function setTarget(model: Model?)
	local parts = viewParts
	if not parts then
		return
	end
	local highlight = targetHighlight
	local id = model and creatureIdOf(model)
	local def = id and Config.CreaturesById[id]
	local color = C.Text
	if model and def then
		color = worldAccent(def.Rarity)
		parts.TargetName.Text = def.Name
		local rarityName = string.upper(def.Rarity)
		if isDiscovered(def.Id) then
			parts.TargetSub.Text = rarityName .. "  ·  already in your Codex"
			parts.TargetSub.TextColor3 = C.TextDim
		else
			parts.TargetSub.Text = rarityName .. "  ·  NEW! Not in your Codex yet"
			parts.TargetSub.TextColor3 = C.EmberBright
		end
		if highlight then
			highlight.OutlineColor = color
			highlight.Adornee = model
			highlight.Parent = Workspace.CurrentCamera
		end
	else
		parts.TargetName.Text = "No cryptid in view"
		parts.TargetSub.Text = ""
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
		local parts = viewParts
		if not parts then
			return
		end
		sinceCheck += dt
		local now = os.clock()
		if sinceCheck >= codexConfig.TargetRefreshInterval then
			sinceCheck = 0
			local ok, target = pcall(pickTarget)
			setTarget(if ok then target else nil)
		end
		local elapsed = math.floor(now - recordStart)
		parts.Timecode.Text = string.format("%02d:%02d:%02d", elapsed // 3600, (elapsed // 60) % 60, elapsed % 60)
		parts.RecDot.Visible = (now - recordStart) % 1 < 0.6
		parts.Stamp.Text = formatGameClock()
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
	frame.BackgroundTransparency = tuning.FlashStart
	UI.Tween(frame, codexConfig.ShutterFlashTime, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
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

--------------------------------------------------------------------------
-- Field Camera: the tool
--------------------------------------------------------------------------

-- Followed through Equipped / Unequipped only, so it doesn't matter what
-- equips it (Roblox's backpack, a custom hotbar's Humanoid:EquipTool).
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

	-- Codex screen (contents built on first open).
	local w = Window.new({
		Name = "Codex",
		Title = "Codex",
		Icon = "Book",
		Size = windowSize(),
		Info = "",
	})
	w.OnOpen = function()
		buildScreen()
		refreshScreen()
		applyFilter()
		refreshNewTags()
		HudController.SetAlert("IndexBtn", false)
	end
	w.OnClose = function()
		-- Looked at: the "NEW" tags go.
		table.clear(unseen)
		refreshNewTags()
	end
	window = w
	HudController.Bind("IndexBtn", CodexController.Open, "Codex", "Book")

	ProfileController.Changed:Connect(function()
		refreshScreen()
	end)

	-- Celebrations.
	celebrateGui = UI.new("ScreenGui", {
		Name = "CodexCelebration",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = layers.Celebration,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})

	local discovered = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CodexDiscovered") :: RemoteEvent
	discovered.OnClientEvent:Connect(function(creatureId: any, info: any)
		if typeof(creatureId) ~= "string" or not Config.CreaturesById[creatureId] then
			return
		end
		local data = if typeof(info) == "table" then info else {}
		local page = if typeof(data.PageCompleted) == "string" and Config.Rarities[data.PageCompleted]
			then data.PageCompleted :: string else nil
		local delay = if data.Source == "Hatch" then codexConfig.HatchCelebrationDelay else 0
		unseen[creatureId] = true
		refreshNewTags()
		if not w:IsOpen() then
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
