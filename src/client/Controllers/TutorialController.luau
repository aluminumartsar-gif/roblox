--!strict
--[[
	TutorialController
	StarterPlayerScripts/Client/Controllers/TutorialController

	The first-join tutorial. Client only: every step is ticked off from the
	player's real progress (profile snapshot + player attributes), so there
	is nothing to save and no remote. Anyone who has already hatched an egg
	never sees it; a returning player who stopped half way picks up at the
	first step they haven't done yet.

	  1. Welcome card                       -> "Let's go!"
	  2. Grab an egg off the egg belt       done: carrying, or bought one
	  3. Carry it to your camp's pad        done: an egg is in a nest
	  4. Guard it until it hatches          done: Stats.Hatches > 0
	  5. Collect from your cryptid          done: a CashCollected event arrived
	  6. Tips card                          -> "Let's play!"

	Each step shows a field-kit card at the top centre (ScreenGui "Tutorial",
	draw order Config.UI.Layers.Tutorial, scaled for phones): a "STEP 2 OF 4"
	label with one progress dot per action step, a Skip button, the step's
	title, its instructions, and on the two cards a "Let's go!" / "Let's
	play!" button. It sits under Roblox's top bar, the HUD's Base/Eggs
	buttons, any sighting/Hunt banner (NotificationController.ReservedBottom
	+ ReservationsChanged) and the steal banners (StealController.
	BannerBottom + BannersChanged), and reserves its own bottom edge
	(ReserveTop "Tutorial") so toasts slide in below it. While it shows,
	the player attribute TutorialActive is true: Daily Rewards and the
	Offline Earnings popup wait for it.

	Each step also has a 3D guide: a glowing Beam from your character to
	the target plus a bouncing arrow over it, in the theme's ember and moss.
	The guide's parts are created locally (only this client sees them) in
	Workspace.

	StreamingEnabled: targets (belt eggs, your pad, your eggs and cryptids)
	may not be on this client yet. Each target falls back to a position
	worked out from Config (belt arch from Config.Belt + BeltPath, your camp
	from Config.Plot — the same maths as MapBuilder.GetPlotCFrame), and is
	re-resolved every Config.Tutorial.CheckInterval, so the guide snaps to
	the real thing once it streams in.

	Skipping lasts for this visit only (nothing is saved); a player who
	skipped and still hasn't hatched anything sees it again next time.

	Studio test: ServerStorage.SAC_Debug:Invoke("tutorial", name, "fresh")
	wipes that player to a new profile and replays it on their screen.

	Tunables: Config.Tutorial (steps, guide), Config.UI.Tutorial.Panel (look).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BeltPath = require(Shared:WaitForChild("BeltPath"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local HudLayout = require(Components:WaitForChild("HudLayout"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))
local StealController = require(script.Parent:WaitForChild("StealController"))

local TutorialController = {}

local localPlayer = Players.LocalPlayer
local tuning = Config.Tutorial
local look = Config.UI.Tutorial.Panel
local C = Theme.Colors

-- Rich-text colour for button/prompt names in the instructions.
local HIGHLIGHT = "#" .. C.EmberBright:ToHex()

-- NotificationController.ReserveTop key for the panel (toasts go below it).
local RESERVE_KEY = "Tutorial"
-- The card's fit scale only changes by more than this (no jitter).
local FIT_STEP = 0.01

-- Studio test hook (DebugCommands "tutorial"): the server bumps this player
-- attribute to replay the tutorial; we wait a moment for the new snapshot.
local REPLAY_ATTRIBUTE = "TutorialReplay"
local REPLAY_DELAY = 1

local running = false -- a tutorial is on screen (or about to be)

-- Step 5 is ticked off by the server's CashCollected event (fired only for
-- a real collect from one of your cryptids), not by TotalCashEarned, which
-- also rises for daily rewards, spins, gifts and belt refunds.
local cashCollects = 0     -- CashCollected events seen this visit
local runCollectBase = 0   -- cashCollects when the current run started

-- When Carrying was last seen true. Claiming at the pad clears Carrying
-- and fills the nest in the same server frame, but the two can land a
-- moment apart here; this stops a brief "you lost your egg" flash.
local lastCarryingAt = -math.huge

type State = {
	cash: number,
	rebirths: number,
	carrying: boolean,
	eggs: number,      -- eggs sitting in nests (not out being stolen)
	creatures: number, -- cryptids sitting in nests
	hatches: number,
	eggsBought: number,
}

-- A step's guide: the panel text, and where the arrow points. `target`
-- (an Instance) is followed every frame while it exists; `point` is the
-- fallback (or the target when there's no Instance).
type Guide = { text: string, target: Instance?, point: Vector3? }

type Step = {
	Title: string,
	Card: boolean,                   -- a card has a button and no guide
	Button: string?,
	SkipIf: ((State) -> boolean)?,   -- already done when we get here
	OnEnter: ((State) -> ())?,
	Done: ((State) -> boolean)?,
	Guide: ((State) -> Guide)?,
}

--------------------------------------------------------------------------
-- Sounds (button clicks come from SoundController's hook on every button)
--------------------------------------------------------------------------

local function playSound(name: string)
	SoundController.Play(name)
end

--------------------------------------------------------------------------
-- Reading progress
--------------------------------------------------------------------------

local function gatherState(): State
	local snapshot: { [string]: any } = ProfileController.Get() or {}
	local stats = if typeof(snapshot.Stats) == "table" then snapshot.Stats else {}
	local eggs, creatures = 0, 0
	if typeof(snapshot.Nests) == "table" then
		for _, slot in pairs(snapshot.Nests) do
			if typeof(slot) == "table" and not slot.Away then
				if slot.Kind == "Egg" then
					eggs += 1
				elseif slot.Kind == "Creature" then
					creatures += 1
				end
			end
		end
	end
	local carrying = localPlayer:GetAttribute("Carrying") == true
	if carrying then
		lastCarryingAt = os.clock()
	end
	return {
		cash = tonumber(snapshot.Cash) or 0,
		rebirths = tonumber(snapshot.Rebirths) or 0,
		carrying = carrying,
		eggs = eggs,
		creatures = creatures,
		hatches = tonumber(stats.Hatches) or 0,
		eggsBought = tonumber(stats.EggsBought) or 0,
	}
end

local function getRoot(): BasePart?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function myPlotIndex(): number?
	local index = localPlayer:GetAttribute("PlotIndex")
	return if typeof(index) == "number" then index else nil
end

local function cheapestUnlockedPrice(rebirths: number): number
	local cheapest = math.huge
	for _, eggId in ipairs(Config.EggOrder) do
		local def = Config.Eggs[eggId]
		if def.RequiredRebirths <= rebirths then
			cheapest = math.min(cheapest, def.Price)
		end
	end
	return cheapest
end

--------------------------------------------------------------------------
-- Targets (each with a fallback position for StreamingEnabled)
--------------------------------------------------------------------------

--- Centre of plot `index` at deck height. Same maths as
--- MapBuilder.GetPlotCFrame (server-only, so mirrored here).
local function plotCentre(index: number): Vector3
	local angle = (index - 1) / Config.Plot.Count * math.pi * 2
	return Vector3.new(math.cos(angle), 0, math.sin(angle)) * Config.Plot.RingRadius
		+ Vector3.new(0, Config.Plot.FloorHeight, 0)
end

--- Just outside the egg belt's arch (the way in to the campfire).
local function archPoint(): Vector3
	local angle = math.rad(Config.Belt.GapCenterDegrees)
	return BeltPath.Center
		+ Vector3.new(math.cos(angle), 0, math.sin(angle)) * (Config.Belt.Radius + tuning.ArchOutside)
end

--- The point on the belt's riding arc closest to `position`.
local function nearestBeltPoint(position: Vector3): Vector3
	local offset = position - BeltPath.Center
	local angle = math.atan2(offset.Z, offset.X)
	local tau = math.pi * 2
	local along = (angle - BeltPath.StartAngle) % tau
	if along > BeltPath.Arc then
		-- In the gap: snap to whichever burrow end is nearer.
		along = if along - BeltPath.Arc < tau - along then BeltPath.Arc else 0
	end
	return BeltPath.PointAt(BeltPath.StartAngle + along, Config.Belt.Height)
end

--- The nearest belt egg this player could buy right now, if any.
local function nearestBuyableEgg(state: State, from: Vector3): Model?
	local now = Workspace:GetServerTimeNow()
	local lastBuyableAge = Config.Belt.RiseTime + Config.Belt.TravelTime - tuning.EggMinRideLeft
	local best: Model? = nil
	local bestDistance = math.huge
	for _, instance in ipairs(CollectionService:GetTagged(Config.Tags.BeltEgg)) do
		if not instance:IsA("Model") then
			continue
		end
		local spawnTime = instance:GetAttribute("SpawnTime")
		local eggId = instance:GetAttribute("EggId")
		if typeof(spawnTime) ~= "number" or typeof(eggId) ~= "string" then
			continue
		end
		local def = Config.Eggs[eggId]
		local age = now - spawnTime
		if not def or BeltPath.Phase(age) ~= "Riding" or age > lastBuyableAge then
			continue
		end
		if def.Price > state.cash or def.RequiredRebirths > state.rebirths then
			continue
		end
		local distance = (instance:GetPivot().Position - from).Magnitude
		if distance < bestDistance then
			best, bestDistance = instance, distance
		end
	end
	return best
end

local function myPad(): BasePart?
	local index = myPlotIndex()
	if not index then
		return nil
	end
	for _, instance in ipairs(CollectionService:GetTagged(Config.Tags.PlotPad)) do
		if instance:IsA("BasePart") and instance:GetAttribute("PlotIndex") == index then
			return instance
		end
	end
	return nil
end

--- My nest item with the biggest value of `attribute` (Progress for eggs, Vault
--- for cryptids), among models tagged `tag`.
local function myBestItem(tag: string, attribute: string): (Model?, number)
	local best: Model? = nil
	local bestValue = -math.huge
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsA("Model") and instance:GetAttribute("OwnerUserId") == localPlayer.UserId
			and instance:GetAttribute("NestIndex") ~= nil then
			local value = tonumber(instance:GetAttribute(attribute)) or 0
			if value > bestValue then
				best, bestValue = instance, value
			end
		end
	end
	return best, if best then bestValue else 0
end

local function upgradesCounter(): BasePart?
	for _, instance in ipairs(CollectionService:GetTagged(Config.Tags.ShopBooth)) do
		if instance:IsA("BasePart") and instance:GetAttribute("ShopId") == "Upgrades" then
			return instance
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- Guides shared by several steps
--------------------------------------------------------------------------

local function bold(text: string): string
	return string.format('<font color="%s"><b>%s</b></font>', HIGHLIGHT, text)
end

local function beltGuide(state: State, lead: string?): Guide
	local prefix = if lead then lead .. " " else ""
	local cheapest = cheapestUnlockedPrice(state.rebirths)
	if state.cash < cheapest then
		local rescue = if Config.Economy.RescueEnabled
			then " — and if you have nothing at all, a free egg turns up in your camp."
			else "."
		return {
			text = prefix .. string.format("Eggs start at $%s. Your cryptids' cash adds up fast%s",
				Config.FormatNumber(cheapest), rescue),
			point = archPoint(),
		}
	end
	local root = getRoot()
	local flat = if root then (root.Position - BeltPath.Center) * Vector3.new(1, 0, 1) else nil
	if not root or not flat or flat.Magnitude > Config.Belt.Radius + tuning.BeltNearDistance then
		return {
			text = prefix .. "Eggs ride round the " .. bold("egg belt") .. " by the big campfire. Tap the "
				.. bold("Eggs") .. " button at the top of the screen to jump there, or follow the glowing line.",
			point = archPoint(),
		}
	end
	local egg = nearestBuyableEgg(state, root.Position)
	return {
		text = prefix .. "Tap " .. bold("Buy") .. " on an egg as it rides past. First come, first served! You have "
			.. bold("$" .. Config.FormatNumber(state.cash)) .. ".",
		target = egg,
		point = nearestBeltPoint(root.Position),
	}
end

local function padGuide(): Guide
	local index = myPlotIndex()
	return {
		text = "Carry it home and step on the glowing " .. bold("pad") .. " just inside your camp's door. "
			.. "(The " .. bold("Base") .. " button doesn't work while your hands are full — walk it!) "
			.. "Careful: a bat hit knocks it loose.",
		target = myPad(),
		point = if index then plotCentre(index) else nil,
	}
end

local function homePoint(): Vector3?
	local index = myPlotIndex()
	return if index then plotCentre(index) else nil
end

local function hatchGuide(state: State): Guide
	if state.eggs == 0 then
		if state.carrying then
			return padGuide()
		end
		return beltGuide(state, "No egg in your nests right now.")
	end
	local egg = myBestItem(Config.Tags.Egg, "Progress")
	local remaining = if egg then tonumber(egg:GetAttribute("Remaining")) or 0 else 0
	local clock = string.format("%d:%02d", remaining // 60, remaining % 60)
	return {
		text = "Your egg hatches by itself in " .. bold(clock) .. ". Until then anyone can "
			.. bold("steal") .. " it, so stay close and bat away thieves! Better eggs take longer, and everyone can see them.",
		target = egg,
		point = homePoint(),
	}
end

--------------------------------------------------------------------------
-- The steps
--------------------------------------------------------------------------

local STEPS: { Step } = {
	{
		Title = "Welcome to camp!",
		Card = true,
		Button = "Let's go!",
		SkipIf = function(state)
			return state.carrying or state.eggsBought > 0 or state.eggs > 0 or state.creatures > 0
		end,
		Guide = function(_state)
			return {
				text = "Grab cryptid eggs off the " .. bold("egg belt") .. " and carry them home.\n"
					.. "They " .. bold("hatch by themselves") .. " after a while (better eggs take longer) into cryptids that " .. bold("earn cash") .. ".\n"
					.. "Anyone can steal an egg until it hatches — so guard yours, and rob other camps!",
			}
		end,
	},
	{
		Title = "Grab an egg",
		Card = false,
		Done = function(state)
			return state.carrying or state.eggsBought > 0 or state.eggs > 0 or state.creatures > 0
		end,
		Guide = function(state)
			return beltGuide(state, nil)
		end,
	},
	{
		Title = "Take it home",
		Card = false,
		Done = function(state)
			return state.eggs > 0 or state.creatures > 0 or state.hatches > 0
		end,
		Guide = function(state)
			if state.carrying or os.clock() - lastCarryingAt < tuning.LostEggGrace then
				return padGuide()
			end
			return beltGuide(state, "Oh no, you lost your egg! If it's on the ground, grab it quick — or get another.")
		end,
	},
	{
		Title = "Guard it until it hatches",
		Card = false,
		Done = function(state)
			return state.hatches > 0
		end,
		Guide = hatchGuide,
	},
	{
		Title = "Collect your cash",
		Card = false,
		-- Any collect since this run started counts (a quick player may walk
		-- into their new cryptid while "Nice!" is still showing).
		Done = function(_state)
			return cashCollects > runCollectBase
		end,
		Guide = function(state)
			if state.creatures == 0 then
				return hatchGuide(state)
			end
			local creature, vault = myBestItem(Config.Tags.Creature, "Vault")
			local holding = if creature and vault >= 1 then " It's holding " .. bold("$" .. Config.FormatNumber(vault)) .. "." else ""
			return {
				text = "Meet your cryptid! It fills up with cash all by itself." .. holding
					.. " " .. bold("Walk into it") .. " to collect.",
				target = creature,
				point = homePoint(),
			}
		end,
	},
	{
		Title = "You're all set!",
		Card = true,
		Button = "Let's play!",
		Guide = function(_state)
			return {
				text = "• The " .. bold("Upgrades") .. " cabin by the campfire sells more nests, faster hatching and faster feet.\n"
					.. "• " .. bold("LOCK CAMP") .. " (top left) shuts your door to thieves for a while.\n"
					.. "• Unlocked camps can be robbed: hold " .. bold("Steal") .. " on their eggs. Hatched cryptids are safe, and you can " .. bold("Sell") .. " the ones you don't want. Bonk a thief with your "
					.. bold("Bat") .. " to make them drop it.\n"
					.. "• Wild cryptids turn up in the woods. Catch them, and snap photos with your "
					.. bold("Field Camera") .. " for your Codex.\n"
					.. "• When the fire gutters, " .. bold(Config.Hunt.Name) .. " comes for anyone carrying an egg. "
					.. "Your camp and the campfire's light are the only safe places.",
				target = upgradesCounter(),
			}
		end,
	},
}

local ACTION_STEP_COUNT = 0
for _, step in ipairs(STEPS) do
	if not step.Card then
		ACTION_STEP_COUNT += 1
	end
end

--------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------

type Panel = {
	gui: ScreenGui,
	origin: Frame,     -- zero-size frame at the gui's (0, 0): converts screen px to gui px
	holder: Frame,     -- placed under the top bar and banners; carries the screen scale
	scale: UIScale,
	frame: Frame,      -- the card itself (drops in inside the holder)
	fit: UIScale,      -- shrinks the card when it's too tall for the space left
	stepLabel: TextLabel,
	dots: { Frame },
	title: TextLabel,
	body: TextLabel,
	button: TextButton,
	skip: TextButton,
}


--- Number of action steps (not cards) among STEPS[1..index].
local function actionNumber(index: number): number
	local number = 0
	for i = 1, math.min(index, #STEPS) do
		if not STEPS[i].Card then
			number += 1
		end
	end
	return number
end

--- Progress dots: the first `done` are moss, dot `currentDot` (if any) is
--- ember, the rest are hollow wells.
local function paintProgress(panel: Panel, done: number, currentDot: number?)
	for i, dot in ipairs(panel.dots) do
		local fill, edge = C.Inset, C.Edge
		if i <= done then
			fill, edge = C.Moss, C.MossDeep
		elseif i == currentDot then
			fill, edge = C.Ember, C.EmberBright
		end
		dot.BackgroundColor3 = fill
		local stroke = dot:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = edge
		end
	end
end

local function buildPanel(): Panel
	local gui = UI.new("ScreenGui", {
		Name = "Tutorial",
		ResetOnSpawn = false,
		IgnoreGuiInset = true, -- placed from the very top, like the HUD's top row
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Config.UI.Layers.Tutorial,
		Enabled = false,
	}) :: ScreenGui
	local origin = UI.new("Frame", {
		Name = "Origin",
		BackgroundTransparency = 1,
		Size = UDim2.new(),
		Parent = gui,
	}) :: Frame
	local holder = UI.new("Frame", {
		Name = "Holder",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(look.Width, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	}) :: Frame
	local scale = UI.Scale(holder)

	-- The card: a charred-wood panel that grows to fit its rows. Anchored
	-- at its top centre so the fit scale shrinks it towards that point.
	local frame = UI.Panel({
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = holder,
	})
	local fit = UI.new("UIScale", { Name = "Fit", Parent = frame }) :: UIScale
	UI.Padding(look.Padding).Parent = frame
	UI.List({ Padding = look.RowGap, HorizontalAlignment = Enum.HorizontalAlignment.Center }).Parent = frame

	-- Header: "STEP 2 OF 4" and the progress dots on the left, Skip on the right.
	local header = UI.new("Frame", {
		Name = "Header",
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, look.HeaderHeight),
		Parent = frame,
	}) :: Frame
	local progress = UI.new("Frame", {
		Name = "Progress",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -look.SkipArmedWidth, 1, 0),
		Parent = header,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = look.StepGap,
		}),
	}) :: Frame
	local stepLabel = UI.Text({
		Name = "Step",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		TextSize = look.StepTextSize,
		TextColor3 = C.TextDim,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 1,
		Visible = false,
		Parent = progress,
	})
	local dotRow = UI.new("Frame", {
		Name = "Dots",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		Parent = progress,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = look.DotGap,
		}),
	}) :: Frame
	local dots: { Frame } = {}
	for i = 1, ACTION_STEP_COUNT do
		local dot = UI.new("Frame", {
			Name = "Dot" .. i,
			BackgroundColor3 = C.Inset,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(look.DotSize, look.DotSize),
			LayoutOrder = i,
			Parent = dotRow,
		}, {
			UI.Corner(math.ceil(look.DotSize / 2)),
			UI.Stroke({ Color = C.Edge }),
		}) :: Frame
		table.insert(dots, dot)
	end
	local skip = UI.Button({
		Name = "Skip",
		Text = "Skip",
		Variant = "Ghost",
		TextSize = look.SkipTextSize,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(look.SkipWidth, look.HeaderHeight),
		Parent = header,
	})

	local title = UI.Text({
		Name = "Title",
		Role = "Heading",
		Weight = "Bold",
		Text = "",
		TextSize = look.TitleSize,
		TextColor3 = C.EmberBright,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = 2,
		Parent = frame,
	})
	UI.Divider({ LayoutOrder = 3, Parent = frame })
	local body = UI.Text({
		Name = "Body",
		Role = "Body",
		Text = "",
		TextSize = look.BodySize,
		TextColor3 = C.Text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = 4,
		Parent = frame,
	})
	-- "Let's go!" / "Let's play!" on the two cards; hidden on action steps.
	local button = UI.Button({
		Name = "Continue",
		Text = "",
		Variant = "Primary",
		TextSize = look.ButtonTextSize,
		Size = UDim2.fromOffset(look.ButtonSize.X, look.ButtonSize.Y),
		LayoutOrder = 5,
		Visible = false,
		Parent = frame,
	})

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return {
		gui = gui,
		origin = origin,
		holder = holder,
		scale = scale,
		frame = frame,
		fit = fit,
		stepLabel = stepLabel,
		dots = dots,
		title = title,
		body = body,
		button = button,
		skip = skip,
	}
end

--------------------------------------------------------------------------
-- 3D guide (all local parts: only this player sees them)
--------------------------------------------------------------------------

type GuideParts = {
	anchor: Part,
	beam: Beam,
	marker: BillboardGui,
	rootAttachment: Attachment?,
}

local function buildGuide(): GuideParts
	local anchor = Instance.new("Part")
	anchor.Name = "TutorialTarget"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(0, -500, 0)

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "Target"
	targetAttachment.Position = Vector3.new(0, 1.5, 0)
	targetAttachment.Parent = anchor

	local beam = Instance.new("Beam")
	beam.Name = "GuideBeam"
	beam.Attachment1 = targetAttachment
	beam.Color = ColorSequence.new(C.EmberBright, C.MossBright) -- your end, the target's end
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.15, 0.25),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	beam.Width0 = tuning.BeamWidth
	beam.Width1 = tuning.BeamWidth
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Segments = 24
	beam.Enabled = false
	beam.Parent = anchor

	local marker = Instance.new("BillboardGui")
	marker.Name = "GuideMarker"
	marker.Adornee = anchor
	marker.AlwaysOnTop = true
	marker.LightInfluence = 0
	marker.Size = UDim2.fromOffset(tuning.MarkerSize, tuning.MarkerSize)
	marker.StudsOffsetWorldSpace = Vector3.new(0, tuning.MarkerHeight, 0)
	marker.Enabled = false
	marker.Parent = anchor
	-- A downward chevron made of two rounded ember bars (no image asset
	-- needed). Bars are ARROW_LENGTH tall, tilted 45 degrees, meeting at
	-- ARROW_TIP, with a dark edge so they read against the night sky.
	local ARROW_LENGTH, ARROW_THICKNESS = 0.56, 0.17
	local ARROW_TIP = Vector2.new(0.5, 0.8)
	local ARROW_CORNER, ARROW_OUTLINE = 6, 2
	local half = ARROW_LENGTH / 2 * math.sin(math.rad(45))
	for _, side in ipairs({ -1, 1 }) do
		UI.new("Frame", {
			Name = "ArrowBar",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(ARROW_TIP.X + side * half, ARROW_TIP.Y - half),
			Size = UDim2.fromScale(ARROW_THICKNESS, ARROW_LENGTH),
			Rotation = side * 45,
			BackgroundColor3 = C.EmberBright,
			BorderSizePixel = 0,
			Parent = marker,
		}, {
			UI.Corner(ARROW_CORNER),
			UI.Stroke({ Color = C.TextOnAccent, Thickness = ARROW_OUTLINE }),
		})
	end

	anchor.Parent = Workspace
	return { anchor = anchor, beam = beam, marker = marker, rootAttachment = nil }
end

local function attachToCharacter(guide: GuideParts, character: Model)
	task.spawn(function()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not root or not root:IsA("BasePart") or character ~= localPlayer.Character
			or guide.anchor.Parent == nil then
			return -- gone, replaced, or the tutorial already finished
		end
		local old = guide.rootAttachment
		if old then
			old:Destroy()
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = "TutorialGuide"
		attachment.Parent = root
		guide.rootAttachment = attachment
		guide.beam.Attachment0 = attachment
	end)
end

--------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------

function TutorialController.Start()
	if not tuning.Enabled then
		return
	end
	-- Count real collects (step 5). Waited for off the start-up thread.
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CashCollected") :: RemoteEvent
		remote.OnClientEvent:Connect(function()
			cashCollects += 1
		end)
	end)
	-- Studio test hook: SAC_Debug "tutorial" bumps this attribute to replay
	-- the tutorial (after the server's fresh snapshot has had a moment to
	-- arrive). Harmless on live servers: it's UI only and nothing sets it.
	localPlayer:GetAttributeChangedSignal(REPLAY_ATTRIBUTE):Connect(function()
		if not running then
			running = true
			task.delay(REPLAY_DELAY, TutorialController.Run)
		end
	end)
	-- Everything else waits for the first profile snapshot, off the start-up
	-- thread so other controllers aren't held up.
	task.spawn(function()
		local snapshot = ProfileController.WaitForProfile()
		local stats = snapshot.Stats
		if typeof(stats) == "table" and (tonumber(stats.Hatches) or 0) > 0 then
			return -- a veteran: they've done all this before
		end
		if not running then
			TutorialController.Run()
		end
	end)
end

function TutorialController.Run()
	running = true
	-- Other screens (Daily Rewards, Offline Earnings) don't pop up over the tutorial.
	localPlayer:SetAttribute("TutorialActive", true)
	runCollectBase = cashCollects
	-- The panel sits under the steal banners and, while it's up, holds the
	-- toast reservation for both.
	StealController.SetPanelBelow(RESERVE_KEY)
	local panel = buildPanel()
	local guide = buildGuide()
	local connections: { RBXScriptConnection } = {}
	local signalConnections: { any } = {} -- Shared/Util/Signal connections

	local current = 0
	local doneAt: number? = nil -- os.clock() when the current step was completed
	local finished = false
	local followed: Instance? = nil
	local fallbackPoint: Vector3? = nil
	local skipArmedUntil = 0
	local lastBody = ""
	-- The card's height in screen px at Fit 1, measured whenever its size
	-- changes (so it always matches the Fit scale it was laid out with).
	local naturalHeight = 0

	local function setTarget(target: Instance?, point: Vector3?)
		followed = target
		fallbackPoint = point
	end

	-- Top centre: under the top bar and Base/Eggs buttons, any banner
	-- (sighting, Hunt) and the steal banners. Shrinks to fit the space left
	-- above the bottom of the screen, and reserves its bottom edge so toasts
	-- slide in below the panel, never over it.
	local function place()
		if finished then
			return
		end
		local scale = panel.scale.Scale
		local originY = panel.origin.AbsolutePosition.Y
		local gap = Config.UI.Tutorial.StackGap * scale
		local top = HudLayout.TopCentreTop(panel.origin, scale, panel.frame.AbsoluteSize.X)
		local above = NotificationController.ReservedBottom(RESERVE_KEY)
		if above then
			top = math.max(top, above - originY + gap)
		end
		local stealBottom = StealController.BannerBottom()
		if stealBottom then
			top = math.max(top, stealBottom - originY + gap)
		end
		top = math.floor(top + 0.5)
		panel.holder.Position = UDim2.new(0.5, 0, 0, top)

		local camera = Workspace.CurrentCamera
		if camera and naturalHeight > 0 then
			local available = camera.ViewportSize.Y - top - look.ScreenMargin * scale
			local wanted = math.clamp(available / naturalHeight, look.MinFit, 1)
			if math.abs(wanted - panel.fit.Scale) > FIT_STEP then
				panel.fit.Scale = wanted
			end
		end

		if panel.gui.Enabled then
			NotificationController.ReserveTop(RESERVE_KEY, originY + top + panel.frame.AbsoluteSize.Y)
		end
	end

	local function measure()
		naturalHeight = panel.frame.AbsoluteSize.Y / panel.fit.Scale
		place()
	end

	local function setSkipArmed(armed: boolean)
		UI.SetButtonText(panel.skip, if armed then "Tap again to skip" else "Skip")
		UI.SetButtonVariant(panel.skip, if armed then "Danger" else "Ghost")
		panel.skip.Size = UDim2.fromOffset(if armed then look.SkipArmedWidth else look.SkipWidth, look.HeaderHeight)
	end

	local function finish()
		if finished then
			return
		end
		finished = true
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		for _, connection in ipairs(signalConnections) do
			connection:Disconnect()
		end
		NotificationController.ReserveTop(RESERVE_KEY, nil)
		StealController.SetPanelBelow(nil)
		setTarget(nil, nil)
		guide.beam.Enabled = false
		guide.marker.Enabled = false
		-- Slide up off the top of the screen, then clean everything up.
		UI.Tween(panel.holder, look.SlideOutTime, {
			Position = UDim2.new(0.5, 0, 0, -(panel.frame.AbsoluteSize.Y + look.DropIn)),
		}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(look.SlideOutTime, function()
			running = false
			localPlayer:SetAttribute("TutorialActive", nil)
			panel.gui:Destroy()
			guide.anchor:Destroy()
			local attachment = guide.rootAttachment
			if attachment then
				attachment:Destroy()
			end
		end)
	end

	local function setBody(text: string)
		if text ~= lastBody then
			lastBody = text
			panel.body.Text = text
		end
	end

	local function show(step: Step, state: State)
		panel.title.Text = step.Title
		panel.title.TextColor3 = C.EmberBright
		local number = actionNumber(current)
		if step.Card then
			panel.stepLabel.Text = ""
			panel.stepLabel.Visible = false
			paintProgress(panel, number, nil)
		else
			panel.stepLabel.Text = string.format("STEP %d OF %d", number, ACTION_STEP_COUNT)
			panel.stepLabel.Visible = true
			paintProgress(panel, number - 1, number)
		end
		panel.button.Visible = step.Card
		UI.SetButtonText(panel.button, step.Button or "")
		local guideFn = step.Guide
		if guideFn then
			local g = guideFn(state)
			setBody(g.text)
			setTarget(g.target, g.point)
		else
			setBody("")
			setTarget(nil, nil)
		end
		-- A little drop-in so a new step catches the eye.
		panel.frame.Position = UDim2.new(0.5, 0, 0, -look.DropIn)
		UI.Tween(panel.frame, look.DropInTime, { Position = UDim2.fromScale(0.5, 0) },
			Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		panel.gui.Enabled = true
		place()
	end

	local function advance()
		while true do
			current += 1
			local step = STEPS[current]
			if not step then
				playSound("Notify")
				finish()
				return
			end
			local state = gatherState()
			if step.OnEnter then
				step.OnEnter(state)
			end
			local skipIf = step.SkipIf
			local done = step.Done
			if (skipIf and skipIf(state)) or (done and done(state)) then
				continue -- already done this one
			end
			show(step, state)
			return
		end
	end

	local function tick()
		if finished then
			return
		end
		-- Keep the panel under the banners and the toasts under the panel.
		place()
		local step = STEPS[current]
		if not step then
			return
		end
		local completedAt = doneAt
		if completedAt then
			if os.clock() - completedAt >= tuning.StepDoneDelay then
				doneAt = nil
				advance()
			end
			return
		end
		local state = gatherState()
		local done = step.Done
		if done and done(state) then
			doneAt = os.clock()
			panel.title.Text = "Nice!"
			panel.title.TextColor3 = C.MossBright
			paintProgress(panel, actionNumber(current), nil)
			setTarget(nil, nil)
			playSound("Notify")
			return
		end
		-- Re-aim the guide: targets stream in and out, eggs ride the belt.
		local guideFn = step.Guide
		if guideFn and not step.Card then
			local g = guideFn(state)
			setBody(g.text)
			setTarget(g.target, g.point)
		elseif guideFn and step.Card and not followed then
			-- Cards keep their text; just pick up a target that streamed in.
			local g = guideFn(state)
			setTarget(g.target, g.point)
		end
	end

	-- Buttons (SoundController clicks every button by itself)
	table.insert(connections, panel.button.Activated:Connect(function()
		local step = STEPS[current]
		if step and step.Card and not doneAt then
			advance()
		end
	end))
	table.insert(connections, panel.skip.Activated:Connect(function()
		-- Two taps, so a stray thumb on a phone doesn't throw it away.
		if os.clock() < skipArmedUntil then
			finish()
			return
		end
		skipArmedUntil = os.clock() + tuning.SkipConfirmTime
		setSkipArmed(true)
		task.delay(tuning.SkipConfirmTime, function()
			if not finished and os.clock() >= skipArmedUntil then
				setSkipArmed(false)
			end
		end)
	end))

	-- Re-place when anything above moves or the panel changes size.
	table.insert(signalConnections, NotificationController.ReservationsChanged:Connect(place))
	table.insert(signalConnections, StealController.BannersChanged:Connect(place))
	table.insert(connections, panel.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(measure))

	-- Character (re)spawns: the beam starts at your HumanoidRootPart.
	if localPlayer.Character then
		attachToCharacter(guide, localPlayer.Character)
	end
	table.insert(connections, localPlayer.CharacterAdded:Connect(function(character)
		attachToCharacter(guide, character)
	end))

	-- Every frame: follow the target, bounce the arrow, hide the beam up close.
	local clockStart = os.clock()
	table.insert(connections, RunService.Heartbeat:Connect(function()
		local position: Vector3? = nil
		local target = followed
		if target and target.Parent then
			if target:IsA("BasePart") then
				position = target.Position
			elseif target:IsA("Model") then
				position = target:GetPivot().Position
			end
		end
		if not position then
			position = fallbackPoint
		end
		if not position then
			guide.beam.Enabled = false
			guide.marker.Enabled = false
			return
		end
		guide.anchor.CFrame = CFrame.new(position)
		local bounce = math.sin((os.clock() - clockStart) * tuning.MarkerBounceSpeed) * tuning.MarkerBounce
		guide.marker.StudsOffsetWorldSpace = Vector3.new(0, tuning.MarkerHeight + bounce, 0)
		guide.marker.Enabled = true
		local root = getRoot()
		local attachment = guide.rootAttachment
		guide.beam.Enabled = root ~= nil and attachment ~= nil and attachment.Parent == root
			and (root.Position - position).Magnitude > tuning.BeamHideDistance
	end))

	-- Progress checks
	task.spawn(function()
		while not finished do
			tick()
			task.wait(tuning.CheckInterval)
		end
	end)

	playSound("UIOpen")
	advance()
end

return TutorialController
