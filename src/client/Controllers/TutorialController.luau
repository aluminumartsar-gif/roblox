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

	Each step shows a short panel near the top centre (under the kit HUD's
	Base/Eggs buttons, ScreenScale'd for phones, with a Skip button) and a
	3D guide: a glowing Beam from your character to the target plus a
	bouncing arrow over it. The guide's parts are created locally (only this
	client sees them) in Workspace.

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

	Tunables: Config.Tutorial.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BeltPath = require(Shared:WaitForChild("BeltPath"))

local Components = script.Parent.Parent:WaitForChild("Components")
local ScreenScale = require(Components:WaitForChild("ScreenScale"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))

local TutorialController = {}

local localPlayer = Players.LocalPlayer
local tuning = Config.Tutorial

-- Panel colours (presentation only, not designer-tunable numbers).
local PANEL_COLOR = Color3.fromRGB(24, 22, 30)
local STROKE_COLOR = Color3.fromRGB(255, 196, 120)
local TITLE_COLOR = Color3.fromRGB(255, 226, 170)
local BODY_COLOR = Color3.fromRGB(236, 232, 224)
local MUTED_COLOR = Color3.fromRGB(170, 164, 156)
local GO_COLOR = Color3.fromRGB(56, 156, 88)
local SKIP_COLOR = Color3.fromRGB(70, 64, 76)
local NICE_COLOR = Color3.fromRGB(140, 255, 170)
local HIGHLIGHT = "#FFD27A" -- rich-text colour for button/prompt names

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
-- Sounds (SoundController is written in parallel; unknown names are a
-- silent no-op there, and a missing controller is a no-op here)
--------------------------------------------------------------------------

local soundController: any = nil

local function playSound(name: string)
	local sc = soundController
	if sc and typeof(sc.Play) == "function" then
		pcall(sc.Play, name)
	end
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
	frame: Frame,
	stepLabel: TextLabel,
	title: TextLabel,
	body: TextLabel,
	button: TextButton,
	skip: TextButton,
}

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function buildPanel(): Panel
	local gui = Instance.new("ScreenGui")
	gui.Name = "Tutorial"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- same coordinates as the kit HUD
	gui.DisplayOrder = tuning.DisplayOrder
	gui.Enabled = false

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, tuning.PanelTop, 0)
	frame.Size = UDim2.fromOffset(tuning.PanelWidth, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = PANEL_COLOR
	frame.BackgroundTransparency = 0.1
	frame.Parent = gui
	corner(frame, 14)
	local stroke = Instance.new("UIStroke")
	stroke.Color = STROKE_COLOR
	stroke.Thickness = 2
	stroke.Transparency = 0.25
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame
	ScreenScale.Apply(frame)

	-- Header: "STEP 1 OF 4" on the left, Skip on the right.
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.LayoutOrder = 1
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 32)
	header.Parent = frame

	local stepLabel = Instance.new("TextLabel")
	stepLabel.Name = "Step"
	stepLabel.BackgroundTransparency = 1
	stepLabel.Size = UDim2.new(1, -90, 1, 0)
	stepLabel.Font = Enum.Font.GothamBold
	stepLabel.TextSize = 14
	stepLabel.TextColor3 = MUTED_COLOR
	stepLabel.TextXAlignment = Enum.TextXAlignment.Left
	stepLabel.Text = ""
	stepLabel.Parent = header

	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.AnchorPoint = Vector2.new(1, 0)
	skip.Position = UDim2.fromScale(1, 0)
	skip.Size = UDim2.new(0, 84, 1, 0)
	skip.AutomaticSize = Enum.AutomaticSize.X
	skip.BackgroundColor3 = SKIP_COLOR
	skip.BackgroundTransparency = 0.2
	skip.Font = Enum.Font.GothamBold
	skip.TextSize = 14
	skip.TextColor3 = BODY_COLOR
	skip.Text = "Skip"
	skip.AutoButtonColor = true
	skip.Parent = header
	corner(skip, 8)
	local skipPadding = Instance.new("UIPadding")
	skipPadding.PaddingLeft = UDim.new(0, 10)
	skipPadding.PaddingRight = UDim.new(0, 10)
	skipPadding.Parent = skip

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.LayoutOrder = 2
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 0)
	title.AutomaticSize = Enum.AutomaticSize.Y
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 24
	title.TextWrapped = true
	title.TextColor3 = TITLE_COLOR
	title.Text = ""
	title.Parent = frame

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.LayoutOrder = 3
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.Font = Enum.Font.GothamMedium
	body.TextSize = 18
	body.TextWrapped = true
	body.RichText = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextColor3 = BODY_COLOR
	body.Text = ""
	body.Parent = frame

	local button = Instance.new("TextButton")
	button.Name = "Continue"
	button.LayoutOrder = 4
	button.Size = UDim2.fromOffset(220, 48) -- a thumb-sized target
	button.BackgroundColor3 = GO_COLOR
	button.Font = Enum.Font.GothamBlack
	button.TextSize = 20
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Text = ""
	button.AutoButtonColor = true
	button.Visible = false
	button.Parent = frame
	corner(button, 10)

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return {
		gui = gui,
		frame = frame,
		stepLabel = stepLabel,
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
	beam.Color = ColorSequence.new(tuning.BeamColorNear, tuning.BeamColorFar)
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
	-- A downward chevron made of two rounded bars (no image asset needed).
	-- Bars are ARROW_LENGTH tall, tilted 45 degrees, meeting at ARROW_TIP.
	local ARROW_LENGTH, ARROW_THICKNESS = 0.56, 0.17
	local ARROW_TIP = Vector2.new(0.5, 0.8)
	local half = ARROW_LENGTH / 2 * math.sin(math.rad(45))
	for _, side in ipairs({ -1, 1 }) do
		local bar = Instance.new("Frame")
		bar.Name = "ArrowBar"
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(ARROW_TIP.X + side * half, ARROW_TIP.Y - half)
		bar.Size = UDim2.fromScale(ARROW_THICKNESS, ARROW_LENGTH)
		bar.Rotation = side * 45
		bar.BackgroundColor3 = tuning.BeamColorNear
		bar.BorderSizePixel = 0
		bar.Parent = marker
		corner(bar, 6)
		local outline = Instance.new("UIStroke")
		outline.Color = Color3.fromRGB(40, 24, 10)
		outline.Thickness = 2
		outline.Parent = bar
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
	local soundModule = script.Parent:FindFirstChild("SoundController")
	if soundModule and soundModule:IsA("ModuleScript") then
		local ok, result = pcall(require, soundModule :: any)
		if ok then
			soundController = result
		end
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
	-- Other screens (Daily Rewards) don't pop up over the tutorial.
	localPlayer:SetAttribute("TutorialActive", true)
	runCollectBase = cashCollects
	local panel = buildPanel()
	local guide = buildGuide()
	local connections: { RBXScriptConnection } = {}

	local current = 0
	local doneAt: number? = nil -- os.clock() when the current step was completed
	local finished = false
	local followed: Instance? = nil
	local fallbackPoint: Vector3? = nil
	local skipArmedUntil = 0
	local lastBody = ""

	local function setTarget(target: Instance?, point: Vector3?)
		followed = target
		fallbackPoint = point
	end

	local function finish()
		if finished then
			return
		end
		finished = true
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		setTarget(nil, nil)
		guide.beam.Enabled = false
		guide.marker.Enabled = false
		-- Slide up off the top of the screen, then clean everything up.
		TweenService:Create(panel.frame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 0, -400),
		}):Play()
		task.delay(0.35, function()
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
		panel.title.TextColor3 = TITLE_COLOR
		if step.Card then
			panel.stepLabel.Text = ""
		else
			local number = 0
			for i = 1, current do
				if not STEPS[i].Card then
					number += 1
				end
			end
			panel.stepLabel.Text = string.format("STEP %d OF %d", number, ACTION_STEP_COUNT)
		end
		panel.button.Visible = step.Card
		panel.button.Text = step.Button or ""
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
		panel.frame.Position = UDim2.new(0.5, 0, tuning.PanelTop, -16)
		TweenService:Create(panel.frame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, tuning.PanelTop, 0),
		}):Play()
		panel.gui.Enabled = true
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
			panel.title.TextColor3 = NICE_COLOR
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

	-- Buttons
	table.insert(connections, panel.button.Activated:Connect(function()
		local step = STEPS[current]
		if step and step.Card and not doneAt then
			playSound("UIClick")
			advance()
		end
	end))
	table.insert(connections, panel.skip.Activated:Connect(function()
		-- Two taps, so a stray thumb on a phone doesn't throw it away.
		if os.clock() < skipArmedUntil then
			playSound("UIClick")
			finish()
			return
		end
		skipArmedUntil = os.clock() + tuning.SkipConfirmTime
		panel.skip.Text = "Tap again to skip"
		task.delay(tuning.SkipConfirmTime, function()
			if not finished and os.clock() >= skipArmedUntil then
				panel.skip.Text = "Skip"
			end
		end)
	end))

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
