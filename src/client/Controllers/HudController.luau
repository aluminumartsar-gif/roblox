--!strict
--[[
	HudController
	StarterPlayerScripts/Client/Controllers/HudController

	The main HUD, on the STUD kit's HUD screen:

	  bottom-left   cash; rebirth count + income bonus; "+" opens the Store
	  side buttons  Store, Rebirth (red "!" when you can rebirth), Invite
	                (Roblox invite prompt), Settings, Index (the Codex —
	                Step 7). Gift is hidden until Playtime Gifts (Step 7.5).
	  top buttons   Base -> fast travel home; Eggs -> fast travel to the egg
	                belt. Sell is hidden (no selling in this game).
	  right offers  quick-buy Luck Potion and the 3-Egg Bundle
	  hidden        toolbar, inventory, Daily (Step 7.5), dev placeholders

	Plus our own small additions above the cash: active buff chips with
	countdowns, and a warning if the server isn't saving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")

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

local hudGui: ScreenGui? = nil
local alertTemplate: GuiObject? = nil

local BUFFS: { { key: string, icon: string } } = {
	{ key = "Luck", icon = "Potion" },
	{ key = "HatchSpeed", icon = "Bonfire" },
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

--------------------------------------------------------------------------
-- Buttons other controllers own (Codex, Daily, Gifts, Spin)
--------------------------------------------------------------------------

local function findButtonFrame(name: string): Instance?
	local gui = hudGui
	if not gui then
		return nil
	end
	if name == "DailyBtn" then
		local bottomRight = gui:FindFirstChild("BottomRight")
		return bottomRight and bottomRight:FindFirstChild("DailyBtn")
	end
	local side = gui:FindFirstChild("SideButtons")
	if not side then
		return nil
	end
	local frame = side:FindFirstChild(name)
	if not frame and name == "SpinBtn" then
		-- The kit has no Spin button: make one from the Gift button.
		local gift = side:FindFirstChild("GiftBtn")
		if gift then
			local copy = gift:Clone()
			copy.Name = "SpinBtn"
			copy.Parent = side
			frame = copy
		end
	end
	return frame
end

--- Shows a HUD button and runs `fn` when it's pressed. Names:
---   "IndexBtn" (Codex), "GiftBtn" (Playtime Gifts), "DailyBtn" (Daily
---   Rewards, bottom right), "SpinBtn" (Spin Wheel — a copy of the Gift
---   button). Optional caption and icon (a Config.Icons name) restyle it.
--- Call from a controller's Start(); HudController always starts first.
function HudController.Bind(name: string, fn: () -> (), caption: string?, iconName: string?): Instance?
	local frame = findButtonFrame(name)
	if not frame then
		warn("[SAC/HUD] no HUD button called " .. name)
		return nil
	end
	if frame:IsA("GuiObject") then
		frame.Visible = true
	end
	if name == "DailyBtn" and frame.Parent and frame.Parent:IsA("GuiObject") then
		frame.Parent.Visible = true
	end
	local container = frame:FindFirstChild("Container")
	local contents = container and container:FindFirstChild("Contents")
	if caption then
		Kit.SetText(contents and contents:FindFirstChild("TextLabel"), caption)
	end
	local icon = contents and contents:FindFirstChild("Icon")
	if iconName and icon and icon:IsA("ImageLabel") and Config.Icons[iconName] then
		icon.Image = Config.Icons[iconName]
	end
	onActivated(container, fn)
	return frame
end

--- Shows or hides the red "!" badge on a bound button.
function HudController.SetAlert(name: string, visible: boolean)
	local frame = findButtonFrame(name)
	local container = frame and frame:FindFirstChild("Container")
	if not container then
		return
	end
	local alert = container:FindFirstChild("Alert")
	if not alert and alertTemplate then
		local copy = alertTemplate:Clone()
		copy.Parent = container
		alert = copy
	end
	if alert and alert:IsA("GuiObject") then
		alert.Visible = visible
	end
end

--- Changes a bound button's caption (e.g. to show a countdown).
function HudController.SetCaption(name: string, text: string)
	local frame = findButtonFrame(name)
	local container = frame and frame:FindFirstChild("Container")
	local contents = container and container:FindFirstChild("Contents")
	Kit.SetText(contents and contents:FindFirstChild("TextLabel"), text)
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

	-- The kit ships "!" badges on Index and Gift. Keep a copy as a template
	-- (any bound button can show one) and give one to Rebirth.
	local indexContainer = sideButton("IndexBtn")
	local kitBadge = indexContainer and indexContainer:FindFirstChild("Alert")
	if kitBadge and kitBadge:IsA("GuiObject") then
		alertTemplate = kitBadge:Clone()
	end
	local rebirthBadge: GuiObject? = nil
	local rebirthContainer = sideButton("RebirthBtn")
	if alertTemplate and rebirthContainer then
		local badge = alertTemplate:Clone()
		badge.Visible = false
		badge.Parent = rebirthContainer
		rebirthBadge = badge
	end

	-- Buttons other controllers claim with HudController.Bind: hidden until
	-- something binds them, so the HUD never shows a button that does nothing.
	for _, name in ipairs({ "IndexBtn", "GiftBtn" }) do
		local frame = side:FindFirstChild(name)
		Kit.Hide(frame)
		local container = frame and frame:FindFirstChild("Container")
		local alert = container and container:FindFirstChild("Alert")
		if alert and alert:IsA("GuiObject") then
			alert.Visible = false
		end
	end
	hudGui = gui

	-- Top buttons: Base / Eggs fast travel; no selling.
	local top = gui:WaitForChild("TopButtons")
	Kit.Hide(top:FindFirstChild("SellBtn"))
	onActivated(top:FindFirstChild("BaseBtn"), function()
		travel("Home")
	end)
	local eggsButton = top:FindFirstChild("ShopBtn")
	Kit.SetText(eggsButton and eggsButton:FindFirstChildWhichIsA("TextLabel"), "Eggs")
	onActivated(eggsButton, function()
		travel("EggBelt")
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

	-- Not used by this game. (BottomRight holds the Daily button; it's
	-- shown when something binds "DailyBtn".)
	for _, name in ipairs({ "ToolBar", "Inventory", "PLACEHOLDERS", "BottomRight" }) do
		Kit.Hide(gui:FindFirstChild(name))
	end

	local chips, warning = buildExtras(gui)

	-- Server clock at the moment the latest snapshot arrived (buff expiry
	-- times are server os.time values).
	local snapshotServerTime = os.time()
	local snapshotClock = os.clock()

	-- Cash change animation (Step 8 juice): gains count up and the label
	-- bounces; spending snaps straight to the new value.
	local shownCash: number? = nil
	local cashCounter = Instance.new("NumberValue")
	local cashTween: Tween? = nil
	local cashPunch: UIScale? = nil
	if cashText and cashText:IsA("GuiObject") and not cashText:FindFirstChildOfClass("UIScale") then
		local punch = Instance.new("UIScale")
		punch.Name = "CashPunch"
		punch.Parent = cashText
		cashPunch = punch
	end
	cashCounter.Changed:Connect(function(value)
		Kit.SetText(cashText, "$" .. Config.FormatNumber(math.floor(value + 0.5)))
	end)
	local function animateCash(cash: number)
		local previous = shownCash
		if previous == cash then
			return -- another field changed; let a running count-up finish
		end
		shownCash = cash
		if cashTween then
			cashTween:Cancel()
			cashTween = nil
		end
		if previous == nil or cash <= previous then
			cashCounter.Value = cash
			Kit.SetText(cashText, "$" .. Config.FormatNumber(cash))
			return
		end
		cashCounter.Value = math.max(cashCounter.Value, previous)
		local countUp = TweenService:Create(cashCounter,
			TweenInfo.new(Config.Feedback.CashCountUpTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = cash })
		countUp:Play()
		cashTween = countUp
		local punch = cashPunch
		if punch then
			punch.Scale = Config.Feedback.CashPunchScale
			TweenService:Create(punch, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end

	local function render(snapshot: { [string]: any })
		local cash = tonumber(snapshot.Cash) or 0
		local rebirths = tonumber(snapshot.Rebirths) or 0
		animateCash(cash)
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
