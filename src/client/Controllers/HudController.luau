-- Owns the pack HUD ScreenGui: wires the cash display (BottomLeft)
-- and top-nav teleport buttons (TopButtons.BaseBtn / ShopBtn / SellBtn /
-- UpgradeBtn).
-- Individual popup controllers (Shop, Settings, Rebirth, Index, etc.)
-- reach their HUD buttons directly from PlayerGui and do not call
-- through here, so this controller stays intentionally narrow.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder   = Shared:WaitForChild("Util")

local DigConfig      = require(ConfigFolder:WaitForChild("DigConfig"))
local EconomyConfig  = require(ConfigFolder:WaitForChild("EconomyConfig"))
local TeleportConfig = require(ConfigFolder:WaitForChild("TeleportConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local FormatUtil     = require(UtilFolder:WaitForChild("FormatUtil"))

local HudController = {}

-- TopButtons may use UIButton Slot Frame + inner __UIButtonInner; teleport must attach to Inner,
-- never a stray nested GuiButton (FindFirstWhich descends too deep).
local function teleportTargetUnder(container: Instance, childName: string): GuiButton?
	local marker = container:WaitForChild(childName)
	if marker:IsA("GuiButton") then
		return marker
	end

	local inner = marker:FindFirstChild("__UIButtonInner")
	if inner and inner:IsA("GuiButton") then
		return inner
	end

	for _, ch in marker:GetChildren() do
		if ch:IsA("GuiButton") then
			return ch
		end
	end

	return marker:FindFirstChildWhichIsA("GuiButton", true)
end

local function countFriendsInServer(): number
	local localPlayer = Players.LocalPlayer
	local count = 0
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= localPlayer then
			local ok, isFriend = pcall(function()
				return localPlayer:IsFriendsWith(otherPlayer.UserId)
			end)
			if ok and isFriend then
				count += 1
			end
		end
	end
	return count
end

function HudController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local hud       = playerGui:WaitForChild("HUD")

	local economySyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REMOTE
	)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)
	local teleportRemote = RemoteRegistry.getRemote(
		TeleportConfig.REMOTE_FOLDER,
		TeleportConfig.TELEPORT_REQUEST_REMOTE
	)

	local bottomLeft = hud:WaitForChild("BottomLeft")
	local cashLabels: { TextLabel } = {}
	for _, child in bottomLeft:GetChildren() do
		if child:IsA("TextLabel") and child.Name == "CashText" then
			table.insert(cashLabels, child)
		end
	end

	local friendBoostLabel: TextLabel? = bottomLeft:FindFirstChild("FriendBoostText") :: TextLabel?

	local function setCash(amount: number)
		local text = FormatUtil.money(amount)
		for _, label in cashLabels do
			label.Text = text
		end
	end

	local function refreshFriendBoost()
		if not friendBoostLabel then
			return
		end
		local friendCount = countFriendsInServer()
		local boostPercent = math.round(friendCount * DigConfig.FRIEND_LUCK_PER_FRIEND * 100)
		friendBoostLabel.Text = ("Friend Boost +%d%%"):format(boostPercent)
	end

	economySyncRemote.OnClientEvent:Connect(function(snapshot)
		if type(snapshot) ~= "table" then return end
		setCash(snapshot.money or 0)
	end)

	Players.PlayerAdded:Connect(function()
		refreshFriendBoost()
	end)

	Players.PlayerRemoving:Connect(function()
		-- Yield one frame so the player is fully removed from Players before recount.
		task.defer(refreshFriendBoost)
	end)

	local topButtons = hud:WaitForChild("TopButtons")

	local baseBtn = teleportTargetUnder(topButtons, "BaseBtn")
	if baseBtn then
		baseBtn.Activated:Connect(function()
			teleportRemote:FireServer(TeleportConfig.DESTINATION_BASE)
		end)
	end

	local shopNav = teleportTargetUnder(topButtons, "ShopBtn")
	if shopNav then
		shopNav.Activated:Connect(function()
			teleportRemote:FireServer(TeleportConfig.DESTINATION_SHOP)
		end)
	end

	local sellBtn = teleportTargetUnder(topButtons, "SellBtn")
	if sellBtn then
		sellBtn.Activated:Connect(function()
			teleportRemote:FireServer(TeleportConfig.DESTINATION_SELL)
		end)
	end

	local upgradeBtn = teleportTargetUnder(topButtons, "UpgradeBtn")
	if upgradeBtn then
		upgradeBtn.Activated:Connect(function()
			teleportRemote:FireServer(TeleportConfig.DESTINATION_UPGRADE)
		end)
	end

	economySyncRequestRemote:FireServer()
	refreshFriendBoost()
end

return HudController
