--!strict
--[[
	HudController
	StarterPlayerScripts/Client/Controllers/HudController

	The main HUD, on the STUD kit's HUD screen:

	  bottom-left   cash; rebirth count + income bonus; "+" opens the Store
	  side buttons  Store, Rebirth (red "!" when you can rebirth), Invite
	                (Roblox invite prompt), Settings, Index (the Codex —
	                Step 7). Gift is hidden until Playtime Gifts (Step 7.5).
	  top buttons   Base -> fast travel home; Eggs -> fast travel to the Egg
	                Shop. Sell is hidden (no selling in this game).
	  right offers  quick-buy Luck Potion and the 3-Egg Bundle
	  hidden        toolbar, inventory, Daily (Step 7.5), dev placeholders

	Plus our own small additions above the cash: active buff chips with
	countdowns, and a warning if the server isn't saving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Kit = require(Components:WaitForChild("Kit"))
local Icon = require(Components:WaitForChild("Icon"))
local ScreenScale = require(Components:WaitForChild("ScreenScale"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local RobuxShopController = require(script.Parent:WaitForChild("RobuxShopController"))
local RebirthController = require(script.Parent:WaitForChild("RebirthController"))
local SettingsController = require(script.Parent:WaitForChild("SettingsController"))

local HudController = {}

local localPlayer = Players.LocalPlayer

local BUFFS: { { key: string, icon: string } } = {
	{ key = "Luck", icon = "Potion" },
	{ key = "HeatRate", icon = "Bonfire" },
}

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function onActivated(button: Instance?, fn: () -> ())
	if button and button:IsA("GuiButton") then
		button.Activated:Connect(fn)
	end
end

local function travel(destination: string)
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Travel") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer(destination)
	end)
	if ok and typeof(result) == "table" and not result.Ok then
		NotificationController.Show(tostring(result.Message or ""), "Error")
	end
end

local function invite()
	local ok, canInvite = pcall(function()
		return SocialService:CanSendGameInviteAsync(localPlayer)
	end)
	if ok and canInvite then
		pcall(function()
			SocialService:PromptGameInvite(localPlayer)
		end)
	else
		NotificationController.Show("Invites aren't available right now.", "Info")
	end
end

--- Our buff chips + saving warning, as small pills above the kit's cash.
local function buildExtras(gui: ScreenGui): ({ [string]: TextLabel }, TextLabel)
	local row = Instance.new("Frame")
	row.Name = "Extras"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0, 1)
	row.Position = UDim2.new(0.01, 0, 0.865, 0)
	row.Size = UDim2.fromOffset(0, 30)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.Parent = gui
	ScreenScale.Apply(row)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = row

	local function pill(name: string, order: number, iconName: string): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.LayoutOrder = order
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromOffset(0, 30)
		label.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
		label.BackgroundTransparency = 0.25
		label.TextColor3 = Color3.fromRGB(180, 255, 190)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 16
		label.Visible = false
		label.Parent = row
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = label
		local padding = Instance.new("UIPadding")
		padding.PaddingRight = UDim.new(0, 10)
		padding.Parent = label
		Icon.addLeft(label, iconName, 22, 4)
		return label
	end

	local chips: { [string]: TextLabel } = {}
	for i, buff in ipairs(BUFFS) do
		chips[buff.key] = pill("Buff_" .. buff.key, i, buff.icon)
	end
	local warning = pill("NotSaving", 10, "Warning")
	warning.BackgroundColor3 = Color3.fromRGB(150, 30, 40)
	warning.TextColor3 = Color3.new(1, 1, 1)
	warning.Text = "PROGRESS NOT SAVING"
	return chips, warning
end

function HudController.Start()
	local gui = Kit.Mount("HUD")
	gui.Enabled = true

	-- Cash (the two "CashText" labels: cash on top, a status line below).
	local bottomLeft = gui:WaitForChild("BottomLeft")
	local cashLabels = Kit.ChildrenNamed(bottomLeft, "CashText")
	local cashText = cashLabels[1]
	local statusText = cashLabels[2]
	onActivated(bottomLeft:FindFirstChild("AddBtn"), RobuxShopController.Open)

	-- Side buttons
	local side = gui:WaitForChild("SideButtons")
	local function sideButton(name: string): Instance?
		local frame = side:FindFirstChild(name)
		return frame and frame:FindFirstChild("Container")
	end
	onActivated(sideButton("ShopBtn"), RobuxShopController.Open)
	onActivated(sideButton("RebirthBtn"), RebirthController.Open)
	onActivated(sideButton("SettingsBtn"), SettingsController.Open)
	onActivated(sideButton("InviteBtn"), invite)
	onActivated(sideButton("IndexBtn"), function()
		NotificationController.Show("The Cryptid Codex arrives in the next update!", "Info")
	end)
	Kit.Hide(side:FindFirstChild("GiftBtn")) -- Playtime Gifts, Step 7.5

	-- The kit ships "!" badges on Index and Gift. Use one for Rebirth instead.
	local indexContainer = sideButton("IndexBtn")
	local badgeTemplate = indexContainer and indexContainer:FindFirstChild("Alert")
	local rebirthBadge: GuiObject? = nil
	local rebirthContainer = sideButton("RebirthBtn")
	if badgeTemplate and rebirthContainer then
		rebirthBadge = badgeTemplate:Clone() :: GuiObject
		rebirthBadge.Parent = rebirthContainer
		badgeTemplate.Visible = false
	end

	-- Top buttons: Base / Eggs fast travel; no selling.
	local top = gui:WaitForChild("TopButtons")
	Kit.Hide(top:FindFirstChild("SellBtn"))
	onActivated(top:FindFirstChild("BaseBtn"), function()
		travel("Home")
	end)
	local eggsButton = top:FindFirstChild("ShopBtn")
	Kit.SetText(eggsButton and eggsButton:FindFirstChildWhichIsA("TextLabel"), "Eggs")
	onActivated(eggsButton, function()
		travel("EggShop")
	end)

	-- Right-side offers: quick-buy Luck Potion and the egg bundle.
	local function setupOffer(button: Instance?, title: string, kind: string, key: string, iconName: string?): TextLabel?
		if not button then
			return nil
		end
		local art = button:FindFirstChild("Item")
		local priceLabel: TextLabel? = nil
		if art then
			for _, label in ipairs(art:GetChildren()) do
				if label:IsA("TextLabel") then
					if label.Text:find("R%$") then
						priceLabel = label
					else
						label.Text = title
					end
				end
			end
			if iconName and art:IsA("ImageLabel") then
				art.Image = Config.Icons[iconName]
			end
		end
		onActivated(button, function()
			RobuxShopController.Buy(kind, key)
		end)
		return priceLabel
	end
	local potionPrice = setupOffer(gui:FindFirstChild("Item"), "LUCK", "Product", "LuckPotion", "Potion")
	local bundlePrice = setupOffer(gui:FindFirstChild("StarterPack"), "3 Eggs!", "Product", "EggBundle", nil)

	-- Not used by this game (or not yet).
	for _, name in ipairs({ "ToolBar", "Inventory", "PLACEHOLDERS", "BottomRight" }) do
		Kit.Hide(gui:FindFirstChild(name))
	end

	local chips, warning = buildExtras(gui)

	-- Server clock at the moment the latest snapshot arrived (buff expiry
	-- times are server os.time values).
	local snapshotServerTime = os.time()
	local snapshotClock = os.clock()

	local function render(snapshot: { [string]: any })
		local cash = tonumber(snapshot.Cash) or 0
		local rebirths = tonumber(snapshot.Rebirths) or 0
		Kit.SetText(cashText, "$" .. Config.FormatNumber(cash))
		if rebirths > 0 then
			Kit.SetText(statusText, string.format("Rebirth %d  ·  +%d%% cash", rebirths,
				math.floor(rebirths * Config.Rebirth.IncomeBonusPerRebirth * 100 + 0.5)))
		else
			Kit.SetText(statusText, "Rebirth 0")
		end
		warning.Visible = snapshot.IsPersistent == false
	end

	local function tick()
		local snapshot = ProfileController.Get()
		local buffs = snapshot and snapshot.Buffs or {}
		local serverNow = snapshotServerTime + (os.clock() - snapshotClock)
		for key, chip in pairs(chips) do
			local expiry = tonumber(buffs[key])
			local remaining = if expiry then expiry - serverNow else 0
			chip.Visible = remaining > 0
			if remaining > 0 then
				chip.Text = formatClock(remaining)
			end
		end
		if rebirthBadge then
			rebirthBadge.Visible = RebirthController.CanRebirth()
		end
		Kit.SetText(potionPrice, RobuxShopController.PriceText("Product", "LuckPotion"))
		Kit.SetText(bundlePrice, RobuxShopController.PriceText("Product", "EggBundle"))
	end

	ProfileController.Changed:Connect(function(snapshot)
		snapshotServerTime = tonumber(snapshot.ServerTime) or os.time()
		snapshotClock = os.clock()
		render(snapshot)
		tick()
	end)
	local existing = ProfileController.Get()
	if existing then
		snapshotServerTime = tonumber(existing.ServerTime) or os.time()
		render(existing)
	else
		Kit.SetText(cashText, "...")
		Kit.SetText(statusText, "")
	end

	task.spawn(function()
		while true do
			task.wait(0.5)
			tick()
		end
	end)
end

return HudController
