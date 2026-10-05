--!strict
--[[
	EggShopController
	StarterPlayerScripts/Client/Controllers/EggShopController

	The Egg Shop panel. Opens from the Egg Shop counter's prompt, closes when
	you walk away. Each row shows price, rebirth lock, and the odds of a
	Legendary-or-better at heat 0 vs full heat — the patience hook, up front.

	Everything shown here is read from Config for display only. The server
	re-checks every purchase (price, lock, distance, free nest, cash).
	Placeholder styling — the real UI pass is Step 8.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local EggShopController = {}

local localPlayer = Players.LocalPlayer

local gui: ScreenGui
local rows: { [string]: { button: TextButton, note: TextLabel } } = {}
local openedAt: BasePart? = nil
local busy = false

local function topOdds(eggId: string, heat: number): number
	local c = Config.GetRarityChances(eggId, heat, 0)
	return (c.Legendary or 0) + (c.Mythic or 0) + (c.Secret or 0)
end

local function formatPercent(p: number): string
	local pct = p * 100
	if pct >= 10 then
		return string.format("%.0f%%", pct)
	elseif pct >= 1 then
		return string.format("%.1f%%", pct)
	end
	return string.format("%.2f%%", pct)
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextColor3 = Color3.fromRGB(255, 236, 200)
	l.Font = Enum.Font.GothamMedium
	l.TextXAlignment = Enum.TextXAlignment.Left
	for key, value in pairs(props) do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

local function refresh()
	local snapshot = ProfileController.Get()
	local cash = snapshot and tonumber(snapshot.Cash) or 0
	local rebirths = snapshot and tonumber(snapshot.Rebirths) or 0
	for eggId, row in pairs(rows) do
		local egg = Config.Eggs[eggId]
		if rebirths < egg.RequiredRebirths then
			row.button.Text = "LOCKED"
			row.button.BackgroundColor3 = Color3.fromRGB(70, 72, 80)
			row.note.Text = string.format("Unlocks at Rebirth %d", egg.RequiredRebirths)
		else
			row.button.Text = "$" .. Config.FormatNumber(egg.Price)
			row.button.BackgroundColor3 = if cash >= egg.Price
				then Color3.fromRGB(46, 140, 80)
				else Color3.fromRGB(110, 60, 60)
			row.note.Text = string.format("Legendary+  %s  →  %s at max heat",
				formatPercent(topOdds(eggId, 0)), formatPercent(topOdds(eggId, Config.Heat.Max)))
		end
	end
end

local function buy(eggId: string)
	if busy then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("BuyEgg") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer(eggId)
	end)
	busy = false
	if ok and typeof(result) == "table" then
		NotificationController.Show(tostring(result.Message or ""), if result.Ok then "Success" else "Error")
	else
		NotificationController.Show("Couldn't reach the server.", "Error")
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "EggShop"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 5

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.52)
	panel.Size = UDim2.fromScale(0.92, 0.72)
	panel.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	panel.BackgroundTransparency = 0.05
	panel.Parent = gui
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(480, 560)
	constraint.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel

	label(panel, {
		Name = "Title", Text = "EGG SHOP", Font = Enum.Font.GothamBlack, TextSize = 22,
		Size = UDim2.new(1, -70, 0, 44), Position = UDim2.fromOffset(16, 6),
	})

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Text = "X"
	close.Font = Enum.Font.GothamBlack
	close.TextSize = 20
	close.TextColor3 = Color3.new(1, 1, 1)
	close.BackgroundColor3 = Color3.fromRGB(120, 40, 48)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -10, 0, 8)
	close.Size = UDim2.fromOffset(40, 40)
	close.Parent = panel
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = close
	close.Activated:Connect(function()
		EggShopController.Close()
	end)

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(10, 56)
	list.Size = UDim2.new(1, -20, 1, -66)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	for order, eggId in ipairs(Config.EggOrder) do
		local egg = Config.Eggs[eggId]
		local row = Instance.new("Frame")
		row.Name = eggId
		row.LayoutOrder = order
		row.Size = UDim2.new(1, -8, 0, 64)
		row.BackgroundColor3 = Color3.fromRGB(36, 38, 48)
		row.Parent = list
		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 10)
		rowCorner.Parent = row

		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.fromOffset(36, 46)
		swatch.Position = UDim2.fromOffset(10, 9)
		swatch.BackgroundColor3 = egg.Color
		swatch.Parent = row
		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(0.5, 0)
		swatchCorner.Parent = swatch

		label(row, {
			Name = "EggName", Text = egg.Name, Font = Enum.Font.GothamBold, TextSize = 17,
			Position = UDim2.fromOffset(56, 8), Size = UDim2.new(1, -170, 0, 24),
		})
		local note = label(row, {
			Name = "Note", Text = "", TextSize = 13, TextColor3 = Color3.fromRGB(200, 190, 170),
			TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(56, 32), Size = UDim2.new(1, -170, 0, 30),
		})

		local button = Instance.new("TextButton")
		button.Name = "Buy"
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -10, 0.5, 0)
		button.Size = UDim2.fromOffset(100, 44)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 16
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Parent = row
		local buttonCorner = Instance.new("UICorner")
		buttonCorner.CornerRadius = UDim.new(0, 8)
		buttonCorner.Parent = button
		button.Activated:Connect(function()
			buy(eggId)
		end)

		rows[eggId] = { button = button, note = note }
	end

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
end

function EggShopController.Open(counter: BasePart)
	openedAt = counter
	refresh()
	gui.Enabled = true
end

function EggShopController.Close()
	openedAt = nil
	gui.Enabled = false
end

function EggShopController.IsOpen(): boolean
	return gui ~= nil and gui.Enabled
end

function EggShopController.Start()
	build()

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= localPlayer or prompt.Name ~= "ShopPrompt" then
			return
		end
		local shopId = prompt:GetAttribute("ShopId")
		local counter = prompt.Parent
		if shopId == "Eggs" and counter and counter:IsA("BasePart") then
			EggShopController.Open(counter)
		elseif shopId == "Upgrades" then
			NotificationController.Show("The Upgrade Shop opens in a later update.", "Info")
		end
	end)

	ProfileController.Changed:Connect(function()
		if gui.Enabled then
			refresh()
		end
	end)

	-- Close when the player walks away from the counter.
	task.spawn(function()
		while true do
			task.wait(0.3)
			local counter = openedAt
			if counter and gui.Enabled then
				local character = localPlayer.Character
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not root or not counter.Parent
					or (root.Position - counter.Position).Magnitude > Config.Shop.InteractDistance then
					EggShopController.Close()
				end
			end
		end
	end)
end

return EggShopController
