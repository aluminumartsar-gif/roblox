--[[
	Paste into the Studio Command Bar (or run via Studio MCP execute_luau) with the
	full game place open. Rojo does not sync Workspace, so map fixes live here.

	For every SpawnLocation in Workspace (including per-base spawns), finds BaseParts
	whose bounds overlap an expanded box around the pad and:

	- Destroys overlapping BaseParts that live under an ancestor folder named one of:
	  Decor, Scenery, Props, MapProps (case-insensitive).
	- For everything else overlapping (except structural skips), disables
	  CanCollide / CanTouch so players are not blocked (visuals stay).

	Edit EXPANSION or SKIP_PART_NAMES if your build uses nonstandard part names.
]]

local Workspace = game:GetService("Workspace")

local EXPANSION = Vector3.new(4, 8, 4) -- studs beyond SpawnLocation size
local MAX_STRUCTURAL_DIM = 40 -- parts larger than this on any axis are treated as building/ground

local SKIP_PART_NAMES: { [string]: boolean } = {
	SpawnLocation = true,
	Pad = true,
	Collect = true,
	DisplayPoint = true,
	UpgradePad = true,
	FloorSlab = true,
	Ladder = true,
	EntrancePost1 = true,
	EntrancePost2 = true,
	Baseplate = true,
	EntranceWalkway = true,
	HumanoidRootPart = true,
}

local DECOR_FOLDER_NAMES: { [string]: boolean } = {
	decor = true,
	scenery = true,
	props = true,
	mapprops = true,
}

local function ancestorNamed(inst: Instance, name: string): boolean
	local p: Instance? = inst
	while p do
		if p.Name == name then
			return true
		end
		p = p.Parent
	end
	return false
end

local function underDecorTree(inst: Instance): boolean
	local p: Instance? = inst
	while p and p ~= game do
		local key = string.lower(p.Name)
		if DECOR_FOLDER_NAMES[key] then
			return true
		end
		p = p.Parent
	end
	return false
end

local function shouldAlwaysSkip(inst: Instance): boolean
	if inst:IsA("Terrain") then
		return true
	end
	if ancestorNamed(inst, "Leaderboards") or ancestorNamed(inst, "RBLXEssentials") then
		return true
	end
	local m = inst:FindFirstAncestorOfClass("Model")
	if m and m:FindFirstChildOfClass("Humanoid") then
		return true
	end
	if SKIP_PART_NAMES[inst.Name] then
		return true
	end
	return false
end

local function isLikelyStructuralFloor(part: BasePart): boolean
	if part.Name == "FloorSlab" or part.Name == "TrussPart" or part:IsA("TrussPart") then
		return true
	end
	local s = part.Size
	if math.max(s.X, s.Y, s.Z) >= MAX_STRUCTURAL_DIM then
		return true
	end
	local parent = part.Parent
	if parent and string.match(parent.Name, "^Floor%d+") then
		-- Large walking surfaces inside floor models — keep collision unless explicitly decor tree
		if s.X * s.Z > 400 and s.Y <= 4 then
			return true
		end
	end
	return false
end

local spawns: { BasePart } = {}
for _, d in Workspace:GetDescendants() do
	if d:IsA("SpawnLocation") then
		table.insert(spawns, d)
	end
end

if #spawns > 0 then
	local destroyed = 0
	local softened = 0

	for _, pad in spawns do
		local padPart = pad :: BasePart
		local filter: { Instance } = { padPart }
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = filter
		local overlapSize = padPart.Size + EXPANSION
		local parts = Workspace:GetPartBoundsInBox(padPart.CFrame, overlapSize, params)

		for _, part in parts do
			if part:IsA("BasePart") then
				local bp = part :: BasePart
				if not shouldAlwaysSkip(bp) then
					if not isLikelyStructuralFloor(bp) or underDecorTree(bp) then
						if underDecorTree(bp) then
							bp:Destroy()
							destroyed = destroyed + 1
						elseif bp.CanCollide or bp.CanTouch then
							bp.CanCollide = false
							bp.CanTouch = false
							softened = softened + 1
						end
					end
				end
			end
		end
	end

	print(
		("[StripSpawnBlockingScenery] Spawns: %d | Decor destroyed: %d | Other collision cleared: %d"):format(
			#spawns,
			destroyed,
			softened
		)
	)
else
	warn("[StripSpawnBlockingScenery] No SpawnLocation found.")
end
