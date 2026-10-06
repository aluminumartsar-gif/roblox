local CollectionService  = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players            = game:GetService("Players")

local LOCAL_PLAYER = Players.LocalPlayer

local function wireButton(button: ImageButton | TextButton)
	local productIdValue   = button:FindFirstChild("ProductId")
	local productTypeValue = button:FindFirstChild("ProductType")
	if not productIdValue or not productTypeValue then return end

	button.Activated:Connect(function()
		if productTypeValue.Value == "DevProduct" then
			MarketplaceService:PromptProductPurchase(LOCAL_PLAYER, productIdValue.Value)
		elseif productTypeValue.Value == "Gamepass" then
			MarketplaceService:PromptGamePassPurchase(LOCAL_PLAYER, productIdValue.Value)
		end
	end)
end

for _, button in CollectionService:GetTagged("UIButton") do
	task.defer(wireButton, button)
end
CollectionService:GetInstanceAddedSignal("UIButton"):Connect(wireButton)

return {}
