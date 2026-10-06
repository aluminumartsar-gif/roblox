local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local PlotConfig = require(ConfigFolder:WaitForChild("PlotConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))
local BasePlacard = require(UtilFolder:WaitForChild("BasePlacard"))
local BrainrotPlacard = require(UtilFolder:WaitForChild("BrainrotPlacard"))
local BrainrotVisualFactory = require(UtilFolder:WaitForChild("BrainrotVisualFactory"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local UpgradeBillboard = require(UtilFolder:WaitForChild("UpgradeBillboard"))

local BaseUpgradeService = require(script.Parent:WaitForChild("BaseUpgradeService"))
local CollectService = require(script.Parent:WaitForChild("CollectService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local HotbarService = require(script.Parent:WaitForChild("HotbarService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local PlotService = {}

local plotByUserId = {}
local ownerByPlotIndex = {}
local slotPartsByUserId = {}
local upgradePartsByUserId = {}
local touchDebounceByKey = {}
local discoveredPlots = nil
local placardByPlotIndex: { [number]: any } = {}
local homeBillboardByPlotIndex: { [number]: Instance } = {}

-- Attributes used to remember the original (unlocked) state of decor parts on
-- floors that we hide while the player hasn't reached that tier. Stored on the
-- instance itself so we can fully reverse the hide pass without round-tripping
-- through service-level state.
local ORIGINAL_TRANSPARENCY_ATTRIBUTE = "_FloorOriginalTransparency"
local ORIGINAL_CANCOLLIDE_ATTRIBUTE = "_FloorOriginalCanCollide"
local ORIGINAL_LIGHT_ENABLED_ATTRIBUTE = "_FloorOriginalLightEnabled"

local placementPromptRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PLACEMENT_PROMPT_REMOTE)
local placeRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PLACE_REQUEST_REMOTE)
local pickupPromptRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PICKUP_PROMPT_REMOTE)
local pickupRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PICKUP_REQUEST_REMOTE)
local slotSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_SLOT_SYNC_REMOTE)
local cashCollectFxRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.CASH_COLLECT_FX_REMOTE)
local padUnlockRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PAD_UNLOCK_REMOTE)

local function isBaseModel(instance: Instance)
	return instance:IsA("Model")
		and (
			instance.Name == PlotConfig.PLOT_MODEL_NAME
			or instance.Name:match("^" .. PlotConfig.PLOT_NAME_PREFIX .. "%d+$") ~= nil
			or instance.Name:match("^" .. PlotConfig.LEGACY_PLOT_NAME_PREFIX .. "%d+$") ~= nil
		)
end

local function sortByName(left: Instance, right: Instance)
	if left.Name == right.Name then
		return left:GetFullName() < right:GetFullName()
	end

	return left.Name < right.Name
end

local function discoverPlots()
	if discoveredPlots then
		return discoveredPlots
	end

	local roots = {}
	local basesFolder = Workspace:FindFirstChild(PlotConfig.PLOT_FOLDER_NAME)
	local legacyPlotsFolder = Workspace:FindFirstChild(PlotConfig.LEGACY_PLOT_FOLDER_NAME)
	if basesFolder then
		table.insert(roots, basesFolder)
	end
	if legacyPlotsFolder then
		table.insert(roots, legacyPlotsFolder)
	end
	table.insert(roots, Workspace)

	local seen = {}
	local plots = {}
	for _, root in roots do
		for _, child in root:GetChildren() do
			if isBaseModel(child) and not seen[child] then
				seen[child] = true
				table.insert(plots, child)
			end
		end
	end

	table.sort(plots, sortByName)
	discoveredPlots = plots

	return discoveredPlots
end

-- Bases in the live build keep their SpawnLocation inside Floor1 (not as a
-- direct child of the Base model the way the build spec implies), so we have
-- to walk the descendants to find it. We prefer an actual SpawnLocation
-- instance over a plain BasePart that happens to be named "SpawnLocation"
-- so legacy bases still work but newer bases pick up the real spawn part.
local function getSpawnLocation(plot: Instance): SpawnLocation?
	for _, descendant in plot:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			return descendant
		end
	end

	local named = plot:FindFirstChild(PlotConfig.SPAWN_LOCATION_NAME, true)
	if named and named:IsA("SpawnLocation") then
		return named
	end

	return nil
end

local function getSpawnPart(plot: Instance)
	local spawnLocation = getSpawnLocation(plot)
	if spawnLocation then
		return spawnLocation
	end

	local named = plot:FindFirstChild(PlotConfig.SPAWN_LOCATION_NAME, true)
	if named and named:IsA("BasePart") then
		return named
	end

	return nil
end

-- Disables the SpawnLocation on a vacant plot so Roblox's default spawn
-- search never lands a freshly-joined (or recently-respawned) player at
-- somebody else's base. We re-enable a plot's SpawnLocation only for the
-- player who owns it, and route them there with Player.RespawnLocation.
local function setPlotSpawnEnabled(plot: Instance, enabled: boolean)
	local spawnLocation = getSpawnLocation(plot)
	if spawnLocation then
		spawnLocation.Enabled = enabled
	end
end

local function findBasePart(container: Instance, partName: string)
	local direct = container:FindFirstChild(partName)
	if direct and direct:IsA("BasePart") then
		return direct
	end

	local descendant = container:FindFirstChild(partName, true)
	if descendant and descendant:IsA("BasePart") then
		return descendant
	end

	return nil
end

local function findDirectBasePart(container: Instance, partName: string)
	local child = container:FindFirstChild(partName)
	if child and child:IsA("BasePart") then
		return child
	end

	return nil
end

local function isPadGroup(instance: Instance)
	return (instance:IsA("Model") or instance:IsA("Folder"))
		and (
			instance.Name == PlotConfig.PAD_GROUP_NAME
			or instance.Name:match("^" .. PlotConfig.PAD_GROUP_NAME_PREFIX .. "%d+$") ~= nil
		)
		and findDirectBasePart(instance, PlotConfig.PAD_NAME) ~= nil
		and findDirectBasePart(instance, PlotConfig.COLLECT_PAD_NAME) ~= nil
end

local function getFloorContainer(plot: Instance, tierIndex: number)
	return plot:FindFirstChild(PlotConfig.getFloorName(tierIndex))
end

-- Sorts `pads` in-place into snake-walk order using the physical positions of
-- the pads relative to the plot's entrance. The left column (EntrancePost1
-- side) is ordered nearest-to-farthest from the entrance; the right column
-- (EntrancePost2 side) continues the snake by going farthest-to-nearest.
-- Falls back to name order when entrance posts are not present (legacy bases).
local function sortFloorPadsSnake(pads: { Instance }, plot: Instance)
	if #pads <= 1 then
		return
	end

	local floor1 = getFloorContainer(plot, 1)
	if not floor1 then
		table.sort(pads, sortByName)
		return
	end

	local post1 = findDirectBasePart(floor1, PlotConfig.ENTRANCE_POST_LEFT_NAME)
	local post2 = findDirectBasePart(floor1, PlotConfig.ENTRANCE_POST_RIGHT_NAME)
	if not post1 or not post2 then
		table.sort(pads, sortByName)
		return
	end

	local midX = (post1.Position.X + post2.Position.X) / 2
	local midZ = (post1.Position.Z + post2.Position.Z) / 2

	-- side: unit XZ vector from post1 toward post2 (positive = post2/"right" side)
	local sideRaw = post2.Position - post1.Position
	local sideMag = math.sqrt(sideRaw.X ^ 2 + sideRaw.Z ^ 2)
	if sideMag < 1e-3 then
		table.sort(pads, sortByName)
		return
	end
	local sideX, sideZ = sideRaw.X / sideMag, sideRaw.Z / sideMag

	-- outward: unit XZ vector from plot pivot toward entrance midpoint
	local pivotPos = plot:GetPivot().Position
	local outRawX = midX - pivotPos.X
	local outRawZ = midZ - pivotPos.Z
	local outMag = math.sqrt(outRawX ^ 2 + outRawZ ^ 2)
	if outMag < 1e-3 then
		table.sort(pads, sortByName)
		return
	end
	local outX, outZ = outRawX / outMag, outRawZ / outMag

	local leftSide = {}
	local rightSide = {}

	for _, padGroup in pads do
		local pad = findDirectBasePart(padGroup, PlotConfig.PAD_NAME)
		local posX = if pad then pad.Position.X else midX
		local posZ = if pad then pad.Position.Z else midZ

		local offX = posX - midX
		local offZ = posZ - midZ
		-- depth: positive = farther inside the plot (away from entrance)
		local depth = -(offX * outX + offZ * outZ)
		local sideOffset = offX * sideX + offZ * sideZ

		if sideOffset < 0 then
			table.insert(leftSide, { padGroup = padGroup, depth = depth })
		else
			table.insert(rightSide, { padGroup = padGroup, depth = depth })
		end
	end

	-- Left column: ascending depth (entrance → back of plot for pads 1..N/2)
	table.sort(leftSide, function(a, b)
		return a.depth < b.depth
	end)
	-- Right column: descending depth (back → entrance = snake U-turn for pads N/2+1..N)
	table.sort(rightSide, function(a, b)
		return a.depth > b.depth
	end)

	local i = 1
	for _, data in leftSide do
		pads[i] = data.padGroup
		i += 1
	end
	for _, data in rightSide do
		pads[i] = data.padGroup
		i += 1
	end
end

-- Returns a flat array indexed by global slot index, where slots[i] is the
-- PadGroup that owns slot i (or nil if no pad exists for that index). Slot
-- indices follow the cumulative tier ranges: Tier 1 owns 1..N1, Tier 2 owns
-- N1+1..N1+N2, etc. We support a legacy flat layout (PadGroups directly under
-- the plot, no FloorN containers) for plots that haven't been migrated yet.
local function buildSlotMap(plot: Instance)
	local slots = table.create(PlotConfig.getMaxSlots(), nil)
	local hasFloorContainer = false

	for tier = 1, PlotConfig.MAX_TIER do
		local floor = getFloorContainer(plot, tier)
		if floor then
			hasFloorContainer = true
			local floorPads = {}
			for _, descendant in floor:GetDescendants() do
				if isPadGroup(descendant) then
					table.insert(floorPads, descendant)
				end
			end
			sortFloorPadsSnake(floorPads, plot)

			local firstSlot, lastSlot = PlotConfig.getSlotRange(tier)
			for offset = 0, lastSlot - firstSlot do
				local pad = floorPads[offset + 1]
				if pad then
					slots[firstSlot + offset] = pad
				end
			end
		end
	end

	if not hasFloorContainer then
		local flatPads = {}
		for _, descendant in plot:GetDescendants() do
			if isPadGroup(descendant) then
				table.insert(flatPads, descendant)
			end
		end
		sortFloorPadsSnake(flatPads, plot)

		local _, tier1Last = PlotConfig.getSlotRange(1)
		for index = 1, math.min(tier1Last, #flatPads) do
			slots[index] = flatPads[index]
		end
	end

	return slots
end

local function findUpgradePad(floor: Instance)
	return findBasePart(floor, PlotConfig.UPGRADE_PAD_NAME)
end

local function setFloorVisible(floor: Instance, visible: boolean)
	for _, descendant in floor:GetDescendants() do
		if descendant:IsA("BasePart") then
			if visible then
				local original = descendant:GetAttribute(ORIGINAL_TRANSPARENCY_ATTRIBUTE)
				if original ~= nil then
					descendant.Transparency = original
				end
				local cancollide = descendant:GetAttribute(ORIGINAL_CANCOLLIDE_ATTRIBUTE)
				if cancollide ~= nil then
					descendant.CanCollide = cancollide
				end
			else
				if descendant:GetAttribute(ORIGINAL_TRANSPARENCY_ATTRIBUTE) == nil then
					descendant:SetAttribute(ORIGINAL_TRANSPARENCY_ATTRIBUTE, descendant.Transparency)
				end
				if descendant:GetAttribute(ORIGINAL_CANCOLLIDE_ATTRIBUTE) == nil then
					descendant:SetAttribute(ORIGINAL_CANCOLLIDE_ATTRIBUTE, descendant.CanCollide)
				end
				descendant.Transparency = 1
				descendant.CanCollide = false
			end
		elseif descendant:IsA("Light") then
			if visible then
				local original = descendant:GetAttribute(ORIGINAL_LIGHT_ENABLED_ATTRIBUTE)
				if original ~= nil then
					descendant.Enabled = original
				end
			else
				if descendant:GetAttribute(ORIGINAL_LIGHT_ENABLED_ATTRIBUTE) == nil then
					descendant:SetAttribute(ORIGINAL_LIGHT_ENABLED_ATTRIBUTE, descendant.Enabled)
				end
				descendant.Enabled = false
			end
		elseif descendant:IsA("ProximityPrompt") and not visible then
			descendant.Enabled = false
		end
	end
end

-- `withCashIcon = true` packs a cash icon to the left of the text via a
-- horizontal UIListLayout, so money labels (uncollected cash, etc.) read with
-- the same currency glyph used on the brainrot placard. Plain text labels
-- (e.g. "Place Brainrot") opt out and keep the original full-width layout.
-- `maxDistance` mirrors BrainrotPlacard's MaxDistance: nil = unlimited (default
-- Roblox behaviour), a number hides the billboard beyond that many studs.
local function addBillboard(parent: BasePart, name: string, text: string, offset: Vector3, withCashIcon: boolean?, maxDistance: number?)
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = name
	billboard.Size = UDim2.fromScale(4, 1)
	billboard.StudsOffsetWorldSpace = offset
	billboard.AlwaysOnTop = true
	if maxDistance then
		billboard.MaxDistance = maxDistance
	end
	billboard.Parent = parent

	local labelParent: Instance = billboard
	if withCashIcon then
		local row = Instance.new("Frame")
		row.Name = "Row"
		row.BackgroundTransparency = 1
		row.Size = UDim2.fromScale(1, 1)
		row.Parent = billboard

		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Padding = UDim.new(0, 4)
		rowLayout.Parent = row

		local icon = Instance.new("ImageLabel")
		icon.Name = "CashIcon"
		icon.BackgroundTransparency = 1
		icon.Image = IconAssets.Cash
		icon.ScaleType = Enum.ScaleType.Fit
		-- RelativeYY makes both Size scales reference the parent's Y dimension,
		-- producing a square sized to the row's height regardless of canvas size.
		icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
		icon.Size = UDim2.fromScale(1, 1)
		icon.LayoutOrder = 1
		icon.Parent = row

		labelParent = row
	end

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = if withCashIcon then UDim2.new(0.7, 0, 1, 0) else UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.TextStrokeTransparency = 0.25
	label.LayoutOrder = 2
	label.Parent = labelParent

	return label
end

local function getPlayerFromHit(hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end

	return Players:GetPlayerFromCharacter(character)
end

local function makeTouchKey(userId: number, slotIndex: number, action: string)
	return ("%d:%d:%s"):format(userId, slotIndex, action)
end

local function makeUpgradeTouchKey(userId: number)
	return ("%d:upgrade"):format(userId)
end

local function canTouch(key: string, cooldown: number)
	local now = os.clock()
	local nextAllowed = touchDebounceByKey[key] or 0
	if now < nextAllowed then
		return false
	end

	touchDebounceByKey[key] = now + cooldown
	return true
end

local function getAssignedPlot(player: Player)
	return plotByUserId[player.UserId]
end

local function getSlotParts(player: Player, slotIndex: number)
	local slots = slotPartsByUserId[player.UserId]
	if not slots then
		return nil
	end

	return slots[slotIndex]
end

local function getMaxSlotsForTier(tier: number)
	return PlotConfig.getCumulativeSlots(tier)
end

local function getPlayerTier(player: Player)
	return PlayerDataService.getBaseTier(player)
end

-- Returns (anchorPosition, facingDirection) for the BasePlacard on a plot.
-- The anchor sits just in front of the entrance walkway and (optionally) to
-- the side of the path so the sign post never blocks the player's approach.
-- The facing direction points away from the plot center so the front of the
-- sign is visible to anyone walking up to the base. Falls back gracefully
-- when a base does not have entrance posts (older layouts) by anchoring to
-- the plot model itself with a simple +/- Z heuristic.
local function computePlacardAnchor(plot: Instance): (Vector3, Vector3)
	local floor1 = getFloorContainer(plot, 1)
	local entranceLeft = if floor1 then findDirectBasePart(floor1, PlotConfig.ENTRANCE_POST_LEFT_NAME) else nil
	local entranceRight = if floor1 then findDirectBasePart(floor1, PlotConfig.ENTRANCE_POST_RIGHT_NAME) else nil

	if entranceLeft and entranceRight then
		local mid = (entranceLeft.Position + entranceRight.Position) / 2
		-- Side direction runs along the line between the two entrance posts
		-- (so a "side offset" pushes the sign clear of the walkway).
		local sideRaw = entranceRight.Position - entranceLeft.Position
		local side = Vector3.new(sideRaw.X, 0, sideRaw.Z)
		side = if side.Magnitude < 1e-3 then Vector3.new(1, 0, 0) else side.Unit

		-- Outward direction: away from the model's pivot (interior) toward the
		-- entrance midpoint, projected to the XZ plane.
		local pivot = plot:GetPivot().Position
		local outwardRaw = mid - pivot
		local outward = Vector3.new(outwardRaw.X, 0, outwardRaw.Z)
		if outward.Magnitude < 1e-3 then
			outward = Vector3.new(0, 0, -1)
		end
		outward = outward.Unit

		local groundY = entranceLeft.Position.Y - entranceLeft.Size.Y / 2
		local anchor = Vector3.new(mid.X, groundY, mid.Z)
			+ outward * PlotConfig.BASE_PLACARD_FORWARD_OFFSET
			+ side * PlotConfig.BASE_PLACARD_SIDE_OFFSET

		return anchor, outward
	end

	-- Fallback: no entrance posts. Drop the sign in front of the plot pivot
	-- along -Z and assume the world is roughly axis-aligned.
	local pivotCFrame = plot:GetPivot()
	local outward = Vector3.new(0, 0, -1)
	local anchor = pivotCFrame.Position + Vector3.new(0, 0, -18) + Vector3.new(0, -1, 0)

	return anchor, outward
end

local function ensurePlacardForPlot(plotIndex: number, plot: Instance)
	if placardByPlotIndex[plotIndex] then
		return placardByPlotIndex[plotIndex]
	end

	local existing = plot:FindFirstChild(PlotConfig.BASE_PLACARD_NAME)
	if existing then
		existing:Destroy()
	end

	local anchor, facing = computePlacardAnchor(plot)
	local placard = BasePlacard.create({
		parent = plot,
		name = PlotConfig.BASE_PLACARD_NAME,
		position = anchor,
		facingDirection = facing,
		maxDistance = PlotConfig.BASE_PLACARD_MAX_DISTANCE,
	})

	placardByPlotIndex[plotIndex] = placard
	return placard
end

-- Height in studs above the plot pivot at which the home beacon part floats.
-- At 60 studs the beacon clears the tallest floor (~45 studs) with 15 studs
-- of breathing room so the icon reads as floating above the building.
local HOME_BEACON_HEIGHT = 60

local function createHomeBillboard(plotIndex: number, plot: Instance, player: Player)
	local existing = homeBillboardByPlotIndex[plotIndex]
	if existing and existing.Parent then
		existing:Destroy()
	end

	local pivot = plot:GetPivot().Position

	local beacon = Instance.new("Part")
	beacon.Name = "HomeBeacon"
	beacon.Anchored = true
	beacon.CanCollide = false
	beacon.CanQuery = false
	beacon.CanTouch = false
	beacon.CastShadow = false
	beacon.Transparency = 1
	beacon.Size = Vector3.new(0.1, 0.1, 0.1)
	beacon.Position = pivot + Vector3.new(0, HOME_BEACON_HEIGHT, 0)
	beacon.Parent = plot

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HomeBillboard"
	billboard.Size = UDim2.fromOffset(220, 280)
	billboard.MaxDistance = 1200
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.ClipsDescendants = false
	billboard.Parent = beacon

	local icon = Instance.new("ImageLabel")
	icon.Name = "HomeIcon"
	icon.BackgroundTransparency = 1
	icon.Image = IconAssets.Home
	icon.ScaleType = Enum.ScaleType.Fit
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.new(0.5, 0, 0, 0)
	icon.Size = UDim2.new(0, 200, 0, 200)
	icon.Parent = billboard

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "OwnerName"
	nameLabel.BackgroundTransparency = 1
	nameLabel.AnchorPoint = Vector2.new(0.5, 0)
	nameLabel.Position = UDim2.new(0.5, 0, 0, 208)
	nameLabel.Size = UDim2.new(0, 220, 0, 65)
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.Text = player.DisplayName .. "'s Base"
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextScaled = true
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.TextStrokeTransparency = 0.2
	nameLabel.Parent = billboard

	homeBillboardByPlotIndex[plotIndex] = beacon
end

local function destroyHomeBillboard(plotIndex: number)
	local beacon = homeBillboardByPlotIndex[plotIndex]
	if beacon and beacon.Parent then
		beacon:Destroy()
	end
	homeBillboardByPlotIndex[plotIndex] = nil
end

-- Only count placements on currently-unlocked floors. This matches the
-- collect-label loop above (and what the player can actually collect from)
-- so the placard never reports phantom income from data left behind on
-- locked tiers.
local function getTotalEarningsRate(player: Player): number
	local total = 0
	local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
	for slotIndex = 1, maxSlots do
		local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
		if placement and type(placement.value) == "number" and placement.value > 0 then
			total += EconomyService.getCashReward(player, placement)
		end
	end

	return total
end

local function refreshPlacardForPlayer(player: Player)
	local plotData = plotByUserId[player.UserId]
	if not plotData then
		return
	end

	local placard = placardByPlotIndex[plotData.index]
	if not placard then
		return
	end

	placard.setEarningsRate(getTotalEarningsRate(player))
end

local function buildDisplayName(brainrotId: string, variantId: string?)
	local resolvedVariantId = if VariantConfig.isKnown(variantId) then variantId else VariantConfig.NORMAL_ID
	if resolvedVariantId == VariantConfig.NORMAL_ID then
		return brainrotId
	end

	return ("%s %s"):format(VariantConfig.getDisplayName(resolvedVariantId), brainrotId)
end

-- Walks up from a slot's display point to the owning Base model. Used to
-- resolve plot-level info (entrance posts) without threading the plot through
-- every call site that already has the display point.
local function findPlotAncestor(instance: Instance): Instance?
	local current = instance.Parent
	while current and current ~= Workspace do
		if isBaseModel(current) then
			return current
		end
		current = current.Parent
	end

	return nil
end

-- Returns a unit XZ direction the brainrot should face from `displayPoint`,
-- so that pads on either side of the entrance walkway look inward toward each
-- other. Returns nil if the base is missing entrance posts (legacy layouts);
-- callers should fall back to the display point's own orientation in that case.
local function computeBrainrotFacingDirection(displayPoint: BasePart): Vector3?
	local plot = findPlotAncestor(displayPoint)
	if not plot then
		return nil
	end

	local floor1 = getFloorContainer(plot, 1)
	if not floor1 then
		return nil
	end

	local entranceLeft = findDirectBasePart(floor1, PlotConfig.ENTRANCE_POST_LEFT_NAME)
	local entranceRight = findDirectBasePart(floor1, PlotConfig.ENTRANCE_POST_RIGHT_NAME)
	if not entranceLeft or not entranceRight then
		return nil
	end

	local sideRaw = entranceRight.Position - entranceLeft.Position
	local side = Vector3.new(sideRaw.X, 0, sideRaw.Z)
	if side.Magnitude < 1e-3 then
		return nil
	end
	side = side.Unit

	-- Project the pad's offset from the entrance midpoint onto the side axis.
	-- A positive sideOffset means the pad sits on the EntrancePost2 (right)
	-- side of the walkway, so it should look back toward EntrancePost1.
	local entranceMid = (entranceLeft.Position + entranceRight.Position) / 2
	local offset = displayPoint.Position - entranceMid
	local sideOffset = offset.X * side.X + offset.Z * side.Z
	if math.abs(sideOffset) < 1e-3 then
		return nil
	end

	return if sideOffset > 0 then -side else side
end

local function createPlacedVisual(displayPoint: BasePart, placement, earningsRate: number)
	local existing = displayPoint:FindFirstChild(PlotConfig.PLACED_VISUAL_NAME)
	if existing then
		existing:Destroy()
	end

	local variantId = placement.variantId or VariantConfig.NORMAL_ID
	local revealData = BrainrotConfig.getRevealData(placement.id, variantId)
	local variantEntry = VariantConfig.getById(variantId)

	local heightOffset = if displayPoint.Name == PlotConfig.PAD_NAME
		then Vector3.new(0, displayPoint.Size.Y / 2 + 1.2, 0)
		else Vector3.zero
	local facing = computeBrainrotFacingDirection(displayPoint)
	local visualCFrame = if facing
		then CFrame.lookAt(displayPoint.Position + heightOffset, displayPoint.Position + heightOffset + facing)
		else displayPoint.CFrame + heightOffset
	local visual, labelPart = BrainrotVisualFactory.create(placement.id, {
		name = PlotConfig.PLACED_VISUAL_NAME,
		parent = displayPoint,
		cframe = visualCFrame,
		targetHeight = BrainrotVisualFactory.WORLD_TARGET_HEIGHT,
		fallbackColor = revealData.color,
		fallbackSize = Vector3.new(4, 4, 4),
		variantId = variantId,
	})

	BrainrotPlacard.create({
		parent = labelPart,
		name = PlotConfig.PLACARD_NAME,
		rngText = revealData.rngText,
		rngDenominator = revealData.rngDenominator,
		rarity = revealData.rarity,
		rarityColor = revealData.color,
		-- Variant now occupies its own placard row (rendered by BrainrotPlacard
		-- from `variantId`), so the name row stays just the brainrot id rather
		-- than the "Gold ChimpanziniBananini" run-on we used to render.
		displayName = placement.id,
		nameColor = variantEntry.nameColor,
		variantId = variantId,
		earningsRate = earningsRate,
		maxDistance = PlotConfig.PLACARD_MAX_DISTANCE,
		-- Use the visual model's bounding box so the placard always clears
		-- the brainrot's actual top regardless of which part inside the
		-- model is the rootPart (some brainrots root at the center, others
		-- at the feet, so a fixed studsOffset buried tall models).
		aboveModel = visual,
		headroom = 1,
	})

	return visual
end

local function getEarningsRate(player: Player, placement)
	local data = PlayerDataService.getData(player)
	local multiplier = EconomyConfig.getCashMultiplier(data.rebirths)
	return EconomyConfig.computeEarningsRate(placement.value, multiplier)
end

local function getUncollectedCash(player: Player, placement)
	local lastCollectedAt = tonumber(placement.lastCollectedAt) or os.time()
	local storedCash = tonumber(placement.uncollectedCash) or 0
	local elapsed = math.max(0, os.time() - lastCollectedAt)

	return math.floor(storedCash + elapsed * getEarningsRate(player, placement))
end

local function applyOfflineEarnings(player: Player)
	local now = os.time()
	local maxSlots = PlotConfig.getMaxSlots()

	for slotIndex = 1, maxSlots do
		local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
		if placement then
			local lastCollectedAt = tonumber(placement.lastCollectedAt) or now
			local storedCash = tonumber(placement.uncollectedCash) or 0
			local elapsed = math.min(
				math.max(0, now - lastCollectedAt),
				EconomyConfig.PLOT_OFFLINE_EARNINGS_CAP_SECONDS
			)
			local offlineCash = elapsed * getEarningsRate(player, placement) * EconomyConfig.PLOT_OFFLINE_INCOME_MULTIPLIER

			placement.uncollectedCash = math.floor(storedCash + offlineCash)
			placement.lastCollectedAt = now
			PlayerDataService.setPlacedBrainrot(player, slotIndex, placement)
		end
	end
end

local function updateCollectLabel(player: Player, slotIndex: number)
	local parts = getSlotParts(player, slotIndex)
	if not parts or not parts.collectLabel then
		return
	end

	local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
	if not placement then
		parts.collectLabel.Text = "$0"
		return
	end

	parts.collectLabel.Text = FormatUtil.money(getUncollectedCash(player, placement))
end

local function updatePlaceLabel(player: Player, slotIndex: number)
	local parts = getSlotParts(player, slotIndex)
	if not parts then
		return
	end

	local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
	local isUnlocked = PlayerDataService.isPadUnlocked(player, slotIndex)

	if parts.placeLabel then
		if not isUnlocked then
			local cost = PlotConfig.getPadUnlockCost(slotIndex)
			parts.placeLabel.Text = "Unlock - " .. FormatUtil.money(cost)
			parts.placeLabel.Visible = true
		else
			parts.placeLabel.Text = "Place Brainrot"
			parts.placeLabel.Visible = placement == nil
		end
	end

	if parts.placePrompt then
		if not isUnlocked then
			local cost = PlotConfig.getPadUnlockCost(slotIndex)
			parts.placePrompt.ActionText = "Unlock Pad (" .. FormatUtil.money(cost) .. ")"
		elseif placement then
			parts.placePrompt.ActionText = PlotConfig.PICKUP_PROMPT_ACTION_TEXT
		else
			parts.placePrompt.ActionText = PlotConfig.PLACE_PROMPT_ACTION_TEXT
		end
	end
end

local function syncSlots(player: Player)
	local data = PlayerDataService.getPublicData(player)
	slotSyncRemote:FireClient(player, {
		placedBrainrots = data.placedBrainrots,
		baseTier = data.baseTier,
		unlockedPads = data.unlockedPads,
	})
end

local function snapshotUncollectedCash(player: Player)
	local now = os.time()
	local maxSlots = PlotConfig.getMaxSlots()

	for slotIndex = 1, maxSlots do
		local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
		if placement then
			placement.uncollectedCash = getUncollectedCash(player, placement)
			placement.lastCollectedAt = now
			PlayerDataService.setPlacedBrainrot(player, slotIndex, placement)
		end
	end
end

local function renderSlot(player: Player, slotIndex: number)
	local parts = getSlotParts(player, slotIndex)
	if not parts then
		return
	end

	local isUnlocked = PlayerDataService.isPadUnlocked(player, slotIndex)

	if parts.placeButton then
		parts.placeButton.Color = if isUnlocked
			then Color3.fromRGB(100, 100, 100)
			else Color3.fromRGB(60, 60, 70)
	end

	if parts.collectButton then
		parts.collectButton.Transparency = if isUnlocked then 0 else 1
		parts.collectButton.CanCollide = isUnlocked
		local collectBillboard = parts.collectButton:FindFirstChild("CollectButtonLabel")
		if collectBillboard then
			collectBillboard.Enabled = isUnlocked
		end
	end

	local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
	local existing = parts.displayPoint:FindFirstChild(PlotConfig.PLACED_VISUAL_NAME)
	if existing then
		existing:Destroy()
	end

	if placement then
		createPlacedVisual(parts.displayPoint, placement, getEarningsRate(player, placement))
	end

	updateCollectLabel(player, slotIndex)
	updatePlaceLabel(player, slotIndex)
end

local function renderUnlockedSlots(player: Player)
	local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
	for slotIndex = 1, maxSlots do
		renderSlot(player, slotIndex)
	end
end

local function teleportCharacterToPlot(player: Player, character: Model)
	local plotData = getAssignedPlot(player)
	if not plotData then
		return
	end

	local spawnPart = getSpawnPart(plotData.plot)
	if not spawnPart then
		return
	end

	character:PivotTo(spawnPart.CFrame + Vector3.new(0, 4, 0))
end

local function onPlacePromptTriggered(owner: Player, slotIndex: number, player: Player)
	if player ~= owner then
		return
	end

	local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
	if slotIndex > maxSlots then
		return
	end

	local key = makeTouchKey(player.UserId, slotIndex, "place")
	if not canTouch(key, PlotConfig.PLACE_DEBOUNCE_SECONDS) then
		return
	end

	if not PlayerDataService.isPadUnlocked(player, slotIndex) then
		local cost = PlotConfig.getPadUnlockCost(slotIndex)
		local data = PlayerDataService.getData(player)
		if data.money < cost then
			padUnlockRemote:FireClient(player, {
				success = false,
				slotIndex = slotIndex,
				cost = cost,
				message = ("Need %s to unlock this pad."):format(FormatUtil.money(cost)),
			})
			return
		end

		if cost > 0 then
			PlayerDataService.addMoney(player, -cost, "PadUnlock")
		end
		PlayerDataService.unlockPad(player, slotIndex)
		task.spawn(PlayerDataService.savePlayer, player)

		padUnlockRemote:FireClient(player, {
			success = true,
			slotIndex = slotIndex,
			cost = cost,
		})

		CollectService.syncPlayer(player)
		updatePlaceLabel(player, slotIndex)
		syncSlots(player)
		return
	end

	local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
	if placement then
		-- Occupied pad: prompt the player to pick up the brainrot (goes to hotbar).
		pickupPromptRemote:FireClient(player, {
			slotIndex = slotIndex,
			brainrotId = placement.id,
			variantId = placement.variantId or VariantConfig.NORMAL_ID,
			displayName = buildDisplayName(placement.id, placement.variantId),
			uncollectedCash = getUncollectedCash(player, placement),
		})
		return
	end

	-- Empty pad: tell the client which pad was triggered so HotbarController
	-- can place the selected hotbar slot without showing a selection modal.
	placementPromptRemote:FireClient(player, {
		slotIndex = slotIndex,
	})
end

local function bindPlaceButton(owner: Player, slotIndex: number, placeButton: BasePart)
	local placeLabel = addBillboard(placeButton, "PlaceButtonLabel", "Place Brainrot", Vector3.new(0, 2, 0))

	local existingPrompt = placeButton:FindFirstChild(PlotConfig.PLACE_PROMPT_NAME)
	if existingPrompt then
		existingPrompt:Destroy()
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PlotConfig.PLACE_PROMPT_NAME
	prompt.ActionText = PlotConfig.PLACE_PROMPT_ACTION_TEXT
	prompt.ObjectText = ""
	prompt.HoldDuration = PlotConfig.PLACE_PROMPT_HOLD_DURATION
	prompt.MaxActivationDistance = PlotConfig.PLACE_PROMPT_MAX_DISTANCE
	prompt.KeyboardKeyCode = PlotConfig.PROMPT_KEY_CODE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
	prompt.Parent = placeButton

	prompt.Triggered:Connect(function(player)
		onPlacePromptTriggered(owner, slotIndex, player)
	end)

	return placeLabel, prompt
end

-- Fires the cash-collect VFX on the collecting client. Position comes from the
-- collect pad part (or whichever world-space anchor the caller passes), so the
-- explosion bursts where the player physically picked up the cash.
local function fireCashCollectFx(player: Player, amount: number, position: Vector3?)
	if amount <= 0 then
		return
	end

	cashCollectFxRemote:FireClient(player, {
		amount = amount,
		position = position,
	})
end

local function collectSlot(player: Player, slotIndex: number)
	local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
	if not placement then
		updateCollectLabel(player, slotIndex)
		return
	end

	local amount = getUncollectedCash(player, placement)
	if amount <= 0 then
		updateCollectLabel(player, slotIndex)
		return
	end

	placement.uncollectedCash = 0
	placement.lastCollectedAt = os.time()
	PlayerDataService.setPlacedBrainrot(player, slotIndex, placement)
	PlayerDataService.addMoney(player, amount, "PlotCollect")
	CollectService.syncEconomy(player)
	updateCollectLabel(player, slotIndex)

	local parts = getSlotParts(player, slotIndex)
	local fxPosition = if parts and parts.collectButton then parts.collectButton.Position else nil
	fireCashCollectFx(player, amount, fxPosition)
end

local function createInventoryItemFromPlacement(placement)
	return {
		uid = placement.uid,
		id = placement.id,
		variantId = placement.variantId or VariantConfig.NORMAL_ID,
		level = placement.level,
		rarity = placement.rarity,
		rarityRank = placement.rarityRank,
		value = placement.value,
		collectedAt = os.time(),
	}
end

local function pickupSlot(player: Player, slotIndex: number)
	local placement = PlayerDataService.getPlacedBrainrot(player, slotIndex)
	if not placement then
		renderSlot(player, slotIndex)
		return
	end

	-- Collect any pending cash before removing the brainrot.
	local amount = getUncollectedCash(player, placement)
	if amount > 0 then
		PlayerDataService.addMoney(player, amount, "PlotCollect")
	end

	local parts = getSlotParts(player, slotIndex)
	local fxPosition = if parts and parts.collectButton then parts.collectButton.Position else nil

	-- Try to add the brainrot back to the player's hotbar.
	-- If the hotbar is full, HotbarService notifies the player and the
	-- pickup is rejected so the brainrot stays on the pad.
	local item = createInventoryItemFromPlacement(placement)
	local added = HotbarService.addItem(player, item)
	if not added then
		-- Hotbar full — leave the pad occupied, still collect any cash.
		if amount > 0 then
			CollectService.syncEconomy(player)
			fireCashCollectFx(player, amount, fxPosition)
		end
		return
	end

	PlayerDataService.clearPlacedBrainrot(player, slotIndex)
	renderSlot(player, slotIndex)
	CollectService.syncPlayer(player)
	syncSlots(player)
	refreshPlacardForPlayer(player)

	fireCashCollectFx(player, amount, fxPosition)
end

local function bindCollectButton(owner: Player, slotIndex: number, collectButton: BasePart)
	collectButton.Color = Color3.fromRGB(80, 255, 120)
	local collectLabel = addBillboard(collectButton, "CollectButtonLabel", "$0", Vector3.new(0, 2, 0), true, 50)

	collectButton.Touched:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		if player ~= owner then
			return
		end

		local key = makeTouchKey(player.UserId, slotIndex, "collect")
		if not canTouch(key, PlotConfig.COLLECT_DEBOUNCE_SECONDS) then
			return
		end

		collectSlot(player, slotIndex)
	end)

	return collectLabel
end

-- Updates the rich UpgradeBillboard above an upgrade pad based on the
-- player's current tier. Each pad lives on a specific floor (`parts.floorIndex`),
-- so the same pad shows different states depending on whether the player has
-- already passed that tier (unlocked), is sitting on it (next upgrade), or
-- hasn't reached it yet (locked higher floors).
local function refreshUpgradePadLabel(parts, currentTier: number)
	if not parts or not parts.billboard then
		return
	end

	if parts.floorIndex < currentTier then
		parts.billboard.setUnlocked(parts.floorTierName)
	elseif parts.floorIndex == currentTier then
		local nextIndex, nextTier = PlotConfig.getNextTier(currentTier)
		if nextIndex and nextTier then
			parts.billboard.setNext(nextTier.displayName, nextTier.cost, nextTier.rebirths, nextTier.accentColor)
		else
			parts.billboard.setMax(parts.floorTierName)
		end
	else
		parts.billboard.setLocked(parts.floorTierName)
	end
end

local function bindUpgradePad(owner: Player, floorIndex: number, upgradePad: BasePart)
	local existingPrompt = upgradePad:FindFirstChild(PlotConfig.UPGRADE_PROMPT_NAME)
	if existingPrompt then
		existingPrompt:Destroy()
	end

	local floorTier = PlotConfig.getTier(floorIndex)
	local floorTierName = if floorTier then floorTier.displayName else PlotConfig.getFloorName(floorIndex)
	-- Tint the pad with the NEXT tier's accent color so players see what they
	-- are unlocking; if there is no next tier, fall back to the current one.
	local _, nextTier = PlotConfig.getNextTier(floorIndex)
	local accent = if nextTier and nextTier.accentColor
		then nextTier.accentColor
		elseif floorTier and floorTier.accentColor then floorTier.accentColor
		else Color3.fromRGB(255, 200, 60)
	upgradePad.Color = accent

	local billboard = UpgradeBillboard.create({
		parent = upgradePad,
		name = "UpgradePadBillboard",
		studsOffset = Vector3.new(0, 3.4, 0),
		maxDistance = 80,
	})

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PlotConfig.UPGRADE_PROMPT_NAME
	prompt.ActionText = PlotConfig.UPGRADE_PROMPT_ACTION_TEXT
	prompt.ObjectText = "Brainrot Tower"
	prompt.HoldDuration = PlotConfig.UPGRADE_PROMPT_HOLD_DURATION
	prompt.MaxActivationDistance = PlotConfig.UPGRADE_PROMPT_MAX_DISTANCE
	prompt.KeyboardKeyCode = PlotConfig.PROMPT_KEY_CODE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
	prompt.Enabled = false
	prompt.Parent = upgradePad

	prompt.Triggered:Connect(function(player)
		if player ~= owner then
			return
		end

		local key = makeUpgradeTouchKey(player.UserId)
		if not canTouch(key, PlotConfig.UPGRADE_DEBOUNCE_SECONDS) then
			return
		end

		BaseUpgradeService.tryUpgrade(player)
	end)

	return {
		floorIndex = floorIndex,
		floorTierName = floorTierName,
		pad = upgradePad,
		prompt = prompt,
		billboard = billboard,
	}
end

-- Applies the default "vacant" look to a plot with no owner: only the
-- starting-tier floor is visible, every higher floor is hidden so an empty
-- base reads as a small lobby instead of a finished skyscraper. Used at
-- startup for all plots and again whenever an owner leaves.
local function applyUnassignedTierVisuals(plot: Instance)
	plot:SetAttribute(PlotConfig.PLOT_TIER_ATTRIBUTE, PlotConfig.STARTING_TIER)

	for tier = 1, PlotConfig.MAX_TIER do
		local floor = getFloorContainer(plot, tier)
		if floor then
			setFloorVisible(floor, tier <= PlotConfig.STARTING_TIER)
		end
	end
end

local function applyTierVisuals(player: Player)
	local plotData = getAssignedPlot(player)
	if not plotData then
		return
	end

	local plot = plotData.plot
	local currentTier = getPlayerTier(player)
	plot:SetAttribute(PlotConfig.PLOT_TIER_ATTRIBUTE, currentTier)

	for tier = 1, PlotConfig.MAX_TIER do
		local floor = getFloorContainer(plot, tier)
		if floor then
			setFloorVisible(floor, tier <= currentTier)
		end
	end

	local upgradeParts = upgradePartsByUserId[player.UserId] or {}
	for floorIndex, parts in upgradeParts do
		local floor = getFloorContainer(plot, floorIndex)
		local floorVisible = floor ~= nil and floorIndex <= currentTier
		local isActiveUpgradeFloor = floorIndex == currentTier and currentTier < PlotConfig.MAX_TIER
		if parts.prompt then
			parts.prompt.Enabled = isActiveUpgradeFloor
		end
		if parts.pad then
			parts.pad.Transparency = if floorVisible then (parts.pad:GetAttribute(ORIGINAL_TRANSPARENCY_ATTRIBUTE) or 0) else 1
		end
		-- Billboards ignore part transparency, so we have to gate them ourselves
		-- or a locked floor's "LOCKED ROOFTOP" sign would float over a hidden
		-- pad and give away the upgrade ladder before it should be revealed.
		if parts.billboard and parts.billboard.instance then
			parts.billboard.instance.Enabled = floorVisible
		end
		refreshUpgradePadLabel(parts, currentTier)
	end
end

-- Builds slot bindings for the slot range [fromSlot, toSlot]. Idempotent for
-- newly-revealed slots (skips ones that already have parts cached) so an
-- upgrade only touches the freshly-unlocked floor without churning existing
-- proximity prompts and Touched connections.
local function bindSlotsRange(player: Player, fromSlot: number, toSlot: number)
	local plotData = getAssignedPlot(player)
	if not plotData then
		return
	end

	local slotParts = slotPartsByUserId[player.UserId] or {}
	local slotMap = buildSlotMap(plotData.plot)

	for slotIndex = fromSlot, toSlot do
		if not slotParts[slotIndex] then
			local padGroup = slotMap[slotIndex]
			local placeButton = if padGroup then findBasePart(padGroup, PlotConfig.PAD_NAME) else nil
			local collectButton = if padGroup then findBasePart(padGroup, PlotConfig.COLLECT_PAD_NAME) else nil
			local displayPoint = if padGroup then findBasePart(padGroup, PlotConfig.DISPLAY_POINT_NAME) or placeButton else nil

			if placeButton and collectButton and displayPoint then
				local placeLabel, placePrompt = bindPlaceButton(player, slotIndex, placeButton)
				local collectLabel = bindCollectButton(player, slotIndex, collectButton)

				slotParts[slotIndex] = {
					padGroup = padGroup,
					placeButton = placeButton,
					placeLabel = placeLabel,
					placePrompt = placePrompt,
					collectButton = collectButton,
					collectLabel = collectLabel,
					displayPoint = displayPoint,
				}
			elseif padGroup then
				warn(("[Plot] Missing Pad/Collect parts for %s slot %d"):format(plotData.plot.Name, slotIndex))
			end
		end
	end

	slotPartsByUserId[player.UserId] = slotParts
end

local function bindUpgradePads(player: Player)
	local plotData = getAssignedPlot(player)
	if not plotData then
		return
	end

	local upgradeParts = {}
	for tier = 1, PlotConfig.MAX_TIER do
		local floor = getFloorContainer(plotData.plot, tier)
		if floor then
			local upgradePad = findUpgradePad(floor)
			if upgradePad then
				upgradeParts[tier] = bindUpgradePad(player, tier, upgradePad)
			end
		end
	end

	upgradePartsByUserId[player.UserId] = upgradeParts
end

local function bindPlayerPlot(player: Player)
	local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
	bindSlotsRange(player, 1, maxSlots)
	bindUpgradePads(player)
	applyTierVisuals(player)
	renderUnlockedSlots(player)
	syncSlots(player)
end

local function handleUpgrade(player: Player, newTier: number)
	local plotData = getAssignedPlot(player)
	if not plotData then
		return
	end

	-- Auto-unlock the first pad on the newly revealed floor so players can
	-- immediately place a brainrot after paying for the floor upgrade.
	local firstSlotOnNewFloor = PlotConfig.getSlotRange(newTier)
	PlayerDataService.unlockPad(player, firstSlotOnNewFloor)

	local previousMax = getMaxSlotsForTier(newTier - 1)
	local newMax = getMaxSlotsForTier(newTier)
	if newMax > previousMax then
		bindSlotsRange(player, previousMax + 1, newMax)
	end
	applyTierVisuals(player)
	for slotIndex = previousMax + 1, newMax do
		renderSlot(player, slotIndex)
	end
	syncSlots(player)
	refreshPlacardForPlayer(player)
end

local function assignPlot(player: Player)
	PlayerDataService.waitForData(player)
	applyOfflineEarnings(player)

	local plots = discoverPlots()
	for plotIndex = 1, PlotConfig.PLOT_COUNT do
		if not ownerByPlotIndex[plotIndex] then
			local plot = plots[plotIndex]
			if plot then
				ownerByPlotIndex[plotIndex] = player.UserId
				plotByUserId[player.UserId] = {
					index = plotIndex,
					plot = plot,
				}

				plot:SetAttribute(PlotConfig.PLOT_OWNER_ATTRIBUTE, player.UserId)

				bindPlayerPlot(player)
				local placard = ensurePlacardForPlot(plotIndex, plot)
				placard.setOwner(player, getTotalEarningsRate(player))
				createHomeBillboard(plotIndex, plot, player)

				-- Route this player (and only this player) to their plot's
				-- SpawnLocation. We enable the SpawnLocation here so the
				-- RespawnLocation property can resolve to it; vacant plots
				-- keep their SpawnLocations disabled (see PlotService.start
				-- and releasePlot) so default spawn search can never pick
				-- somebody else's base.
				setPlotSpawnEnabled(plot, true)
				local spawnLocation = getSpawnLocation(plot)
				if spawnLocation then
					player.RespawnLocation = spawnLocation
				end

				if player.Character then
					teleportCharacterToPlot(player, player.Character)
				elseif player.Parent then
					-- CharacterAutoLoads is disabled in PlotService.start, so
					-- we own the first spawn here. Wrap in pcall because the
					-- player can leave between waitForData and now.
					pcall(function()
						player:LoadCharacter()
					end)
				end

				return
			end
		end
	end

	warn(("[Plot] No available plot for %s"):format(player.Name))
end

local function releasePlot(player: Player)
	snapshotUncollectedCash(player)
	PlayerDataService.savePlayer(player)

	local plotData = plotByUserId[player.UserId]
	if plotData then
		ownerByPlotIndex[plotData.index] = nil
		if plotData.plot then
			plotData.plot:SetAttribute(PlotConfig.PLOT_OWNER_ATTRIBUTE, nil)
			setPlotSpawnEnabled(plotData.plot, false)
			applyUnassignedTierVisuals(plotData.plot)
		end
		local placard = placardByPlotIndex[plotData.index]
		if placard then
			placard.setEmpty()
		end
		destroyHomeBillboard(plotData.index)
	end

	plotByUserId[player.UserId] = nil
	slotPartsByUserId[player.UserId] = nil
	upgradePartsByUserId[player.UserId] = nil
end

local function onPlaceRequest(player: Player, payload)
	if type(payload) ~= "table" then
		return
	end

	local slotIndex = tonumber(payload.slotIndex)
	local hotbarSlot = tonumber(payload.hotbarSlot)
	local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
	if not slotIndex or slotIndex < 1 or slotIndex > maxSlots then
		return
	end
	if not hotbarSlot or hotbarSlot < 1 then
		return
	end

	if not getAssignedPlot(player) or PlayerDataService.getPlacedBrainrot(player, slotIndex) then
		return
	end

	if not PlayerDataService.isPadUnlocked(player, slotIndex) then
		return
	end

	-- Pull the item from the player's hotbar (server-authoritative).
	local item = HotbarService.removeSlot(player, hotbarSlot)
	if not item then
		-- Hotbar slot was empty; sync so the client corrects its view.
		HotbarService.syncPlayer(player)
		return
	end

	local now = os.time()
	local placement = {
		uid = item.uid,
		id = item.id,
		variantId = item.variantId or VariantConfig.NORMAL_ID,
		level = item.level,
		rarity = item.rarity,
		rarityRank = item.rarityRank,
		value = item.value,
		placedAt = now,
		lastCollectedAt = now,
		uncollectedCash = 0,
	}

	PlayerDataService.setPlacedBrainrot(player, slotIndex, placement)
	renderSlot(player, slotIndex)
	CollectService.syncPlayer(player)
	syncSlots(player)
	refreshPlacardForPlayer(player)
end

local function onPickupRequest(player: Player, payload)
	if type(payload) ~= "table" then
		return
	end

	local slotIndex = tonumber(payload.slotIndex)
	local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
	if not slotIndex or slotIndex < 1 or slotIndex > maxSlots then
		return
	end

	if not getAssignedPlot(player) then
		return
	end

	pickupSlot(player, slotIndex)
end

-- Rebases plot visuals and slot sync after profile data was wiped in-session
-- (e.g. admin `:resetdata` / `:resetall`).
function PlotService.refreshAfterDataReset(player: Player)
	if not player.Parent then
		return
	end
	if not getAssignedPlot(player) then
		return
	end

	bindPlayerPlot(player)
	refreshPlacardForPlayer(player)
end

-- Public hook for navigation features (e.g. the top-bar Base button). Pivots
-- the player's character onto their plot's spawn part using the same offset
-- as the on-spawn teleport. Returns false (no-op) when the player has no
-- character, no assigned plot, or the plot has no resolvable spawn part —
-- the caller can decide whether to surface a UI hint.
function PlotService.teleportPlayerHome(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	local plotData = getAssignedPlot(player)
	if not plotData or not plotData.plot then
		return false
	end

	local spawnPart = getSpawnPart(plotData.plot)
	if not spawnPart then
		return false
	end

	character:PivotTo(spawnPart.CFrame + Vector3.new(0, 4, 0))
	return true
end

function PlotService.start()
	-- We control every spawn manually so a player can never appear at a base
	-- that isn't theirs (Roblox's default spawn-search picks any enabled
	-- SpawnLocation, which would otherwise drop the first joiner at a random
	-- plot before assignPlot finishes). assignPlot calls LoadCharacter once
	-- it has set the player's RespawnLocation.
	Players.CharacterAutoLoads = false

	local plots = discoverPlots()
	if #plots == 0 then
		warn(("[Plot] No %s models found. Put Base models in Workspace or Workspace.%s."):format(
			PlotConfig.PLOT_MODEL_NAME,
			PlotConfig.PLOT_FOLDER_NAME
		))
	end

	for plotIndex = 1, math.min(#plots, PlotConfig.PLOT_COUNT) do
		local plot = plots[plotIndex]
		ensurePlacardForPlot(plotIndex, plot)
		setPlotSpawnEnabled(plot, false)
		applyUnassignedTierVisuals(plot)
	end

	BaseUpgradeService.onUpgraded(handleUpgrade)

	for _, player in Players:GetPlayers() do
		task.defer(assignPlot, player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.defer(assignPlot, player)

		player.CharacterAdded:Connect(function(character)
			task.defer(teleportCharacterToPlot, player, character)
		end)
	end)

	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function(character)
			task.defer(teleportCharacterToPlot, player, character)
		end)
	end

	Players.PlayerRemoving:Connect(releasePlot)
	placeRequestRemote.OnServerEvent:Connect(onPlaceRequest)
	pickupRequestRemote.OnServerEvent:Connect(onPickupRequest)

	-- The client fires this if it wants to explicitly request a pad unlock
	-- (e.g. from a UI button). The main path goes through onPlacePromptTriggered,
	-- but we handle it here too for resilience.
	padUnlockRemote.OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		local slotIndex = tonumber(payload.slotIndex)
		if not slotIndex then
			return
		end

		local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
		if slotIndex < 1 or slotIndex > maxSlots then
			return
		end

		if PlayerDataService.isPadUnlocked(player, slotIndex) then
			return
		end

		local cost = PlotConfig.getPadUnlockCost(slotIndex)
		local data = PlayerDataService.getData(player)
		if data.money < cost then
			padUnlockRemote:FireClient(player, {
				success = false,
				slotIndex = slotIndex,
				cost = cost,
				message = ("Need %s to unlock this pad."):format(FormatUtil.money(cost)),
			})
			return
		end

		if cost > 0 then
			PlayerDataService.addMoney(player, -cost, "PadUnlock")
		end
		PlayerDataService.unlockPad(player, slotIndex)
		task.spawn(PlayerDataService.savePlayer, player)

		padUnlockRemote:FireClient(player, {
			success = true,
			slotIndex = slotIndex,
			cost = cost,
		})

		CollectService.syncPlayer(player)
		updatePlaceLabel(player, slotIndex)
		renderSlot(player, slotIndex)
		syncSlots(player)
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			snapshotUncollectedCash(player)
			PlayerDataService.savePlayer(player)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				local maxSlots = getMaxSlotsForTier(getPlayerTier(player))
				for slotIndex = 1, maxSlots do
					updateCollectLabel(player, slotIndex)
				end
				refreshPlacardForPlayer(player)
			end
		end
	end)
end

return PlotService
