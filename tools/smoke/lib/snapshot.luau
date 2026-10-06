--!nocheck
-- Snapshot mode: drive the client to a series of checkpoints and dump the
-- GUI tree at each one as JSON, for a separate tool that draws preview
-- images (there is no Studio to look at the UI).
--
--   bash tools/smoke/run.sh --snapshots <outdir> [--viewport 1920x1080]
--
-- Writes <outdir>/<checkpoint>.json per checkpoint and <outdir>/index.json
-- (which checkpoints were written, which were skipped and why). The format
-- of the checkpoint files is fixed (see README.md); keep it stable.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Classes = require("./classes")
local Inst = require("./inst")
local Loader = require("./loader")
local Report = require("./report")
local Sched = require("./sched")
local Services = require("./services")
local Typeof = require("./typeof")
local World = require("./world")

local S = Inst.S
local get = Inst.get
local typeOf = Typeof.typeof

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local Snapshot = {}

--------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------

local function num(n: number): number?
	if n ~= n or n == math.huge or n == -math.huge then
		return nil -- JSON has no NaN/inf (e.g. BillboardGui.MaxDistance = inf)
	end
	return n
end

local function encode(v: any): any
	local t = typeOf(v)
	if t == "number" then
		return num(v)
	elseif t == "string" or t == "boolean" then
		return v
	elseif t == "UDim2" then
		return { t = "UDim2", xs = num(v.X.Scale), xo = num(v.X.Offset), ys = num(v.Y.Scale), yo = num(v.Y.Offset) }
	elseif t == "UDim" then
		return { t = "UDim", s = num(v.Scale), o = num(v.Offset) }
	elseif t == "Vector2" then
		return { t = "Vector2", x = num(v.X), y = num(v.Y) }
	elseif t == "Vector3" then
		return { t = "Vector3", x = num(v.X), y = num(v.Y), z = num(v.Z) }
	elseif t == "Color3" then
		return { t = "Color3", r = num(v.R), g = num(v.G), b = num(v.B) }
	elseif t == "Font" then
		return { t = "Font", family = v.Family, weight = v.Weight.Name, style = v.Style.Name }
	elseif t == "EnumItem" then
		local enumName = string.gsub(tostring(v.EnumType), "^Enum%.", "")
		return { t = "Enum", enum = enumName, name = v.Name }
	elseif t == "ColorSequence" then
		local kps = {}
		for _, kp in v.Keypoints do
			table.insert(kps, { time = num(kp.Time), r = num(kp.Value.R), g = num(kp.Value.G), b = num(kp.Value.B) })
		end
		return { t = "ColorSequence", kps = kps }
	elseif t == "NumberSequence" then
		local kps = {}
		for _, kp in v.Keypoints do
			table.insert(kps, { time = num(kp.Time), value = num(kp.Value) })
		end
		return { t = "NumberSequence", kps = kps }
	elseif t == "Rect" then
		return { t = "Rect", x0 = num(v.Min.X), y0 = num(v.Min.Y), x1 = num(v.Max.X), y1 = num(v.Max.Y) }
	elseif t == "Instance" then
		return { t = "Ref", path = Inst.fullName(v) }
	elseif t == "NumberRange" then
		return { t = "NumberRange", min = num(v.Min), max = num(v.Max) }
	elseif t == "CFrame" then
		return { t = "CFrame", x = num(v.X), y = num(v.Y), z = num(v.Z) }
	elseif t == "Content" then
		return tostring(v)
	end
	return nil
end
Snapshot.encode = encode

-- Properties dumped (effective value: explicitly set, or the default) for
-- every GUI object that has them...
local PROPS = {
	"Position", "Size", "AnchorPoint", "Visible", "ZIndex", "LayoutOrder", "Rotation",
	"BackgroundColor3", "BackgroundTransparency", "BorderSizePixel", "BorderColor3", "BorderMode",
	"ClipsDescendants", "AutomaticSize", "SizeConstraint", "Active", "Interactable", "Selectable",
	"Text", "TextColor3", "TextSize", "TextTransparency", "TextStrokeColor3", "TextStrokeTransparency",
	"TextXAlignment", "TextYAlignment", "TextWrapped", "TextScaled", "TextTruncate", "RichText",
	"FontFace", "LineHeight", "MaxVisibleGraphemes",
	"Image", "ImageColor3", "ImageTransparency", "ScaleType", "SliceCenter", "SliceScale",
	"ImageRectOffset", "ImageRectSize", "TileSize", "ResampleMode", "HoverImage", "PressedImage",
	"AutoButtonColor", "Selected", "Modal",
	"CanvasSize", "CanvasPosition", "AutomaticCanvasSize", "ScrollBarThickness", "ScrollingDirection",
	"ScrollBarImageColor3", "ScrollBarImageTransparency", "ScrollingEnabled", "ElasticBehavior",
	"PlaceholderText", "PlaceholderColor3", "ClearTextOnFocus", "MultiLine", "TextEditable",
	"GroupTransparency", "GroupColor3",
	"Ambient", "LightColor", "LightDirection", "CurrentCamera",
	"Enabled", "DisplayOrder", "IgnoreGuiInset", "ZIndexBehavior", "ScreenInsets", "ClipToDeviceSafeArea",
	"AlwaysOnTop", "StudsOffset", "StudsOffsetWorldSpace", "ExtentsOffset", "ExtentsOffsetWorldSpace",
	"SizeOffset", "MaxDistance", "LightInfluence", "Brightness", "DistanceLowerLimit", "DistanceUpperLimit",
	"Adornee", "Face", "SizingMode", "PixelsPerStud",
}

-- ...and per UI modifier class (only for that class, so e.g. a Frame's
-- deprecated Transparency alias is never mistaken for a UIStroke's).
local MODIFIER_PROPS = {
	UIListLayout = { "FillDirection", "HorizontalAlignment", "VerticalAlignment", "Padding", "SortOrder", "Wraps", "ItemLineAlignment", "HorizontalFlex", "VerticalFlex" },
	UIGridLayout = { "CellSize", "CellPadding", "FillDirection", "FillDirectionMaxCells", "HorizontalAlignment", "VerticalAlignment", "SortOrder", "StartCorner" },
	UIPageLayout = { "FillDirection", "HorizontalAlignment", "VerticalAlignment", "Padding", "SortOrder", "Animated", "Circular", "EasingStyle", "TweenTime" },
	UITableLayout = { "FillDirection", "HorizontalAlignment", "VerticalAlignment", "Padding", "SortOrder", "FillEmptySpaceColumns", "FillEmptySpaceRows", "MajorAxis" },
	UIPadding = { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" },
	UICorner = { "CornerRadius" },
	UIStroke = { "Color", "Thickness", "Transparency", "ApplyStrokeMode", "LineJoinMode", "Enabled" },
	UIGradient = { "Color", "Transparency", "Rotation", "Offset", "Enabled" },
	UIScale = { "Scale" },
	UIAspectRatioConstraint = { "AspectRatio", "AspectType", "DominantAxis" },
	UISizeConstraint = { "MinSize", "MaxSize" },
	UITextSizeConstraint = { "MinTextSize", "MaxTextSize" },
	UIFlexItem = { "FlexMode", "GrowRatio", "ShrinkRatio", "ItemLineAlignment" },
}

local function isGuiNode(rec): boolean
	return rec.isA.GuiBase2d or rec.isA.UIComponent or rec.isA.UIBase or rec.isA.Folder
end

local function dumpNode(inst, depth: number)
	local st = S[inst]
	local rec = st.info.rec
	local props = {}
	local list = if rec.isA.GuiBase2d then PROPS else (MODIFIER_PROPS[st.className] or {})
	for _, name in list do
		if rec.props[name] and props[name] == nil then
			local ok, v = pcall(get, inst, name)
			if ok and v ~= nil then
				local e = encode(v)
				if e ~= nil then
					props[name] = e
				end
			end
		end
	end
	local attrs = {}
	if st.attrs then
		for k, v in st.attrs do
			local e = encode(v)
			if e ~= nil then
				attrs[k] = e
			end
		end
	end
	local children = {}
	if depth < 80 and not rec.isA.ViewportFrame then
		for _, c in st.children do
			local cs = S[c]
			if isGuiNode(cs.info.rec) and not cs.info.rec.isA.LayerCollector then
				table.insert(children, dumpNode(c, depth + 1))
			end
		end
	end
	return {
		class = st.className,
		name = st.name,
		props = props,
		attrs = attrs,
		children = children,
	}
end

local function playerGui()
	return Inst.findChild(S[World.player], "PlayerGui")
end

local function collectRoots()
	local roots = {}
	local pg = playerGui()
	for _, gui in S[pg].children do
		local st = S[gui]
		if st.className == "ScreenGui" then
			local node = dumpNode(gui, 0)
			node.kind = "screen"
			node.path = Inst.fullName(gui)
			table.insert(roots, node)
		end
	end
	local function billboards(container, where)
		for _, d in Inst.descendants(container) do
			local st = S[d]
			if st.className == "BillboardGui" then
				local node = dumpNode(d, 0)
				node.kind = "billboard"
				node.container = where
				node.path = Inst.fullName(d)
				if st.parent then
					node.parentPath = Inst.fullName(st.parent)
				end
				table.insert(roots, node)
			end
		end
	end
	billboards(pg, "PlayerGui")
	billboards(Services.byClass.Workspace, "Workspace")
	return roots
end

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local clientRealm, clientFolder, outDir
local written, skipped = {}, {}

local function advance(seconds: number)
	Sched.advance(seconds)
end

--- Lets things move for `seconds`, then finishes short tweens.
local function settle(seconds: number)
	advance(seconds)
	Services.settleTweens(1.0)
end

local function dump(name: string, note: string?)
	Report.step = "snapshot " .. name
	local data = {
		checkpoint = name,
		viewport = { w = Classes.viewport.X, h = Classes.viewport.Y },
		guiInset = Classes.guiInset,
		roots = collectRoots(),
	}
	local file = outDir .. "/" .. name .. ".json"
	fs.writeFile(file, serde.encode("json", data, true))
	table.insert(written, { name = name, file = file, note = note, roots = #data.roots })
end

local function skip(name: string, reason: string)
	table.insert(skipped, { name = name, reason = reason })
end

--- A loaded client module by folder + name: (value, nil) or (nil, why not).
local function clientModule(folderName: string, moduleName: string)
	local folder = Inst.findChild(S[clientFolder], folderName)
	local module = folder and Inst.findChild(S[folder], moduleName)
	if not module then
		return nil, folderName .. "/" .. moduleName .. " does not exist"
	end
	local entry = clientRealm.cache[module]
	if not entry then
		return nil, moduleName .. " was never required"
	end
	if entry.state ~= "loaded" then
		local cause = Loader.failureOf(clientRealm, module)
		return nil, moduleName .. " failed to load" .. (if cause then " (" .. string.gsub(cause, "%[smoke%-abort%] ", "") .. ")" else "")
	end
	return entry.value, nil
end

local function call(fn, label: string, ...)
	Sched.run(fn, label, ...)
end

local function closeAll()
	local Window = clientModule("Components", "Window")
	if Window and type(Window.CloseAll) == "function" then
		call(Window.CloseAll, "Window.CloseAll")
	end
	local Kit = clientModule("Components", "Kit")
	if Kit and type(Kit.CloseAll) == "function" then
		call(Kit.CloseAll, "Kit.CloseAll")
	end
	advance(0.5)
end

local function anyWindowOpen(): boolean?
	local Window = clientModule("Components", "Window")
	if Window and type(Window.AnyOpen) == "function" then
		local ok, open = pcall(Window.AnyOpen)
		return ok and open == true
	end
	return nil
end

local function findButton(guiName: string, buttonName: string?)
	local gui = Inst.findChild(S[playerGui()], guiName)
	if not gui then
		return nil
	end
	for _, d in Inst.descendants(gui) do
		local st = S[d]
		if st.info.rec.isA.GuiButton and (buttonName == nil or st.name == buttonName) then
			return d
		end
	end
	return nil
end

local function press(button)
	local io = Inst.create("InputObject")
	S[io].props.UserInputType = if Services.profile.touch then Enum.UserInputType.Touch else Enum.UserInputType.MouseButton1
	S[io].props.UserInputState = Enum.UserInputState.End
	Inst.fire(button, "MouseButton1Click")
	Inst.fire(button, "Activated", io, 1)
	Sched.drain()
end

local function midGameProfile()
	local data = World.data
	local now = math.floor(World.serverNow())
	data.Cash = 1_284_500
	data.Rebirths = 1
	data.Buffs.Luck = now + 540
	data.Buffs.HatchSpeed = now + 300
	data.Upgrades.NestSlots = 3
	data.Upgrades.IncubationSpeed = 2
	data.Upgrades.WalkSpeed = 2
	data.Stats.Hatches = 12
	data.Stats.EggsBought = 15
	data.Stats.TotalCashEarned = 2_400_000
	data.Nests[1] = { Kind = "Egg", EggId = "mountain", Incubated = 60, Vault = 0, AcquiredAt = now - 60, LastIncomeAt = now }
	data.Nests[2] = { Kind = "Creature", CreatureId = "mothman", Rarity = "Epic", Vault = 18000, AcquiredAt = now - 900, LastIncomeAt = now }
	data.Nests[3] = { Kind = "Creature", CreatureId = "yeti", Rarity = "Rare", Vault = 4200, AcquiredAt = now - 600, LastIncomeAt = now }
	data.Nests[4] = { Kind = "Creature", CreatureId = "nessie", Rarity = "Legendary", Vault = 60000, AcquiredAt = now - 300, LastIncomeAt = now }
	for _, id in { "jackalope", "hodag", "gremlin", "chupacabra", "yeti", "mothman", "nessie" } do
		data.Codex[id] = true
	end
end

--------------------------------------------------------------------------
-- Checkpoints
--------------------------------------------------------------------------

local POPUPS = {
	{ name = "robuxshop", controller = "RobuxShopController" },
	{ name = "upgradeshop", controller = "UpgradeShopController", prompt = true },
	{ name = "rebirth", controller = "RebirthController" },
	{ name = "codex", controller = "CodexController" },
	{ name = "dailyrewards", controller = "DailyRewardsController" },
	{ name = "spinwheel", controller = "SpinWheelController" },
	{ name = "playtimegifts", controller = "PlaytimeGiftsController" },
	{ name = "settings", controller = "SettingsController" },
}

local function openUpgradeShopByPrompt()
	-- UpgradeShopController opens on ProximityPromptService.PromptTriggered
	-- for the counter's "ShopPrompt" (ShopId = "Upgrades"), and closes again
	-- if you're further than Config.Shop.InteractDistance from the counter.
	local counter = World.shopCounter
	local prompt = counter and Inst.findChild(S[counter], "ShopPrompt")
	if not prompt then
		return false
	end
	World.moveCharacter(get(counter, "Position") + Vector3.new(0, 3, -6))
	local pps = Services.byClass.ProximityPromptService
	Inst.fire(pps, "PromptTriggered", prompt, World.player)
	Inst.fire(prompt, "Triggered", World.player)
	Sched.drain()
	return true
end

local function checkpointPopups()
	for _, p in POPUPS do
		closeAll()
		local module, why = clientModule("Controllers", p.controller)
		if not module then
			skip(p.name, why)
			continue
		end
		if type(module.Open) == "function" then
			call(module.Open, p.controller .. ".Open()")
		elseif p.prompt then
			openUpgradeShopByPrompt()
		else
			skip(p.name, p.controller .. " has no Open() function")
			continue
		end
		settle(1.2)
		local open = anyWindowOpen()
		dump(p.name, if open == false then "Window.AnyOpen() was false after opening" else nil)
	end
	closeAll()
	World.moveCharacter(World.itemCFrame(1, 2).Position + Vector3.new(0, 3, -8))
end

local function checkpointToasts()
	local Notification, why = clientModule("Controllers", "NotificationController")
	if not Notification or type(Notification.Show) ~= "function" then
		skip("toasts", why or "NotificationController has no Show()")
		return
	end
	local Config = World.Config
	call(Notification.Show, "toast", "Welcome back to camp!", "Info")
	call(Notification.Show, "toast", "Bought a Forest Egg!", "Success")
	call(Notification.Show, "toast", "That camp is locked.", "Warning")
	call(Notification.Show, "toast", "Not enough cash (need $600).", "Error")
	call(Notification.Show, "toast", "Player2 hatched a Legendary Nessie!", "Announce", Config.Rarities.Legendary.Color)
	settle(0.8)
	dump("toasts")
	advance(5)
end

local function checkpointReveal()
	closeAll()
	local Config = World.Config
	local def = Config.CreaturesById.nessie
	World.placeCreature(1, 5, 1, "nessie", 0)
	World.fire("HatchResult", "nessie", def.Rarity, nil, "deepsea", World.itemCFrame(1, 5).Position)
	settle(1.3)
	dump("reveal")
	advance(6)
end

local function checkpointTutorial()
	local Tutorial, why = clientModule("Controllers", "TutorialController")
	if not Tutorial or type(Tutorial.Run) ~= "function" then
		skip("tutorial", why or "TutorialController has no Run()")
		return
	end
	closeAll()
	-- A fresh player: nothing hatched, nothing in the nests.
	local saved = World.data
	local fresh = table.clone(saved)
	fresh.Stats = table.clone(saved.Stats)
	fresh.Stats.Hatches = 0
	fresh.Stats.EggsBought = 0
	fresh.Cash = 500
	fresh.Rebirths = 0
	fresh.Nests = {}
	for i = 1, #saved.Nests do
		fresh.Nests[i] = false
	end
	World.data = fresh
	World.pushProfile()
	call(Tutorial.Run, "TutorialController.Run()")
	settle(0.8)
	-- Step 1 is a welcome card; its button moves on to step 2.
	local button = findButton("Tutorial", "Continue")
	if not button then
		local gui = Inst.findChild(S[playerGui()], "Tutorial")
		if gui then
			for _, d in Inst.descendants(gui) do
				if S[d].info.rec.isA.GuiButton and not string.find(string.lower(S[d].name), "skip", 1, true) then
					button = d
					break
				end
			end
		end
	end
	if button then
		press(button)
	end
	settle(1.0)
	dump("tutorial", if button then nil else "could not find the tutorial's continue button; this is step 1")
	-- Finish it (Skip twice) and go back to the mid-game save.
	local skipButton = findButton("Tutorial", "Skip")
	if skipButton then
		press(skipButton)
		advance(0.3)
		press(skipButton)
	end
	advance(1)
	World.data = saved
	World.pushProfile()
	advance(1)
end

local function checkpointSighting()
	closeAll()
	local Config = World.Config
	local home = World.rootPosition()
	local spot = home + Vector3.new(70, 0, 20)
	local now = World.serverNow()
	World.wildCryptid("yeti", spot, 11, now + Config.Sightings.Duration)
	World.fire("SightingBanner", "Started", {
		SightingId = 11, CreatureId = "yeti", Name = "Yeti", Label = "Yeti", Rarity = "Rare",
		Hint = "Deep in the north woods", Position = spot, StartedAt = now, ExpiresAt = now + Config.Sightings.Duration,
	})
	settle(1.5)
	dump("sighting")
	for _, m in Inst.getTagged(Config.Tags.WildCryptid) do
		Inst.destroy(m)
	end
	World.fire("SightingBanner", "Escaped", { SightingId = 11, Name = "Yeti", Label = "Yeti", Rarity = "Rare" })
	advance(6)
end

local function checkpointHunt()
	closeAll()
	local Config = World.Config
	local hs = World.huntState
	local home = World.rootPosition()
	local now = World.serverNow()
	Inst.setAttribute(hs, "Phase", "Warning")
	Inst.setAttribute(hs, "StartsAt", now + 1)
	Inst.setAttribute(hs, "Position", home + Vector3.new(120, 0, 0))
	World.fire("HuntEvent", "Warning", { StartsAt = now + 1, Position = home + Vector3.new(120, 0, 0) })
	advance(1)
	local endsAt = World.serverNow() + Config.Hunt.Duration
	Inst.setAttribute(World.player, "Carrying", true)
	Inst.setAttribute(hs, "Phase", "Hunting")
	Inst.setAttribute(hs, "EndsAt", endsAt)
	Inst.setAttribute(hs, "TargetUserId", 1)
	Inst.setAttribute(hs, "Position", home + Vector3.new(45, -3, 0))
	World.fire("HuntEvent", "Started", { EndsAt = endsAt })
	settle(2.5)
	dump("hunt")
	Inst.setAttribute(hs, "Phase", "Idle")
	Inst.setAttribute(hs, "TargetUserId", 0)
	World.fire("HuntEvent", "Ended", { Caught = 0 })
	Inst.setAttribute(World.player, "Carrying", false)
	advance(4)
end

local function checkpointSteal()
	closeAll()
	local Config = World.Config
	local returnAt = World.serverNow() + Config.Steal.UnclaimedReturnTime
	local model = World.carryModel({ eggId = "mountain", source = "Steal", label = "Mountain Egg", carrierId = 2, ownerId = 1, ownerName = "Player1", returnAt = returnAt, carryId = 901 })
	World.fire("StealAlarm", "Stolen", { Item = "Mountain Egg", NestIndex = 1, ReturnAt = returnAt, Thief = "Player2", CarryId = 901 })
	settle(1.0)
	dump("steal")
	Inst.destroy(model)
	World.fire("StealAlarm", "Returned", { Item = "Mountain Egg", NestIndex = 1, ReturnAt = returnAt, Thief = "Player2", CarryId = 901 })
	advance(5)
end

local function checkpointPrompt()
	closeAll()
	local home = World.rootPosition()
	local part = World.new("Part", { Name = "SnapshotEgg", CFrame = CFrame.new(home + Vector3.new(0, -1, -5)), Size = Vector3.new(2.6, 3.4, 2.6), Anchored = true }, Services.byClass.Workspace)
	local prompt = World.new("ProximityPrompt", {
		Name = "StealPrompt",
		ActionText = "Steal",
		ObjectText = "Forest Egg",
		HoldDuration = 3,
		KeyboardKeyCode = Enum.KeyCode.E,
	}, part)
	Sched.drain()
	advance(0.2)
	local pps = Services.byClass.ProximityPromptService
	local inputType = if Services.profile.touch then Enum.ProximityPromptInputType.Touch else Enum.ProximityPromptInputType.Keyboard
	Inst.fire(pps, "PromptShown", prompt, inputType)
	Inst.fire(prompt, "PromptShown", inputType)
	settle(0.5)
	Inst.fire(pps, "PromptButtonHoldBegan", prompt, World.player)
	Inst.fire(prompt, "PromptButtonHoldBegan", World.player)
	advance(1.5)
	Services.settleTweens(0.3)
	dump("prompt", "mid-hold: 1.5 s into a 3 s hold")
	Inst.fire(pps, "PromptButtonHoldEnded", prompt, World.player)
	Inst.fire(prompt, "PromptButtonHoldEnded", World.player)
	Inst.fire(pps, "PromptHidden", prompt)
	Inst.fire(prompt, "PromptHidden")
	Inst.destroy(part)
	advance(1)
end

local function checkpointHotbar()
	closeAll()
	local player = World.player
	local backpack = Inst.findChild(S[player], "Backpack")
	local character = get(player, "Character")
	local tools = {}
	for _, c in S[backpack].children do
		if S[c].info.rec.isA.Tool then
			table.insert(tools, c)
		end
	end
	if #tools < 2 or not character then
		skip("hotbar", "expected two tools in the Backpack")
		return
	end
	Inst.setParent(tools[1], S[tools[1]], character)
	settle(0.8)
	dump("hotbar", S[tools[1]].name .. " equipped, " .. S[tools[2]].name .. " in the Backpack")
	Inst.setParent(tools[1], S[tools[1]], backpack)
	advance(0.5)
end

--------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------

function Snapshot.run(realm, client, dir: string)
	clientRealm, clientFolder, outDir = realm, client, dir
	if not fs.isDir(outDir) then
		fs.writeDir(outDir)
	end

	-- Start the client with a mid-game save.
	Report.step = "snapshot startup"
	midGameProfile()
	for _, d in Inst.descendants(client) do
		if S[d].className == "LocalScript" and get(d, "Enabled") ~= false then
			Loader.runScript(clientRealm, d)
		end
	end
	advance(0.5)
	World.claimPlot()
	World.placeEgg(1, 1, 1, "mountain", 0.66)
	World.placeCreature(1, 3, 1, "yeti", 4200)
	World.placeCreature(1, 4, 1, "nessie", 60000)
	advance(4.5)
	World.retention.startedAt = Sched.now
	World.pushProfile()
	World.pushRetention()
	advance(3)

	-- The offline-cash popup opens by itself on join (and keeps coming back
	-- until the cash is claimed): capture it, then claim it so the other
	-- checkpoints show one thing each.
	settle(1.5)
	if anyWindowOpen() then
		dump("offline")
	end
	World.retention.pendingOffline = 0
	World.pushRetention()
	-- Daily Rewards then pops up once on join (when claimable): close it so
	-- the HUD shot is just the HUD (it has its own checkpoint below).
	for _ = 1, 3 do
		closeAll()
		settle(2)
		if not anyWindowOpen() then
			break
		end
	end
	local hud = clientModule("Controllers", "HudController")
	dump("hud", if hud then nil else "HudController is not loaded: only the other controllers' UI is on screen")
	checkpointPopups()
	checkpointToasts()
	checkpointReveal()
	checkpointTutorial()
	checkpointSighting()
	checkpointHunt()
	checkpointSteal()
	checkpointPrompt()
	checkpointHotbar()

	local index = {
		viewport = { w = Classes.viewport.X, h = Classes.viewport.Y },
		guiInset = Classes.guiInset,
		checkpoints = written,
		skipped = skipped,
	}
	fs.writeFile(outDir .. "/index.json", serde.encode("json", index, true))
	return index
end

return Snapshot
