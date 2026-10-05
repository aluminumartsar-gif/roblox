--!strict
--[[
	RebirthController
	StarterPlayerScripts/Client/Controllers/RebirthController

	The rebirth screen, on the STUD kit's Rebirth popup, opened from the HUD's
	Rebirth button:
	  * reward tiles: total luck, total income, a new nest glow, and the egg
	    the next rebirth unlocks (if any)
	  * progress bar: cash toward the rebirth cost; requirement line shows
	    whether a Rare+ cryptid is at home
	  * CLAIM -> the kit's Confirmation popup -> DoRebirth

	A preview only; RebirthService re-checks everything on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Kit = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Kit"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local RebirthController = {}

local GOOD = Color3.fromRGB(120, 255, 140)
local BAD = Color3.fromRGB(255, 120, 120)

local popup: Kit.Popup
local confirmPopup: Kit.Popup
local titleLabel: TextLabel?
local progressLabel: TextLabel?
local requirementLabel: TextLabel?
local barFill: GuiObject?
local tiles: { { title: TextLabel?, icon: ImageLabel?, frame: GuiObject } } = {}
local confirmText: TextLabel?
local busy = false

type Status = { ready: boolean, reason: string?, cost: number, cash: number, hasRare: boolean, nextRebirth: number }

local function status(): Status?
	local snapshot = ProfileController.Get()
	if not snapshot then
		return nil
	end
	local rebirths = tonumber(snapshot.Rebirths) or 0
	local cash = tonumber(snapshot.Cash) or 0
	local cost = Config.GetRebirthCost(rebirths)
	local hasRare = false
	for _, slot in ipairs(snapshot.Nests or {}) do
		if typeof(slot) == "table" and slot.Kind == "Creature" and not slot.Away
			and Config.GetRarityIndex(slot.Rarity) >= Config.RebirthMinRarityIndex then
			hasRare = true
		end
	end
	local minRarity = Config.RarityOrder[Config.RebirthMinRarityIndex]
	local reason = nil
	if not hasRare then
		reason = string.format("You need a %s or better cryptid at home.", minRarity)
	elseif cash < cost then
		reason = string.format("You need $%s.", Config.FormatNumber(cost))
	end
	return { ready = reason == nil, reason = reason, cost = cost, cash = cash, hasRare = hasRare, nextRebirth = rebirths + 1 }
end

local function setTile(i: number, text: string?, iconName: string?)
	local tile = tiles[i]
	if not tile then
		return
	end
	tile.frame.Visible = text ~= nil
	if text then
		Kit.SetText(tile.title, text)
		if tile.icon and iconName and Config.Icons[iconName] then
			tile.icon.Image = Config.Icons[iconName]
		end
	end
end

local function refresh()
	local s = status()
	if not s then
		return
	end
	Kit.SetText(titleLabel, "Rebirth " .. s.nextRebirth)

	local fraction = if s.cost > 0 then math.clamp(s.cash / s.cost, 0, 1) else 1
	if barFill then
		barFill.Size = UDim2.new(fraction, 0, barFill.Size.Y.Scale, barFill.Size.Y.Offset)
	end
	Kit.SetText(progressLabel, string.format("$%s / $%s", Config.FormatNumber(s.cash), Config.FormatNumber(s.cost)))

	if requirementLabel then
		local minRarity = Config.RarityOrder[Config.RebirthMinRarityIndex]
		requirementLabel.Text = string.format("Needs a %s+ cryptid: %s", minRarity, if s.hasRare then "YES" else "NO")
		requirementLabel.TextColor3 = if s.hasRare then GOOD else BAD
	end

	setTile(1, string.format("+%d%% Luck", s.nextRebirth * Config.Luck.PerRebirthPercent), "Luck")
	setTile(2, string.format("+%d%% Cash", math.floor(s.nextRebirth * Config.Rebirth.IncomeBonusPerRebirth * 100 + 0.5)), "Cash")
	setTile(3, "New Glow", "Star")
	local unlock: string? = nil
	for _, eggId in ipairs(Config.EggOrder) do
		if Config.Eggs[eggId].RequiredRebirths == s.nextRebirth then
			unlock = Config.Eggs[eggId].Name
		end
	end
	setTile(4, unlock, "Egg")
end

local function doRebirth()
	if busy then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DoRebirth") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	busy = false
	confirmPopup:Close()
	if ok and typeof(result) == "table" then
		NotificationController.Show(tostring(result.Message or ""), if result.Ok then "Success" else "Error")
	else
		NotificationController.Show("Couldn't reach the server.", "Error")
	end
end

function RebirthController.Open()
	popup:Open()
end

--- True when the player could rebirth right now (the HUD shows an alert).
function RebirthController.CanRebirth(): boolean
	local s = status()
	return s ~= nil and s.ready
end

local function buildConfirm()
	local gui = Kit.Mount("ConfirmationPopup")
	confirmPopup = Kit.Popup(gui)
	local navBar = Kit.Deep(gui.Container, "NavBar")
	Kit.SetText(navBar and navBar:FindFirstChild("Title"), "CONFIRM REBIRTH")
	local content = Kit.Deep(gui.Container, "Content")
	confirmText = content and content:FindFirstChild("Title")
	if confirmText then
		confirmText.TextWrapped = true
	end
	local yes = content and content:FindFirstChild("Yes")
	local no = content and content:FindFirstChild("No")
	if yes and yes:IsA("GuiButton") then
		yes.Activated:Connect(doRebirth)
	end
	if no and no:IsA("GuiButton") then
		no.Activated:Connect(function()
			confirmPopup:Close()
		end)
	end
end

function RebirthController.Start()
	local gui = Kit.Mount("Rebirth")
	popup = Kit.Popup(gui)
	popup.OnOpen = refresh

	local content = Kit.Deep(gui.Container, "Content")
	for _, child in ipairs(content:GetChildren()) do
		if child.Name == "Title" and child:IsA("TextLabel") then
			if child.Text:match("^Rebirth") then
				titleLabel = child
			elseif child.Text:find("/") then
				progressLabel = child
			elseif child.Text:match("Requirement") then
				requirementLabel = child
			end
		end
	end
	local bar = content:FindFirstChild("Bar")
	barFill = bar and bar:FindFirstChild("InsideBar")
	Kit.Hide(content:FindFirstChild("SkipBtn"))

	for _, item in ipairs(Kit.ChildrenNamed(content, "Item")) do
		local clipping = item:FindFirstChild("ClippingItems")
		table.insert(tiles, {
			frame = item,
			title = item:FindFirstChild("Title"),
			icon = clipping and clipping:FindFirstChild("Icon"),
		})
	end

	buildConfirm()

	local claim = content:FindFirstChild("ClaimBtn")
	Kit.SetButtonText(claim, "REBIRTH")
	if claim and claim:IsA("GuiButton") then
		claim.Activated:Connect(function()
			local s = status()
			if not s then
				return
			end
			if not s.ready then
				NotificationController.Show(s.reason or "Not yet.", "Error")
				return
			end
			if confirmText then
				confirmText.Text = string.format("Rebirth for $%s? You lose your cash, eggs, cryptids and upgrades.",
					Config.FormatNumber(s.cost))
			end
			confirmPopup:Open()
		end)
	end

	ProfileController.Changed:Connect(function()
		if popup:IsOpen() then
			refresh()
		end
	end)
end

return RebirthController
