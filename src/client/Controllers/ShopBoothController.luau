-- Drives the proximity-based open/close behaviour for the shop booth and
-- wires the VendorUI panel to the vendor remotes.
--
-- Open/close uses hysteresis: the panel opens once the player walks within
-- OPEN_RADIUS of the shopkeeper, stays open while the player is inside the
-- larger CLOSE_RADIUS, and closes only after the player walks past
-- CLOSE_RADIUS. This avoids flicker if the player loiters around the door
-- of the shop right at the boundary.
--
-- An explicit close (X button or distance check) suppresses auto-reopen
-- until the player walks away past CLOSE_RADIUS, so the close button always
-- feels like it took.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local WorkspaceModelFind = require(UtilFolder:WaitForChild("WorkspaceModelFind"))

local Controllers = script.Parent
local ItemShopController = require(Controllers:WaitForChild("ItemShopController"))

local ShopBoothController = {}

local SHOP_MODEL_NAME = "Shop"
-- Walk into this radius (studs from the shopkeeper) and the panel opens.
-- Slightly tight so the player has to deliberately approach the booth and
-- doesn't get the panel shoved in their face just walking past.
local OPEN_RADIUS_STUDS = 12
-- Once the panel is open it stays open while the player is inside this
-- larger radius. The gap (10 studs) is hysteresis: prevents flicker when
-- the player jiggles back and forth near the open boundary.
local CLOSE_RADIUS_STUDS = 22
-- Heartbeat sample rate. Distance checks are cheap; 6 ticks/sec is plenty
-- and keeps the response snappy without burning CPU.
local CHECK_INTERVAL_SECONDS = 1 / 6

local localPlayer = Players.LocalPlayer

local function findShopModel(): Model?
	return WorkspaceModelFind.findNamedModel(Workspace, SHOP_MODEL_NAME)
end

-- Locate the shopkeeper inside the shop. We look for the Humanoid first so
-- we don't depend on the developer giving the model a specific name (the
-- Studio model has the NPC nested under an unnamed Model).
local function findShopkeeper(shopModel: Model): Model?
	for _, descendant in shopModel:GetDescendants() do
		if descendant:IsA("Humanoid") then
			local model = descendant.Parent
			if model and model:IsA("Model") then
				return model
			end
		end
	end

	return nil
end

-- Pick the best part to measure distance against: prefer HumanoidRootPart
-- (canonical), then PrimaryPart, then Torso, then any BasePart. Returning a
-- BasePart means we always get a Position to compare against; without this
-- guard we'd silently drop into a no-trigger state if the developer changed
-- the rig.
local function findShopkeeperAnchor(npc: Model): BasePart?
	local root = npc:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	local primary = npc.PrimaryPart
	if primary and primary:IsA("BasePart") then
		return primary
	end

	local torso = npc:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		return torso
	end

	for _, descendant in npc:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end

	return nil
end

local function getCharacterRoot(): BasePart?
	local character = localPlayer.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

local function buildFailureKind(reason: string?): string
	if reason == "INSUFFICIENT_CASH" or reason == "LOCKED_REBIRTHS" then
		return "error"
	elseif reason == "ALREADY_OWNED" or reason == "UNKNOWN_SHOVEL" then
		return "error"
	end

	return "info"
end

function ShopBoothController.start()
	local purchaseRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.VENDOR_REMOTE_FOLDER,
		EconomyConfig.VENDOR_PURCHASE_REQUEST_REMOTE
	)
	local purchaseResultRemote = RemoteRegistry.getRemote(
		EconomyConfig.VENDOR_REMOTE_FOLDER,
		EconomyConfig.VENDOR_PURCHASE_RESULT_REMOTE
	)
	local vendorSyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.VENDOR_REMOTE_FOLDER,
		EconomyConfig.VENDOR_SYNC_REMOTE
	)
	local economySyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REMOTE
	)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)

	local ui = ItemShopController.new()
	if not ui then
		warn("[ShopBoothController] Shovel shop UI failed to initialize; booth proximity panel disabled.")
		return
	end

	-- Latest known economy + shovel state. Refreshed on every EconomySync
	-- and VendorSync so the UI always renders against fresh values when it
	-- opens.
	local snapshot = {
		money = 0,
		rebirths = 0,
		shovel = ShovelConfig.getDefaultId(),
	}

	local function refreshUI()
		ui:setSnapshot(snapshot)
	end

	-- A manual close (X button) sets this flag. The proximity loop won't
	-- re-open until the player walks past CLOSE_RADIUS, at which point the
	-- flag clears and the next approach opens normally again.
	local manuallyClosed = false

	ui:setBuyHandler(function(entry)
		-- Pre-flight client-side check so we can show a friendly message
		-- without a server round trip. Server still revalidates.
		local check = ShovelConfig.canPurchase(snapshot.shovel, entry.id, snapshot.rebirths, snapshot.money)
		if not check.ok then
			if check.reason == "LOCKED_REBIRTHS" then
				local missing = check.missingRebirths or 0
				ui:setStatus(("Need %d more rebirth%s to unlock the %s."):format(
					missing,
					if missing == 1 then "" else "s",
					entry.displayName
				), "error")
			elseif check.reason == "INSUFFICIENT_CASH" then
				ui:setStatus(("You can't afford the %s yet."):format(entry.displayName), "error")
			elseif check.reason == "ALREADY_OWNED" then
				ui:setStatus(("You already own the %s."):format(entry.displayName), "info")
			else
				ui:setStatus("Cannot purchase that shovel.", "error")
			end
			return
		end

		ui:setStatus(("Buying %s..."):format(entry.displayName), "info")
		purchaseRequestRemote:FireServer(entry.id)
	end)

	ui:setCloseHandler(function()
		manuallyClosed = true
		ui:close()
	end)

	economySyncRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end

		if payload.money ~= nil then
			snapshot.money = tonumber(payload.money) or snapshot.money
		end
		if payload.rebirths ~= nil then
			snapshot.rebirths = tonumber(payload.rebirths) or snapshot.rebirths
		end
		-- The post-purchase EconomySync includes the shovel; standard
		-- snapshots from rebirth/upgrade don't. Only adopt when present.
		if payload.shovel ~= nil and ShovelConfig.isKnown(payload.shovel) then
			snapshot.shovel = payload.shovel
		end

		refreshUI()
	end)

	vendorSyncRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end

		if payload.shovel ~= nil and ShovelConfig.isKnown(payload.shovel) then
			snapshot.shovel = payload.shovel
			refreshUI()
		end
	end)

	purchaseResultRemote.OnClientEvent:Connect(function(result)
		if type(result) ~= "table" then
			return
		end

		if result.shovel ~= nil and ShovelConfig.isKnown(result.shovel) then
			snapshot.shovel = result.shovel
		end

		refreshUI()

		local message = result.message
		if type(message) ~= "string" or message == "" then
			return
		end

		if result.success then
			ui:setStatus(message, "success")
		else
			ui:setStatus(message, buildFailureKind(result.reason))
		end
	end)

	economySyncRequestRemote:FireServer()

	-- Re-resolve the shop + shopkeeper anchor on demand. The Studio model
	-- exists at start time but we still re-acquire the BasePart each tick
	-- because Studio rebuilds (or rojo sync events) can swap the underlying
	-- Part instances.
	local cachedShop: Model? = nil
	local cachedShopkeeper: Model? = nil
	local cachedAnchor: BasePart? = nil

	Workspace.DescendantAdded:Connect(function(inst: Instance)
		if inst:IsA("Model") and inst.Name == SHOP_MODEL_NAME then
			cachedShop = nil
			cachedShopkeeper = nil
			cachedAnchor = nil
		end
	end)

	local function resolveAnchor(): BasePart?
		if cachedAnchor and cachedAnchor.Parent then
			return cachedAnchor
		end

		if not cachedShop or not cachedShop.Parent then
			cachedShop = findShopModel()
			cachedShopkeeper = nil
		end
		if not cachedShop then
			return nil
		end

		if not cachedShopkeeper or not cachedShopkeeper.Parent then
			cachedShopkeeper = findShopkeeper(cachedShop)
		end
		if not cachedShopkeeper then
			return nil
		end

		cachedAnchor = findShopkeeperAnchor(cachedShopkeeper)
		return cachedAnchor
	end

	local lastCheckAt = 0

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastCheckAt < CHECK_INTERVAL_SECONDS then
			return
		end
		lastCheckAt = now

		local anchor = resolveAnchor()
		if not anchor then
			return
		end

		local root = getCharacterRoot()
		if not root then
			-- Player has no character (dying / just respawning). Force-close
			-- the panel so it doesn't linger in a stale state.
			if ui:isOpen() then
				ui:close()
			end
			manuallyClosed = false
			return
		end

		local distance = (root.Position - anchor.Position).Magnitude

		if ui:isOpen() then
			-- Stay-open zone: respect the manual-close flag immediately,
			-- otherwise wait until we pass CLOSE_RADIUS to drop the panel.
			if manuallyClosed then
				if distance > CLOSE_RADIUS_STUDS then
					manuallyClosed = false
				end
				return
			end

			if distance > CLOSE_RADIUS_STUDS then
				ui:close()
			end
			return
		end

		-- Panel is closed: clear the manual-closed gate the moment the
		-- player walks far enough away that auto-open should resume.
		if manuallyClosed then
			if distance > CLOSE_RADIUS_STUDS then
				manuallyClosed = false
			end
			return
		end

		if distance <= OPEN_RADIUS_STUDS then
			refreshUI()
			ui:open()
		end
	end)
end

return ShopBoothController
