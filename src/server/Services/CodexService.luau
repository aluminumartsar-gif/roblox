--!strict
--[[
	CodexService
	ServerScriptService/Server/Services/CodexService

	Hook 3: the Cryptid Codex and the Field Camera.

	  * Every player gets a Field Camera (Config.Codex.CameraToolName) each
	    time they spawn, next to the Bat.
	  * The client aims and asks; the server decides. TakePhoto(model) is
	    accepted only for a real tagged cryptid model in the world:
	      - in a nest           (Config.Tags.Creature)
	      - a wild sighting     (Config.Tags.WildCryptid)
	      - being carried       (Config.Tags.CarriedItem with Kind "Creature")
	    with the camera in hand, within Config.Codex.MaxPhotoDistance (plus
	    Config.Prompts.ServerDistanceSlack), off cooldown
	    (Config.Codex.PhotoCooldown), and with a lenient line of sight
	    (characters, Workspace.Runtime items, see-through and walk-through
	    parts don't block).
	  * Hatching a creature (NestService.Hatched) and claiming one
	    (StealService.Claimed — captured sightings; only eggs can be
	    stolen, and they log when they hatch) log it too, silently if it's
	    already known.

	Data: profile.Codex[creatureId] = true (ProfileTemplate; repair drops
	unknown ids). The Codex is not in Config.Rebirth.Resets, so it survives
	rebirth. Page luck is NOT applied here: BoostService.GetLuckPercent
	counts complete rarity pages itself, so a new entry raises luck on the
	very next hatch with nothing else to do.

	Client pushes: CodexDiscovered(creatureId, { IsNew = true,
	PageCompleted = rarity?, Source = "Photo" | "Hatch" | "Claim" | "Debug" })
	for every NEW entry. A completed page is also announced server-wide
	(GlobalAnnounce) and saved straight away.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local DataService = require(Services:WaitForChild("DataService"))
local NestService = require(Services:WaitForChild("NestService"))
local StealService = require(Services:WaitForChild("StealService"))

local CodexService = {}

local COOLDOWN_KEY = "CodexPhoto"

local discoveredRemote: RemoteEvent? = nil

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Codex] " .. fmt, ...))
	end
end

--------------------------------------------------------------------------
-- Pages
--------------------------------------------------------------------------

--- True if every creature of this rarity is in the codex table.
local function isPageComplete(codex: { [string]: boolean }, rarity: string): boolean
	local list = Config.CreaturesByRarity[rarity]
	if not list or #list == 0 then
		return false
	end
	for _, creature in ipairs(list) do
		if not codex[creature.Id] then
			return false
		end
	end
	return true
end

--- Number of complete rarity pages (display only; BoostService owns luck).
function CodexService.CountCompletePages(player: Player): number
	local data = DataService.Get(player)
	if not data then
		return 0
	end
	local pages = 0
	for _, rarity in ipairs(Config.RarityOrder) do
		if isPageComplete(data.Codex, rarity) then
			pages += 1
		end
	end
	return pages
end

function CodexService.Has(player: Player, creatureId: string): boolean
	local data = DataService.Get(player)
	return data ~= nil and data.Codex[creatureId] == true
end

--------------------------------------------------------------------------
-- Logging an entry
--------------------------------------------------------------------------

local function announce(text: string, rarity: string)
	RemoteGuard.GetClientEvent("GlobalAnnounce"):FireAllClients(text, rarity)
end

--- Logs `creatureId` in the player's Codex. Returns (isNew, pageCompleted).
--- Already known: does nothing and returns false. `silent` skips the
--- client celebration, toast and announcement (debug bulk adds).
function CodexService.Discover(player: Player, creatureId: string, source: string, silent: boolean?): (boolean, string?)
	local def = Config.CreaturesById[creatureId]
	if not def then
		return false, nil
	end
	local data = DataService.Get(player)
	if not data or data.Codex[creatureId] then
		return false, nil
	end

	local wasComplete = isPageComplete(data.Codex, def.Rarity)
	local ok = DataService.Mutate(player, function(d)
		d.Codex[creatureId] = true
		if source == "Photo" then
			d.Stats.PhotosTaken = (tonumber(d.Stats.PhotosTaken) or 0) + 1
		end
	end)
	if not ok then
		return false, nil
	end

	local fresh = DataService.Get(player)
	local pageCompleted: string? = nil
	if fresh and not wasComplete and isPageComplete(fresh.Codex, def.Rarity) then
		pageCompleted = def.Rarity
	end
	log("%s logged %s (%s) via %s%s", player.Name, creatureId, def.Rarity, source,
		if pageCompleted then (" — " .. pageCompleted .. " page complete") else "")

	if not silent then
		if discoveredRemote and player.Parent == Players then
			discoveredRemote:FireClient(player, creatureId, {
				IsNew = true,
				PageCompleted = pageCompleted,
				Source = source,
			})
		end
		Notifier.Send(player, string.format("New Codex entry: %s!", def.Name), "Success")
	end

	if pageCompleted then
		if not silent then
			announce(string.format("%s completed the %s page of their Codex! (+%g%% luck forever)",
				player.DisplayName, pageCompleted, Config.Luck.CodexPageCompletePercent), pageCompleted)
		end
		-- A permanent luck bonus is worth a save right now.
		task.spawn(function()
			if player.Parent == Players then
				DataService.SaveNow(player)
			end
		end)
	end
	return true, pageCompleted
end

--------------------------------------------------------------------------
-- Photos
--------------------------------------------------------------------------

--- The creature id a photographable model shows, or nil if it isn't one.
local function creatureIdOf(model: Model): string?
	local id: any = nil
	if CollectionService:HasTag(model, Config.Tags.Creature) or CollectionService:HasTag(model, Config.Tags.WildCryptid) then
		id = model:GetAttribute("CreatureId")
	elseif CollectionService:HasTag(model, Config.Tags.CarriedItem) then
		if model:GetAttribute("Kind") == "Creature" then
			id = model:GetAttribute("CreatureId")
		end
	end
	if typeof(id) == "string" and Config.CreaturesById[id] then
		return id
	end
	return nil
end

--- True if a part shouldn't block a photo.
local function isSeeThrough(part: BasePart): boolean
	return not part.CanCollide or part.Transparency >= Config.Codex.LosIgnoreTransparency
end

--- One lenient ray: walks through see-through parts, stops at a solid one.
local function rayIsClear(origin: Vector3, target: Vector3, params: RaycastParams): boolean
	local direction = target - origin
	for _ = 1, Config.Codex.LosMaxPierce do
		local result = Workspace:Raycast(origin, direction, params)
		if not result then
			return true
		end
		local hit = result.Instance
		if hit:IsA("BasePart") and isSeeThrough(hit) then
			params:AddToFilter(hit)
		else
			return false
		end
	end
	return false
end

local function hasLineOfSight(player: Player, model: Model): boolean
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local root = RemoteGuard.GetRoot(player)
	if not root then
		return false
	end
	local eye = if head and head:IsA("BasePart") then head.Position else root.Position

	local ignore: { Instance } = { model }
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local runtime = Workspace:FindFirstChild("Runtime")
	if runtime then
		table.insert(ignore, runtime)
	end

	local boxCf, boxSize = model:GetBoundingBox()
	local targets = { boxCf.Position, boxCf.Position + Vector3.new(0, boxSize.Y * 0.45, 0) }
	local origins = { eye, eye + Vector3.new(0, Config.Codex.LosLenientRise, 0) }
	for _, origin in ipairs(origins) do
		for _, target in ipairs(targets) do
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = ignore
			params.IgnoreWater = true
			if rayIsClear(origin, target, params) then
				return true
			end
		end
	end
	return false
end

local function takePhoto(player: Player, target: any): RemoteGuard.Result
	-- Type + "is it a real cryptid" (the client names an instance; nothing
	-- else it sends is used).
	if typeof(target) ~= "Instance" or not target:IsA("Model") or not target:IsDescendantOf(Workspace) then
		return { Ok = false, Message = "No cryptid in that shot." }
	end
	local model = target :: Model
	local creatureId = creatureIdOf(model)
	if not creatureId then
		return { Ok = false, Message = "No cryptid in that shot." }
	end

	-- The camera must be in hand.
	local character = player.Character
	local tool = character and character:FindFirstChild(Config.Codex.CameraToolName)
	if not tool or not tool:IsA("Tool") then
		return { Ok = false, Message = "Hold your Field Camera to take a photo." }
	end

	-- Distance.
	local reach = Config.Codex.MaxPhotoDistance + Config.Prompts.ServerDistanceSlack
	if not RemoteGuard.IsWithinReach(player, model:GetPivot().Position, reach) then
		return { Ok = false, Message = "Too far away. Get a little closer." }
	end

	-- Cooldown.
	if not RemoteGuard.Cooldowns.Ready(player, COOLDOWN_KEY) then
		return { Ok = false, Message = "Still winding the film..." }
	end

	-- State: profile loaded, and a clear view.
	if not DataService.Get(player) then
		return { Ok = false, Message = "Your Codex is still loading." }
	end
	if not hasLineOfSight(player, model) then
		return { Ok = false, Message = "Something's in the way." }
	end

	RemoteGuard.Cooldowns.Start(player, COOLDOWN_KEY, Config.Codex.PhotoCooldown)

	local isNew, pageCompleted = CodexService.Discover(player, creatureId, "Photo")
	return {
		Ok = true,
		IsNew = isNew,
		CreatureId = creatureId,
		PageCompleted = pageCompleted,
	}
end

--------------------------------------------------------------------------
-- The camera tool
--------------------------------------------------------------------------

local function weldTo(base: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = base
	weld.Part1 = part
	weld.Parent = base
end

local function giveCamera(player: Player)
	local backpack = player:WaitForChild("Backpack", 10)
	if not backpack or backpack:FindFirstChild(Config.Codex.CameraToolName) then
		return
	end
	local character = player.Character
	if character and character:FindFirstChild(Config.Codex.CameraToolName) then
		return
	end

	local tool = Instance.new("Tool")
	tool.Name = Config.Codex.CameraToolName
	tool.ToolTip = "Photograph cryptids for your Codex"
	tool.TextureId = Config.Icons.Camera
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	-- Held just above the hand, lens forward (the handle's -Z).
	tool.Grip = CFrame.new(0, -0.45, 0.1)

	local body = Instance.new("Part")
	body.Name = "Handle"
	body.Size = Vector3.new(1.2, 0.8, 0.6)
	body.Color = Config.Codex.ToolBodyColor
	body.Material = Enum.Material.SmoothPlastic
	body.CanCollide = false
	body.Massless = true
	body.Parent = tool

	local barrel = Instance.new("Part")
	barrel.Name = "Lens"
	barrel.Shape = Enum.PartType.Cylinder
	barrel.Size = Vector3.new(0.35, 0.55, 0.55)
	barrel.Color = Config.Codex.ToolBodyColor
	barrel.Material = Enum.Material.SmoothPlastic
	barrel.CanCollide = false
	barrel.Massless = true
	barrel.CFrame = body.CFrame * CFrame.new(0.15, 0, -0.45) * CFrame.Angles(0, math.pi / 2, 0)
	barrel.Parent = tool
	weldTo(body, barrel)

	local glass = Instance.new("Part")
	glass.Name = "Glass"
	glass.Shape = Enum.PartType.Cylinder
	glass.Size = Vector3.new(0.06, 0.42, 0.42)
	glass.Color = Config.Codex.ToolLensColor
	glass.Material = Enum.Material.Glass
	glass.Reflectance = 0.3
	glass.CanCollide = false
	glass.Massless = true
	glass.CFrame = body.CFrame * CFrame.new(0.15, 0, -0.64) * CFrame.Angles(0, math.pi / 2, 0)
	glass.Parent = tool
	weldTo(body, glass)

	local viewfinder = Instance.new("Part")
	viewfinder.Name = "Viewfinder"
	viewfinder.Size = Vector3.new(0.4, 0.22, 0.4)
	viewfinder.Color = Config.Codex.ToolBodyColor:Lerp(Color3.new(1, 1, 1), 0.12)
	viewfinder.Material = Enum.Material.SmoothPlastic
	viewfinder.CanCollide = false
	viewfinder.Massless = true
	viewfinder.CFrame = body.CFrame * CFrame.new(-0.3, 0.5, 0)
	viewfinder.Parent = tool
	weldTo(body, viewfinder)

	local recLight = Instance.new("Part")
	recLight.Name = "RecLight"
	recLight.Shape = Enum.PartType.Ball
	recLight.Size = Vector3.one * 0.14
	recLight.Color = Color3.fromRGB(255, 50, 50)
	recLight.Material = Enum.Material.Neon
	recLight.CanCollide = false
	recLight.Massless = true
	recLight.CFrame = body.CFrame * CFrame.new(-0.45, 0.25, -0.3)
	recLight.Parent = tool
	weldTo(body, recLight)

	tool.Parent = backpack
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function CodexService.Start()
	if not Config.Codex.Enabled then
		log("disabled (Config.Codex.Enabled = false)")
		return
	end

	for _, creature in ipairs(Config.Creatures) do
		if not Config.Codex.Blurbs[creature.Id] then
			warn("[SAC/Codex] No Config.Codex.Blurbs entry for " .. creature.Id)
		end
	end

	discoveredRemote = RemoteGuard.GetClientEvent("CodexDiscovered")
	RemoteGuard.BindFunction("TakePhoto", takePhoto)

	-- Hatching and claiming log automatically.
	NestService.Hatched:Connect(function(player: Player, _nestIndex: number, result: any)
		if typeof(result) == "table" and typeof(result.CreatureId) == "string" then
			CodexService.Discover(player, result.CreatureId, "Hatch")
		end
	end)
	StealService.Claimed:Connect(function(player: Player, carry: any, _nestIndex: number)
		local slot = carry and carry.Slot
		if typeof(slot) == "table" and slot.Kind == "Creature" and typeof(slot.CreatureId) == "string" then
			CodexService.Discover(player, slot.CreatureId, "Claim")
		end
	end)

	-- A camera every spawn, like the Bat.
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			giveCamera(player)
		end)
		if player.Character then
			task.spawn(giveCamera, player)
		end
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
end

return CodexService
