--!nocheck
-- The DataModel and its services. Services are mock Instances of the real
-- service classes (so unknown members still fail), with behaviour for what
-- client code uses: RunService's frame events, TweenService, Players,
-- UserInputService, GuiService, CollectionService, MarketplaceService, ...

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Classes = require("./classes")
local Datatypes = require("./datatypes")
local Inst = require("./inst")
local Reflect = require("./reflect")
local Report = require("./report")
local Sched = require("./sched")
local Signal = require("./signal")
local Typeof = require("./typeof")
local Util = require("./util")

local S = Inst.S
local B = Inst.Behaviors
local raise = Inst.raise
local selfState = Inst.selfState
local typeOf = Typeof.typeof
local get = Inst.get

local Vector2 = roblox.Vector2
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local Services = {}

Services.profile = nil
Services.game = nil
Services.byClass = {} -- className -> service proxy
Services.calls = {} -- notable API calls (purchases, teleports, invites, SetCore)

local function argType(v: any, expected: string, index: number, fn: string, optional: boolean?)
	if v == nil and optional then
		return
	end
	local t = typeOf(v)
	if t ~= expected then
		raise(
			string.format("invalid argument #%d to '%s' (%s expected, got %s)", index, fn, expected, t),
			"Invalid API arguments"
		)
	end
end

local function instanceArg(v: any, index: number, fn: string, className: string?)
	if not Inst.is(v) then
		raise(
			string.format("invalid argument #%d to '%s' (Instance expected, got %s)", index, fn, typeOf(v)),
			"Invalid API arguments"
		)
	end
	if className and not Inst.isA(v, className) then
		raise(
			string.format("invalid argument #%d to '%s' (%s expected, got %s)", index, fn, className, S[v].className),
			"Invalid API arguments"
		)
	end
end

local function enumArg(v: any, enumName: string, index: number, fn: string)
	if typeOf(v) ~= "EnumItem" or Reflect.enumNameOf(v) ~= enumName then
		raise(
			string.format("invalid argument #%d to '%s' (Enum.%s expected, got %s)", index, fn, enumName, typeOf(v)),
			"Invalid API arguments"
		)
	end
end

local function note(kind: string, text: string)
	table.insert(Services.calls, { kind = kind, text = text, t = Sched.now, step = Report.step, loc = Report.callerLocation() })
end

--------------------------------------------------------------------------
-- DataModel
--------------------------------------------------------------------------

local SERVICE_NAMES = {
	RunService = "Run Service",
}

local function createService(className: string)
	local svc = Inst.create(className)
	S[svc].name = SERVICE_NAMES[className] or className
	Inst.setParent(svc, S[svc], Services.game, true)
	Services.byClass[className] = svc
	return svc
end

local function getService(self, name, method)
	selfState(self, method)
	argType(name, "string", 1, method)
	local svc = Services.byClass[name]
	if svc then
		return svc
	end
	local rec = Reflect.class(name)
	if not rec or not rec.service then
		if method == "FindService" then
			return nil
		end
		raise(string.format("'%s' is not a valid Service name", name), "Invalid services")
	end
	return createService(name)
end

B.ServiceProvider = {
	methods = {
		GetService = function(self, name)
			return getService(self, name, "GetService")
		end,
		FindService = function(self, name)
			return getService(self, name, "FindService")
		end,
	},
}
B.ServiceProvider.methods.getService = B.ServiceProvider.methods.GetService
B.ServiceProvider.methods.service = B.ServiceProvider.methods.GetService

B.DataModel = {
	getters = {
		Workspace = function()
			return Services.byClass.Workspace
		end,
		PlaceId = function()
			return 0
		end,
		GameId = function()
			return 0
		end,
		JobId = function()
			return ""
		end,
		CreatorId = function()
			return 0
		end,
		PlaceVersion = function()
			return 0
		end,
		PrivateServerId = function()
			return ""
		end,
		PrivateServerOwnerId = function()
			return 0
		end,
	},
	methods = {
		IsLoaded = function(self)
			selfState(self, "IsLoaded")
			return true
		end,
		BindToClose = function(self)
			selfState(self, "BindToClose")
			raise("BindToClose can only be called on the server", "Invalid API use")
		end,
		GetJobsInfo = function(self)
			selfState(self, "GetJobsInfo")
			return {}
		end,
	},
}

--------------------------------------------------------------------------
-- RunService: frames
--------------------------------------------------------------------------

local renderBinds = {} -- name -> { priority, fn, seq }
local bindSeq = 0

B.RunService = {
	methods = {
		IsStudio = function(self)
			selfState(self, "IsStudio")
			return true
		end,
		IsClient = function(self)
			selfState(self, "IsClient")
			return true
		end,
		IsServer = function(self)
			selfState(self, "IsServer")
			return false
		end,
		IsRunning = function(self)
			selfState(self, "IsRunning")
			return true
		end,
		IsRunMode = function(self)
			selfState(self, "IsRunMode")
			return false
		end,
		IsEdit = function(self)
			selfState(self, "IsEdit")
			return false
		end,
		BindToRenderStep = function(self, name, priority, fn)
			selfState(self, "BindToRenderStep")
			argType(name, "string", 1, "BindToRenderStep")
			argType(priority, "number", 2, "BindToRenderStep")
			argType(fn, "function", 3, "BindToRenderStep")
			bindSeq += 1
			renderBinds[name] = { priority = priority, fn = fn, seq = bindSeq, name = name, location = Report.callerLocation() }
		end,
		UnbindFromRenderStep = function(self, name)
			selfState(self, "UnbindFromRenderStep")
			argType(name, "string", 1, "UnbindFromRenderStep")
			renderBinds[name] = nil
		end,
		Set3dRenderingEnabled = function(self)
			selfState(self, "Set3dRenderingEnabled")
		end,
	},
}

local function onFrame(dt: number)
	local rs = Services.byClass.RunService
	local binds = {}
	for _, b in renderBinds do
		table.insert(binds, b)
	end
	table.sort(binds, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return a.seq < b.seq
	end)
	for _, b in binds do
		if renderBinds[b.name] == b then
			local co = Sched.create(b.fn, "BindToRenderStep(" .. b.name .. ") bound at " .. tostring(b.location))
			Sched.resume(co, dt)
		end
	end
	Inst.fire(rs, "PreRender", dt)
	Inst.fire(rs, "RenderStepped", dt)
	Inst.fire(rs, "PreAnimation", dt)
	Inst.fire(rs, "Stepped", Sched.now, dt)
	Inst.fire(rs, "PreSimulation", dt)
	Inst.fire(rs, "PostSimulation", dt)
	Inst.fire(rs, "Heartbeat", dt)
	Services.pollLayout()
end

-- Layout-derived properties (AbsoluteSize, ...) change when anything about
-- the layout changes; like Roblox, their changed signals fire after the
-- frame's layout pass. Only instances someone listens to are polled. The
-- first value counts as a change from (0, 0), as after Roblox's first layout.
local LAYOUT_PROPS = { "AbsoluteSize", "AbsolutePosition", "AbsoluteContentSize", "AbsoluteCanvasSize" }
local layoutLast = setmetatable({}, { __mode = "k" })

function Services.pollLayout()
	for proxy in Inst.layoutWatchers do
		local st = S[proxy]
		if not st or st.destroyed or not st.propSignals then
			continue
		end
		local last = layoutLast[proxy]
		if not last then
			last = {}
			layoutLast[proxy] = last
		end
		for _, prop in LAYOUT_PROPS do
			local sig = st.propSignals[prop]
			if sig and st.info.rec.props[prop] then
				local ok, value = pcall(Inst.get, proxy, prop)
				if ok then
					local previous = last[prop]
					if previous == nil then
						previous = Vector2.zero
					end
					if value ~= previous then
						last[prop] = value
						Signal.fire(sig)
					else
						last[prop] = value
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- TweenService
--------------------------------------------------------------------------

local TWEENABLE = {
	number = true,
	boolean = true,
	CFrame = true,
	Rect = true,
	Color3 = true,
	UDim = true,
	UDim2 = true,
	Vector2 = true,
	Vector2int16 = true,
	Vector3 = true,
	EnumItem = true,
}

local activeTweens = {} -- target -> { prop -> tween proxy }
Services.playingTweens = {} -- tween -> true while Playing

local function applyTweenValues(target, ts, values)
	for prop, value in values do
		local s = ts.info.setters[prop]
		if s then
			s(target, ts, value)
		else
			Inst.setRaw(target, ts, prop, value)
		end
	end
end

local function tweenCancelInternal(tween, st, state)
	local tw = st.tween
	if tw.timer then
		Sched.cancelTimer(tw.timer)
		tw.timer = nil
	end
	Services.playingTweens[tween] = nil
	Inst.setRaw(tween, st, "PlaybackState", state)
	Inst.fire(tween, "Completed", state)
end

local function lerpValue(a, b, alpha)
	local t = typeOf(a)
	if t ~= typeOf(b) then
		return if alpha >= 1 then b else a
	end
	if t == "number" then
		return a + (b - a) * alpha
	elseif t == "Color3" or t == "UDim2" or t == "Vector2" or t == "Vector3" or t == "CFrame" then
		return a:Lerp(b, alpha)
	elseif t == "UDim" then
		return roblox.UDim.new(a.Scale + (b.Scale - a.Scale) * alpha, a.Offset + (b.Offset - a.Offset) * alpha)
	elseif t == "Rect" then
		return roblox.Rect.new(a.Min:Lerp(b.Min, alpha), a.Max:Lerp(b.Max, alpha))
	end
	return if alpha >= 1 then b else a
end

--- For snapshots: tweens that end within `window` seconds finish now
--- (goal values applied, Completed fired); longer ones are set to their
--- current interpolated value; endless loops are shown at rest.
function Services.settleTweens(window: number)
	local list = {}
	for tween in Services.playingTweens do
		table.insert(list, tween)
	end
	table.sort(list, function(a, b)
		return S[a].id < S[b].id
	end)
	for _, tween in list do
		local st = S[tween]
		local tw = st.tween
		if not Services.playingTweens[tween] or not tw then
			continue
		end
		local target = tw.target
		local ts = S[target]
		local info = tw.info
		if info.RepeatCount < 0 then
			applyTweenValues(target, ts, tw.start or {})
		elseif (tw.endsAt or 0) - Sched.now <= window then
			if tw.timer then
				Sched.cancelTimer(tw.timer)
				tw.timer = nil
			end
			applyTweenValues(target, ts, if info.Reverses then tw.start else tw.goals)
			Services.playingTweens[tween] = nil
			Inst.setRaw(tween, st, "PlaybackState", Enum.PlaybackState.Completed)
			Inst.fire(tween, "Completed", Enum.PlaybackState.Completed)
		else
			local alpha = math.clamp((Sched.now - (tw.startedAt or Sched.now) - info.DelayTime) / math.max(info.Time, 1e-3), 0, 1)
			local values = {}
			for prop, goal in tw.goals do
				values[prop] = lerpValue(tw.start[prop], goal, alpha)
			end
			applyTweenValues(target, ts, values)
		end
	end
	Sched.drain()
end

Classes.tweenPlay = function(tween, st)
	local tw = st.tween
	local state = get(tween, "PlaybackState")
	if state == Enum.PlaybackState.Playing then
		return
	end
	local target = tw.target
	local ts = S[target]
	-- Another tween on the same property is cancelled.
	activeTweens[target] = activeTweens[target] or {}
	for prop in tw.goals do
		local other = activeTweens[target][prop]
		if other and other ~= tween then
			local os_ = S[other]
			if get(other, "PlaybackState") == Enum.PlaybackState.Playing then
				tweenCancelInternal(other, os_, Enum.PlaybackState.Cancelled)
			end
		end
		activeTweens[target][prop] = tween
	end
	local info = tw.info
	if state ~= Enum.PlaybackState.Paused then
		tw.start = {}
		for prop in tw.goals do
			tw.start[prop] = get(target, prop)
		end
	end
	local cycle = info.Time * (if info.Reverses then 2 else 1)
	local total
	if info.RepeatCount < 0 then
		total = info.DelayTime + info.Time
	else
		total = info.DelayTime + cycle * (info.RepeatCount + 1)
	end
	if state == Enum.PlaybackState.Paused and tw.remaining then
		total = tw.remaining
	end
	tw.endsAt = Sched.now + total
	tw.startedAt = Sched.now - (if state == Enum.PlaybackState.Paused and tw.elapsed then tw.elapsed else 0)
	Inst.setRaw(tween, st, "PlaybackState", Enum.PlaybackState.Playing)
	Services.playingTweens[tween] = true
	tw.timer = Sched.after(total, function()
		tw.timer = nil
		local final = if info.Reverses then tw.start else tw.goals
		applyTweenValues(target, ts, final)
		if info.RepeatCount < 0 then
			return -- loops forever: stays Playing
		end
		Services.playingTweens[tween] = nil
		Inst.setRaw(tween, st, "PlaybackState", Enum.PlaybackState.Completed)
		Inst.fire(tween, "Completed", Enum.PlaybackState.Completed)
	end)
end

Classes.tweenPause = function(tween, st)
	local tw = st.tween
	if get(tween, "PlaybackState") ~= Enum.PlaybackState.Playing then
		return
	end
	if tw.timer then
		Sched.cancelTimer(tw.timer)
		tw.timer = nil
	end
	tw.remaining = math.max(0, (tw.endsAt or Sched.now) - Sched.now)
	tw.elapsed = Sched.now - (tw.startedAt or Sched.now)
	Services.playingTweens[tween] = nil
	Inst.setRaw(tween, st, "PlaybackState", Enum.PlaybackState.Paused)
end

Classes.tweenCancel = function(tween, st)
	local state = get(tween, "PlaybackState")
	if state == Enum.PlaybackState.Playing or state == Enum.PlaybackState.Paused then
		tweenCancelInternal(tween, st, Enum.PlaybackState.Cancelled)
	end
end

B.TweenService = {
	methods = {
		Create = function(self, instance, tweenInfo, goals)
			selfState(self, "Create")
			if not Inst.is(instance) then
				raise("Unable to cast value to Object (TweenService:Create argument #1 is a " .. typeOf(instance) .. ")", "Invalid API arguments")
			end
			if typeOf(tweenInfo) ~= "TweenInfo" then
				raise("Unable to cast value to TweenInfo (TweenService:Create argument #2 is a " .. typeOf(tweenInfo) .. ")", "Invalid API arguments")
			end
			if type(goals) ~= "table" then
				raise("Unable to cast to Dictionary (TweenService:Create argument #3 is a " .. typeOf(goals) .. ")", "Invalid API arguments")
			end
			local ist = S[instance]
			local checked = {}
			for prop, value in goals do
				local p = ist.info.rec.props[prop]
				if not p then
					raise(string.format("TweenService:Create no property named '%s' for object '%s'", tostring(prop), ist.name), "Invalid tweens")
				end
				local current = get(instance, prop)
				local t = typeOf(value)
				if not TWEENABLE[t] or (current ~= nil and typeOf(current) ~= t and not (t == "number" and type(current) == "number")) then
					raise(
						string.format(
							"TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a '%s', but given type is '%s')",
							prop,
							typeOf(current),
							t
						),
						"Invalid tweens"
					)
				end
				if p.readOnly then
					raise(string.format("TweenService:Create property named '%s' is read-only", prop), "Invalid tweens")
				end
				checked[prop] = Inst.coerce(ist, p, value)
			end
			local tween = Inst.create("Tween")
			local st = S[tween]
			st.props.Instance = instance
			st.props.TweenInfo = tweenInfo
			st.props.PlaybackState = Enum.PlaybackState.Begin
			st.tween = { target = instance, info = Datatypes.tweenInfoFields(tweenInfo), goals = checked }
			return tween
		end,
		GetValue = function(self, alpha, style, direction)
			selfState(self, "GetValue")
			argType(alpha, "number", 1, "GetValue")
			enumArg(style, "EasingStyle", 2, "GetValue")
			enumArg(direction, "EasingDirection", 3, "GetValue")
			return math.clamp(alpha, 0, 1)
		end,
	},
}

--------------------------------------------------------------------------
-- Workspace
--------------------------------------------------------------------------

B.Workspace = {
	getters = {
		Terrain = function(proxy, st)
			return Inst.findChild(st, "Terrain")
		end,
		DistributedGameTime = function()
			return Sched.now
		end,
	},
	methods = {
		GetServerTimeNow = function(self)
			selfState(self, "GetServerTimeNow")
			return Sched.EPOCH + Sched.now
		end,
		Raycast = function(self, origin, direction, params)
			selfState(self, "Raycast")
			argType(origin, "Vector3", 1, "Raycast")
			argType(direction, "Vector3", 2, "Raycast")
			argType(params, "RaycastParams", 3, "Raycast", true)
			return nil
		end,
		Blockcast = function(self, cf, size, direction, params)
			selfState(self, "Blockcast")
			argType(cf, "CFrame", 1, "Blockcast")
			argType(size, "Vector3", 2, "Blockcast")
			argType(direction, "Vector3", 3, "Blockcast")
			return nil
		end,
		Spherecast = function(self, position, radius, direction, params)
			selfState(self, "Spherecast")
			argType(position, "Vector3", 1, "Spherecast")
			argType(radius, "number", 2, "Spherecast")
			argType(direction, "Vector3", 3, "Spherecast")
			return nil
		end,
		Shapecast = function(self)
			selfState(self, "Shapecast")
			return nil
		end,
		GetPartBoundsInBox = function(self, cf, size, params)
			selfState(self, "GetPartBoundsInBox")
			argType(cf, "CFrame", 1, "GetPartBoundsInBox")
			argType(size, "Vector3", 2, "GetPartBoundsInBox")
			argType(params, "OverlapParams", 3, "GetPartBoundsInBox", true)
			return {}
		end,
		GetPartBoundsInRadius = function(self, position, radius, params)
			selfState(self, "GetPartBoundsInRadius")
			argType(position, "Vector3", 1, "GetPartBoundsInRadius")
			argType(radius, "number", 2, "GetPartBoundsInRadius")
			argType(params, "OverlapParams", 3, "GetPartBoundsInRadius", true)
			return {}
		end,
		GetPartsInPart = function(self, part, params)
			selfState(self, "GetPartsInPart")
			instanceArg(part, 1, "GetPartsInPart", "BasePart")
			argType(params, "OverlapParams", 2, "GetPartsInPart", true)
			return {}
		end,
		FindPartOnRay = function(self, ray)
			selfState(self, "FindPartOnRay")
			argType(ray, "Ray", 1, "FindPartOnRay")
			return nil, ray.Origin + ray.Direction, Vector3.yAxis, Enum.Material.Air
		end,
		FindPartOnRayWithIgnoreList = function(self, ray)
			selfState(self, "FindPartOnRayWithIgnoreList")
			argType(ray, "Ray", 1, "FindPartOnRayWithIgnoreList")
			return nil, ray.Origin + ray.Direction, Vector3.yAxis, Enum.Material.Air
		end,
		FindPartOnRayWithWhitelist = function(self, ray)
			selfState(self, "FindPartOnRayWithWhitelist")
			argType(ray, "Ray", 1, "FindPartOnRayWithWhitelist")
			return nil, ray.Origin + ray.Direction, Vector3.yAxis, Enum.Material.Air
		end,
		FindPartsInRegion3 = function(self)
			selfState(self, "FindPartsInRegion3")
			return {}
		end,
		BulkMoveTo = function(self, parts, cframes, mode)
			selfState(self, "BulkMoveTo")
			argType(parts, "table", 1, "BulkMoveTo")
			argType(cframes, "table", 2, "BulkMoveTo")
			if #parts ~= #cframes then
				raise("BulkMoveTo: the parts and CFrames lists must be the same length", "Invalid API arguments")
			end
			for i, part in parts do
				if not Inst.is(part) or not Inst.isA(part, "BasePart") then
					raise("BulkMoveTo: item " .. i .. " of the parts list is not a BasePart", "Invalid API arguments")
				end
				if typeOf(cframes[i]) ~= "CFrame" then
					raise("BulkMoveTo: item " .. i .. " of the CFrames list is not a CFrame", "Invalid API arguments")
				end
				Classes.setPartCFrame(part, S[part], cframes[i])
			end
		end,
		GetRealPhysicsFPS = function(self)
			selfState(self, "GetRealPhysicsFPS")
			return 60
		end,
		GetNumAwakeParts = function(self)
			selfState(self, "GetNumAwakeParts")
			return 0
		end,
		ArePartsTouchingOthers = function(self)
			selfState(self, "ArePartsTouchingOthers")
			return false
		end,
	},
}

local terrainNoop = function(name)
	return function(self)
		selfState(self, name)
	end
end
B.Terrain = {
	methods = {
		FillBlock = terrainNoop("FillBlock"),
		FillBall = terrainNoop("FillBall"),
		FillCylinder = terrainNoop("FillCylinder"),
		FillWedge = terrainNoop("FillWedge"),
		FillRegion = terrainNoop("FillRegion"),
		Clear = terrainNoop("Clear"),
		SetMaterialColor = terrainNoop("SetMaterialColor"),
		GetMaterialColor = function(self)
			selfState(self, "GetMaterialColor")
			return roblox.Color3.new(0.4, 0.5, 0.3)
		end,
	},
}

--------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------

local mice = {}

local function getMouse(player)
	local m = mice[player]
	if not m then
		m = Inst.create("PlayerMouse")
		mice[player] = m
	end
	return m
end
Classes.getMouse = getMouse

local function playerFromCharacter(model)
	local players = Services.byClass.Players
	if not players or not model then
		return nil
	end
	for _, p in S[players].children do
		if S[p].className == "Player" and S[p].props.Character == model then
			return p
		end
	end
	return nil
end
Classes.playerFromCharacter = playerFromCharacter

B.Players = {
	getters = {
		LocalPlayer = function()
			return Classes.localPlayer
		end,
	},
	methods = {
		GetPlayers = function(self)
			local st = selfState(self, "GetPlayers")
			local out = {}
			for _, c in st.children do
				if S[c].className == "Player" then
					table.insert(out, c)
				end
			end
			return out
		end,
		GetPlayerFromCharacter = function(self, character)
			selfState(self, "GetPlayerFromCharacter")
			if character == nil then
				return nil
			end
			return playerFromCharacter(character)
		end,
		GetPlayerByUserId = function(self, userId)
			local st = selfState(self, "GetPlayerByUserId")
			argType(userId, "number", 1, "GetPlayerByUserId")
			for _, c in st.children do
				if S[c].className == "Player" and get(c, "UserId") == userId then
					return c
				end
			end
			return nil
		end,
		GetUserIdFromNameAsync = function(self, name)
			local st = selfState(self, "GetUserIdFromNameAsync")
			argType(name, "string", 1, "GetUserIdFromNameAsync")
			Sched.sleep(0.1)
			for _, c in st.children do
				if S[c].className == "Player" and S[c].name == name then
					return get(c, "UserId")
				end
			end
			return 123456
		end,
		GetNameFromUserIdAsync = function(self, userId)
			selfState(self, "GetNameFromUserIdAsync")
			argType(userId, "number", 1, "GetNameFromUserIdAsync")
			Sched.sleep(0.1)
			return "Player" .. tostring(userId)
		end,
		GetUserThumbnailAsync = function(self, userId, thumbType, size)
			selfState(self, "GetUserThumbnailAsync")
			argType(userId, "number", 1, "GetUserThumbnailAsync")
			enumArg(thumbType, "ThumbnailType", 2, "GetUserThumbnailAsync")
			enumArg(size, "ThumbnailSize", 3, "GetUserThumbnailAsync")
			Sched.sleep(0.1)
			return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId) .. "&w=150&h=150", true
		end,
		GetHumanoidDescriptionFromUserId = function(self, userId)
			selfState(self, "GetHumanoidDescriptionFromUserId")
			argType(userId, "number", 1, "GetHumanoidDescriptionFromUserId")
			Sched.sleep(0.1)
			return Inst.create("HumanoidDescription")
		end,
		CreateHumanoidModelFromDescription = function(self, desc)
			selfState(self, "CreateHumanoidModelFromDescription")
			local m = Inst.create("Model")
			local h = Inst.create("Humanoid")
			Inst.setParent(h, S[h], m)
			return m
		end,
	},
}

B.Player = {
	methods = {
		GetMouse = function(self)
			selfState(self, "GetMouse")
			return getMouse(self)
		end,
		Kick = function(self, message)
			selfState(self, "Kick")
			Report.add("WARN", "Player kicked by client code", "Player:Kick(" .. tostring(message) .. ")", Report.callerLocation())
		end,
		IsInGroup = function(self, groupId)
			selfState(self, "IsInGroup")
			argType(groupId, "number", 1, "IsInGroup")
			Sched.sleep(0.05)
			return false
		end,
		GetRankInGroup = function(self, groupId)
			selfState(self, "GetRankInGroup")
			argType(groupId, "number", 1, "GetRankInGroup")
			Sched.sleep(0.05)
			return 0
		end,
		GetRoleInGroup = function(self, groupId)
			selfState(self, "GetRoleInGroup")
			argType(groupId, "number", 1, "GetRoleInGroup")
			Sched.sleep(0.05)
			return "Guest"
		end,
		IsFriendsWith = function(self, userId)
			selfState(self, "IsFriendsWith")
			argType(userId, "number", 1, "IsFriendsWith")
			Sched.sleep(0.05)
			return false
		end,
		GetFriendsOnline = function(self)
			selfState(self, "GetFriendsOnline")
			Sched.sleep(0.05)
			return {}
		end,
		HasAppearanceLoaded = function(self)
			selfState(self, "HasAppearanceLoaded")
			return true
		end,
		LoadCharacter = function(self)
			selfState(self, "LoadCharacter")
			raise("LoadCharacter can only be called by the backend server", "Invalid API use")
		end,
		DistanceFromCharacter = function(self, point)
			local st = selfState(self, "DistanceFromCharacter")
			argType(point, "Vector3", 1, "DistanceFromCharacter")
			local character = st.props.Character
			local root = character and Inst.findChild(S[character], "HumanoidRootPart")
			if not root then
				return 0
			end
			return (get(root, "Position") - point).Magnitude
		end,
		GetJoinData = function(self)
			selfState(self, "GetJoinData")
			return {}
		end,
		GetNetworkPing = function(self)
			selfState(self, "GetNetworkPing")
			return 0.05
		end,
		RequestStreamAroundAsync = function(self)
			selfState(self, "RequestStreamAroundAsync")
			Sched.sleep(0.1)
		end,
	},
}

B.PlayerMouse = {
	getters = {
		Hit = function()
			local cam = Services.byClass.Workspace and get(Services.byClass.Workspace, "CurrentCamera")
			local cf = cam and get(cam, "CFrame") or CFrame.new()
			return CFrame.new(cf.Position + cf.LookVector * 100)
		end,
		Origin = function()
			local cam = Services.byClass.Workspace and get(Services.byClass.Workspace, "CurrentCamera")
			return cam and get(cam, "CFrame") or CFrame.new()
		end,
		X = function()
			return math.floor(Classes.viewport.X / 2)
		end,
		Y = function()
			return math.floor(Classes.viewport.Y / 2)
		end,
		ViewSizeX = function()
			return Classes.viewport.X
		end,
		ViewSizeY = function()
			return Classes.viewport.Y
		end,
		UnitRay = function()
			local cam = Services.byClass.Workspace and get(Services.byClass.Workspace, "CurrentCamera")
			local cf = cam and get(cam, "CFrame") or CFrame.new()
			return roblox.Ray.new(cf.Position, cf.LookVector)
		end,
	},
}

--------------------------------------------------------------------------
-- Input and GUI services
--------------------------------------------------------------------------

B.UserInputService = {
	getters = {
		TouchEnabled = function()
			return Services.profile.touch
		end,
		KeyboardEnabled = function()
			return Services.profile.keyboard
		end,
		MouseEnabled = function()
			return Services.profile.mouse
		end,
		GamepadEnabled = function()
			return false
		end,
		AccelerometerEnabled = function()
			return Services.profile.touch
		end,
		GyroscopeEnabled = function()
			return Services.profile.touch
		end,
		VREnabled = function()
			return false
		end,
		PreferredInput = function()
			return if Services.profile.touch then Enum.PreferredInput.Touch else Enum.PreferredInput.KeyboardAndMouse
		end,
	},
	methods = {
		GetMouseLocation = function(self)
			selfState(self, "GetMouseLocation")
			return Vector2.new(math.floor(Classes.viewport.X / 2), math.floor(Classes.viewport.Y / 2))
		end,
		GetLastInputType = function(self)
			selfState(self, "GetLastInputType")
			return if Services.profile.touch then Enum.UserInputType.Touch else Enum.UserInputType.MouseMovement
		end,
		IsKeyDown = function(self, key)
			selfState(self, "IsKeyDown")
			enumArg(key, "KeyCode", 1, "IsKeyDown")
			return false
		end,
		IsMouseButtonPressed = function(self, button)
			selfState(self, "IsMouseButtonPressed")
			enumArg(button, "UserInputType", 1, "IsMouseButtonPressed")
			return false
		end,
		GetFocusedTextBox = function(self)
			selfState(self, "GetFocusedTextBox")
			return Classes.focusedBox()
		end,
		GetConnectedGamepads = function(self)
			selfState(self, "GetConnectedGamepads")
			return {}
		end,
		GetNavigationGamepads = function(self)
			selfState(self, "GetNavigationGamepads")
			return {}
		end,
		GetGamepadConnected = function(self)
			selfState(self, "GetGamepadConnected")
			return false
		end,
		GetKeysPressed = function(self)
			selfState(self, "GetKeysPressed")
			return {}
		end,
		GetMouseButtonsPressed = function(self)
			selfState(self, "GetMouseButtonsPressed")
			return {}
		end,
		GetMouseDelta = function(self)
			selfState(self, "GetMouseDelta")
			return Vector2.zero
		end,
		GetStringForKeyCode = function(self, key)
			selfState(self, "GetStringForKeyCode")
			enumArg(key, "KeyCode", 1, "GetStringForKeyCode")
			return key.Name
		end,
		GetImageForKeyCode = function(self, key)
			selfState(self, "GetImageForKeyCode")
			enumArg(key, "KeyCode", 1, "GetImageForKeyCode")
			return ""
		end,
	},
}

B.GuiService = {
	getters = {
		TopbarInset = function()
			return roblox.Rect.new(0, 0, Classes.viewport.X, Classes.guiInset)
		end,
		MenuIsOpen = function()
			return false
		end,
	},
	methods = {
		GetGuiInset = function(self)
			selfState(self, "GetGuiInset")
			return Vector2.new(0, Classes.guiInset), Vector2.new(0, 0)
		end,
		IsTenFootInterface = function(self)
			selfState(self, "IsTenFootInterface")
			return false
		end,
		GetEmotesMenuOpen = function(self)
			selfState(self, "GetEmotesMenuOpen")
			return false
		end,
		GetInspectMenuEnabled = function(self)
			selfState(self, "GetInspectMenuEnabled")
			return false
		end,
		SetInspectMenuEnabled = function(self)
			selfState(self, "SetInspectMenuEnabled")
		end,
		CloseInspectMenu = function(self)
			selfState(self, "CloseInspectMenu")
		end,
		Select = function(self)
			selfState(self, "Select")
		end,
	},
}

local coreGuiEnabled = {}

B.StarterGui = {
	methods = {
		SetCoreGuiEnabled = function(self, coreGuiType, enabled)
			selfState(self, "SetCoreGuiEnabled")
			enumArg(coreGuiType, "CoreGuiType", 1, "SetCoreGuiEnabled")
			argType(enabled, "boolean", 2, "SetCoreGuiEnabled")
			coreGuiEnabled[coreGuiType.Name] = enabled
			note("SetCoreGuiEnabled", coreGuiType.Name .. " = " .. tostring(enabled))
		end,
		GetCoreGuiEnabled = function(self, coreGuiType)
			selfState(self, "GetCoreGuiEnabled")
			enumArg(coreGuiType, "CoreGuiType", 1, "GetCoreGuiEnabled")
			local v = coreGuiEnabled[coreGuiType.Name]
			if v == nil then
				return true
			end
			return v
		end,
		SetCore = function(self, name, value)
			selfState(self, "SetCore")
			argType(name, "string", 1, "SetCore")
			note("SetCore", name .. " = " .. Util.show(value))
		end,
		GetCore = function(self, name)
			selfState(self, "GetCore")
			argType(name, "string", 1, "GetCore")
			return nil
		end,
	},
}

B.PlayerGui = {
	methods = {
		GetGuiObjectsAtPosition = function(self, x, y)
			selfState(self, "GetGuiObjectsAtPosition")
			argType(x, "number", 1, "GetGuiObjectsAtPosition")
			argType(y, "number", 2, "GetGuiObjectsAtPosition")
			return {}
		end,
		SetTopbarTransparency = function(self)
			selfState(self, "SetTopbarTransparency")
		end,
		GetTopbarTransparency = function(self)
			selfState(self, "GetTopbarTransparency")
			return 0.5
		end,
	},
}

--------------------------------------------------------------------------
-- Asset / store / social / text services
--------------------------------------------------------------------------

B.ContentProvider = {
	getters = {
		RequestQueueSize = function()
			return 0
		end,
	},
	methods = {
		PreloadAsync = function(self, list, callback)
			selfState(self, "PreloadAsync")
			argType(list, "table", 1, "PreloadAsync")
			argType(callback, "function", 2, "PreloadAsync", true)
			for i, v in list do
				local t = typeOf(v)
				if t ~= "Instance" and t ~= "string" then
					raise(string.format("PreloadAsync: item %s of the list is a %s (Instance or content string expected)", tostring(i), t), "Invalid API arguments")
				end
			end
			Sched.sleep(0.2)
			if callback then
				for _, v in list do
					local id = if typeOf(v) == "string" then v else ""
					callback(id, Enum.AssetFetchStatus.Success)
				end
			end
		end,
		GetAssetFetchStatus = function(self)
			selfState(self, "GetAssetFetchStatus")
			return Enum.AssetFetchStatus.Success
		end,
	},
}

local function purchaseFinished(eventName, ...)
	local args = table.pack(...)
	Sched.after(1, function()
		Inst.fire(Services.byClass.MarketplaceService, eventName, table.unpack(args, 1, args.n))
	end)
end

B.MarketplaceService = {
	methods = {
		GetProductInfo = function(self, assetId, infoType)
			selfState(self, "GetProductInfo")
			argType(assetId, "number", 1, "GetProductInfo")
			if infoType ~= nil then
				enumArg(infoType, "InfoType", 2, "GetProductInfo")
			end
			Sched.sleep(0.1)
			if assetId == 0 then
				error("MarketplaceService:getProductInfo() failed because HTTP 400 (Bad Request)", 2)
			end
			return {
				Name = "X",
				Description = "",
				PriceInRobux = 49,
				ProductId = assetId,
				AssetId = assetId,
				IsForSale = true,
				IconImageAssetId = 0,
				Creator = { Name = "Creator", Id = 1 },
			}
		end,
		UserOwnsGamePassAsync = function(self, userId, passId)
			selfState(self, "UserOwnsGamePassAsync")
			argType(userId, "number", 1, "UserOwnsGamePassAsync")
			argType(passId, "number", 2, "UserOwnsGamePassAsync")
			Sched.sleep(0.1)
			return false
		end,
		PlayerOwnsAsset = function(self, player, assetId)
			selfState(self, "PlayerOwnsAsset")
			instanceArg(player, 1, "PlayerOwnsAsset", "Player")
			argType(assetId, "number", 2, "PlayerOwnsAsset")
			Sched.sleep(0.1)
			return false
		end,
		PromptProductPurchase = function(self, player, productId)
			selfState(self, "PromptProductPurchase")
			instanceArg(player, 1, "PromptProductPurchase", "Player")
			argType(productId, "number", 2, "PromptProductPurchase")
			note("PromptProductPurchase", tostring(productId))
			purchaseFinished("PromptProductPurchaseFinished", get(player, "UserId"), productId, false)
		end,
		PromptGamePassPurchase = function(self, player, passId)
			selfState(self, "PromptGamePassPurchase")
			instanceArg(player, 1, "PromptGamePassPurchase", "Player")
			argType(passId, "number", 2, "PromptGamePassPurchase")
			note("PromptGamePassPurchase", tostring(passId))
			purchaseFinished("PromptGamePassPurchaseFinished", player, passId, false)
		end,
		PromptPurchase = function(self, player, assetId)
			selfState(self, "PromptPurchase")
			instanceArg(player, 1, "PromptPurchase", "Player")
			argType(assetId, "number", 2, "PromptPurchase")
			note("PromptPurchase", tostring(assetId))
			purchaseFinished("PromptPurchaseFinished", player, assetId, false)
		end,
		PromptPremiumPurchase = function(self, player)
			selfState(self, "PromptPremiumPurchase")
			instanceArg(player, 1, "PromptPremiumPurchase", "Player")
			note("PromptPremiumPurchase", "")
		end,
	},
}

B.SocialService = {
	methods = {
		CanSendGameInviteAsync = function(self, player)
			selfState(self, "CanSendGameInviteAsync")
			instanceArg(player, 1, "CanSendGameInviteAsync", "Player")
			Sched.sleep(0.1)
			return true
		end,
		PromptGameInvite = function(self, player)
			selfState(self, "PromptGameInvite")
			instanceArg(player, 1, "PromptGameInvite", "Player")
			note("PromptGameInvite", "")
			Sched.after(1, function()
				Inst.fire(self, "GameInvitePromptClosed", player, {})
			end)
		end,
		CanSendCallInviteAsync = function(self)
			selfState(self, "CanSendCallInviteAsync")
			Sched.sleep(0.1)
			return false
		end,
	},
}

B.TextService = {
	methods = {
		GetTextSize = function(self, text, size, font, frameSize)
			selfState(self, "GetTextSize")
			argType(text, "string", 1, "GetTextSize")
			argType(size, "number", 2, "GetTextSize")
			enumArg(font, "Font", 3, "GetTextSize")
			argType(frameSize, "Vector2", 4, "GetTextSize")
			local lines, longest = 0, 0
			for line in string.gmatch(text .. "\n", "(.-)\n") do
				lines += 1
				longest = math.max(longest, utf8.len(line) or #line)
			end
			local w = longest * size * 0.5
			if frameSize.X > 0 and w > frameSize.X then
				lines += math.ceil(w / frameSize.X) - 1
				w = frameSize.X
			end
			return Vector2.new(w, lines * size)
		end,
		GetTextBoundsAsync = function(self, params)
			selfState(self, "GetTextBoundsAsync")
			instanceArg(params, 1, "GetTextBoundsAsync", "GetTextBoundsParams")
			Sched.sleep(0.02)
			local text = tostring(get(params, "Text"))
			local size = get(params, "Size")
			return Vector2.new(#text * size * 0.5, size)
		end,
	},
}

B.HttpService = {
	methods = {
		JSONEncode = function(self, value)
			selfState(self, "JSONEncode")
			local ok, out = pcall(serde.encode, "json", value, false)
			if not ok then
				raise("Can't convert to JSON: " .. tostring(out), "Invalid API arguments")
			end
			return out
		end,
		JSONDecode = function(self, text)
			selfState(self, "JSONDecode")
			argType(text, "string", 1, "JSONDecode")
			local ok, out = pcall(serde.decode, "json", text)
			if not ok then
				error("Can't parse JSON", 2)
			end
			return out
		end,
		GenerateGUID = function(self, wrap)
			selfState(self, "GenerateGUID")
			local r = Datatypes.Random.new(Sched.frameCount + 17)
			local hex = {}
			for i = 1, 32 do
				hex[i] = string.format("%X", r:NextInteger(0, 15))
			end
			local s = table.concat(hex)
			local guid = string.sub(s, 1, 8) .. "-" .. string.sub(s, 9, 12) .. "-" .. string.sub(s, 13, 16) .. "-" .. string.sub(s, 17, 20) .. "-" .. string.sub(s, 21, 32)
			if wrap == false then
				return guid
			end
			return "{" .. guid .. "}"
		end,
		UrlEncode = function(self, text)
			selfState(self, "UrlEncode")
			argType(text, "string", 1, "UrlEncode")
			return (string.gsub(text, "[^%w%-_%.~]", function(c)
				return string.format("%%%02X", string.byte(c))
			end))
		end,
		GetAsync = function(self)
			selfState(self, "GetAsync")
			raise("Http requests can only be executed by game server", "Invalid API use")
		end,
		PostAsync = function(self)
			selfState(self, "PostAsync")
			raise("Http requests can only be executed by game server", "Invalid API use")
		end,
		RequestAsync = function(self)
			selfState(self, "RequestAsync")
			raise("Http requests can only be executed by game server", "Invalid API use")
		end,
	},
}

B.CollectionService = {
	methods = {
		GetTagged = function(self, tag)
			selfState(self, "GetTagged")
			argType(tag, "string", 1, "GetTagged")
			return Inst.getTagged(tag)
		end,
		HasTag = function(self, instance, tag)
			selfState(self, "HasTag")
			instanceArg(instance, 1, "HasTag")
			argType(tag, "string", 2, "HasTag")
			local tags = S[instance].tags
			return tags ~= nil and tags[tag] == true
		end,
		AddTag = function(self, instance, tag)
			selfState(self, "AddTag")
			instanceArg(instance, 1, "AddTag")
			argType(tag, "string", 2, "AddTag")
			Inst.addTag(instance, tag)
		end,
		RemoveTag = function(self, instance, tag)
			selfState(self, "RemoveTag")
			instanceArg(instance, 1, "RemoveTag")
			argType(tag, "string", 2, "RemoveTag")
			Inst.removeTag(instance, tag)
		end,
		GetTags = function(self, instance)
			selfState(self, "GetTags")
			instanceArg(instance, 1, "GetTags")
			return instance:GetTags()
		end,
		GetAllTags = function(self)
			selfState(self, "GetAllTags")
			local out = {}
			for tag in Inst.tagged do
				table.insert(out, tag)
			end
			table.sort(out)
			return out
		end,
		GetInstanceAddedSignal = function(self, tag)
			selfState(self, "GetInstanceAddedSignal")
			argType(tag, "string", 1, "GetInstanceAddedSignal")
			return Inst.tagSignal(tag, "added")
		end,
		GetInstanceRemovedSignal = function(self, tag)
			selfState(self, "GetInstanceRemovedSignal")
			argType(tag, "string", 1, "GetInstanceRemovedSignal")
			return Inst.tagSignal(tag, "removed")
		end,
	},
}

B.Debris = {
	methods = {
		AddItem = function(self, item, lifetime)
			selfState(self, "AddItem")
			instanceArg(item, 1, "AddItem")
			argType(lifetime, "number", 2, "AddItem", true)
			Sched.after(lifetime or 10, function()
				if not S[item].destroyed then
					Inst.destroy(item)
				end
			end)
		end,
		addItem = nil,
	},
}
B.Debris.methods.addItem = B.Debris.methods.AddItem

B.Lighting = {
	methods = {
		GetMinutesAfterMidnight = function(self)
			selfState(self, "GetMinutesAfterMidnight")
			return get(self, "ClockTime") * 60
		end,
		SetMinutesAfterMidnight = function(self, minutes)
			selfState(self, "SetMinutesAfterMidnight")
			argType(minutes, "number", 1, "SetMinutesAfterMidnight")
			self.ClockTime = (minutes / 60) % 24
		end,
		GetSunDirection = function(self)
			selfState(self, "GetSunDirection")
			return Vector3.new(0, -1, 0)
		end,
		GetMoonDirection = function(self)
			selfState(self, "GetMoonDirection")
			return Vector3.new(0.3, 0.8, 0.2).Unit
		end,
	},
}

B.SoundService = {
	methods = {
		PlayLocalSound = function(self, sound)
			selfState(self, "PlayLocalSound")
			instanceArg(sound, 1, "PlayLocalSound", "Sound")
			sound:Play()
		end,
		GetListener = function(self)
			selfState(self, "GetListener")
			return Enum.ListenerType.Camera, nil
		end,
		SetListener = function(self)
			selfState(self, "SetListener")
		end,
	},
}

B.LocalizationService = {
	getters = {
		RobloxLocaleId = function()
			return "en-us"
		end,
		SystemLocaleId = function()
			return "en-us"
		end,
	},
	methods = {
		GetTranslatorForPlayerAsync = function(self)
			selfState(self, "GetTranslatorForPlayerAsync")
			Sched.sleep(0.05)
			return Inst.create("Translator")
		end,
		GetTranslatorForPlayer = function(self)
			selfState(self, "GetTranslatorForPlayer")
			return Inst.create("Translator")
		end,
		GetCountryRegionForPlayerAsync = function(self)
			selfState(self, "GetCountryRegionForPlayerAsync")
			Sched.sleep(0.05)
			return "US"
		end,
	},
}

B.Translator = {
	getters = {
		LocaleId = function()
			return "en-us"
		end,
	},
	methods = {
		Translate = function(self, context, text)
			selfState(self, "Translate")
			argType(text, "string", 2, "Translate")
			return text
		end,
		FormatByKey = function(self, key)
			selfState(self, "FormatByKey")
			argType(key, "string", 1, "FormatByKey")
			return key
		end,
	},
}

B.TeleportService = {
	methods = {
		Teleport = function(self, placeId)
			selfState(self, "Teleport")
			note("Teleport", tostring(placeId))
			Report.add("WARN", "Teleports requested", "TeleportService:Teleport(" .. tostring(placeId) .. ")", Report.callerLocation())
		end,
		TeleportAsync = function(self, placeId)
			selfState(self, "TeleportAsync")
			raise("TeleportAsync can only be called from the server", "Invalid API use")
		end,
		TeleportToPlaceInstance = function(self, placeId)
			selfState(self, "TeleportToPlaceInstance")
			note("Teleport", tostring(placeId))
			Report.add("WARN", "Teleports requested", "TeleportService:TeleportToPlaceInstance(" .. tostring(placeId) .. ")", Report.callerLocation())
		end,
		GetLocalPlayerTeleportData = function(self)
			selfState(self, "GetLocalPlayerTeleportData")
			return nil
		end,
		GetTeleportSetting = function(self)
			selfState(self, "GetTeleportSetting")
			return nil
		end,
		SetTeleportSetting = function(self)
			selfState(self, "SetTeleportSetting")
		end,
		GetArrivingTeleportGui = function(self)
			selfState(self, "GetArrivingTeleportGui")
			return nil
		end,
		SetTeleportGui = function(self)
			selfState(self, "SetTeleportGui")
		end,
	},
}

B.TextChatService = {
	methods = {
		CanUserChatAsync = function(self)
			selfState(self, "CanUserChatAsync")
			Sched.sleep(0.05)
			return true
		end,
		CanUsersChatAsync = function(self)
			selfState(self, "CanUsersChatAsync")
			Sched.sleep(0.05)
			return true
		end,
		DisplayBubble = function(self)
			selfState(self, "DisplayBubble")
		end,
	},
}

B.Teams = {
	methods = {
		GetTeams = function(self)
			local st = selfState(self, "GetTeams")
			local out = {}
			for _, c in st.children do
				if S[c].className == "Team" then
					table.insert(out, c)
				end
			end
			return out
		end,
	},
}

B.BadgeService = {
	methods = {
		UserHasBadgeAsync = function(self)
			selfState(self, "UserHasBadgeAsync")
			Sched.sleep(0.05)
			return false
		end,
		AwardBadge = function(self)
			selfState(self, "AwardBadge")
			raise("AwardBadge can only be called from the server", "Invalid API use")
		end,
	},
}

B.ProximityPromptService = {}

-- ContextActionService: actions are stored; the scenario calls them.
Services.actions = {} -- name -> { fn, inputs, location }

B.ContextActionService = {
	methods = {
		BindAction = function(self, name, fn, createTouchButton, ...)
			selfState(self, "BindAction")
			argType(name, "string", 1, "BindAction")
			argType(fn, "function", 2, "BindAction")
			argType(createTouchButton, "boolean", 3, "BindAction")
			local inputs = table.pack(...)
			for i = 1, inputs.n do
				local t = typeOf(inputs[i])
				if t ~= "EnumItem" then
					raise(string.format("invalid argument #%d to 'BindAction' (EnumItem expected, got %s)", i + 3, t), "Invalid API arguments")
				end
			end
			Services.actions[name] = { fn = fn, inputs = inputs, location = Report.callerLocation() }
		end,
		BindActionAtPriority = function(self, name, fn, createTouchButton, priority, ...)
			selfState(self, "BindActionAtPriority")
			argType(name, "string", 1, "BindActionAtPriority")
			argType(fn, "function", 2, "BindActionAtPriority")
			argType(priority, "number", 4, "BindActionAtPriority")
			Services.actions[name] = { fn = fn, inputs = table.pack(...), location = Report.callerLocation() }
		end,
		UnbindAction = function(self, name)
			selfState(self, "UnbindAction")
			argType(name, "string", 1, "UnbindAction")
			Services.actions[name] = nil
		end,
		UnbindAllActions = function(self)
			selfState(self, "UnbindAllActions")
			table.clear(Services.actions)
		end,
		GetButton = function(self, name)
			selfState(self, "GetButton")
			return nil
		end,
		GetBoundActionInfo = function(self, name)
			selfState(self, "GetBoundActionInfo")
			return if Services.actions[name] then {} else nil
		end,
		GetAllBoundActionInfo = function(self)
			selfState(self, "GetAllBoundActionInfo")
			return {}
		end,
		SetTitle = function(self)
			selfState(self, "SetTitle")
		end,
		SetDescription = function(self)
			selfState(self, "SetDescription")
		end,
		SetImage = function(self)
			selfState(self, "SetImage")
		end,
		SetPosition = function(self)
			selfState(self, "SetPosition")
		end,
	},
}

B.HapticService = {
	methods = {
		IsVibrationSupported = function(self)
			selfState(self, "IsVibrationSupported")
			return false
		end,
		IsMotorSupported = function(self)
			selfState(self, "IsMotorSupported")
			return false
		end,
		SetMotor = function(self)
			selfState(self, "SetMotor")
		end,
	},
}

--------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------

local STARTUP_SERVICES = {
	"Workspace",
	"Players",
	"Lighting",
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"SoundService",
	"Teams",
	"TextChatService",
	"LocalizationService",
	"RunService",
	"UserInputService",
	"TweenService",
	"CollectionService",
	"ContentProvider",
	"GuiService",
	"HttpService",
	"MarketplaceService",
	"SocialService",
	"TeleportService",
	"TextService",
	"ProximityPromptService",
	"Debris",
}

function Services.setup(profile)
	Services.profile = profile
	Classes.viewport = profile.viewport
	local game = Inst.create("DataModel")
	S[game].name = "StealACryptid"
	Services.game = game
	Inst.game = game
	for _, name in STARTUP_SERVICES do
		createService(name)
	end
	Classes.promptService = Services.byClass.ProximityPromptService

	-- Workspace contents
	local ws = Services.byClass.Workspace
	local terrain = Inst.create("Terrain")
	Inst.setParent(terrain, S[terrain], ws)
	local camera = Inst.create("Camera")
	S[camera].props.CFrame = CFrame.lookAt(Vector3.new(0, 20, 30), Vector3.new(0, 0, 0))
	S[camera].props.FieldOfView = 70
	Inst.setParent(camera, S[camera], ws)
	S[ws].props.CurrentCamera = camera
	S[ws].props.Gravity = 196.2

	-- StarterPlayer containers
	local sp = Services.byClass.StarterPlayer
	for _, name in { "StarterPlayerScripts", "StarterCharacterScripts" } do
		local c = Inst.create(name)
		Inst.setParent(c, S[c], sp)
	end

	-- TextChatService's standard children
	local tcs = Services.byClass.TextChatService
	local channels = Inst.create("Folder")
	S[channels].name = "TextChannels"
	Inst.setParent(channels, S[channels], tcs)
	for _, n in { "RBXGeneral", "RBXSystem" } do
		local ch = Inst.create("TextChannel")
		S[ch].name = n
		Inst.setParent(ch, S[ch], channels)
	end
	for _, cls in { "ChatWindowConfiguration", "ChatInputBarConfiguration", "BubbleChatConfiguration" } do
		if Reflect.exists(cls) then
			local c = Inst.create(cls)
			Inst.setParent(c, S[c], tcs)
		end
	end

	Sched.onFrame = onFrame
	return game
end

--- Changes the viewport size and fires what Roblox fires.
function Services.setViewport(size)
	Classes.viewport = size
	local ws = Services.byClass.Workspace
	local camera = get(ws, "CurrentCamera")
	if camera then
		Inst.changed(camera, S[camera], "ViewportSize", size)
	end
	Inst.changed(Services.byClass.GuiService, S[Services.byClass.GuiService], "TopbarInset", nil)
	-- AbsoluteSize & co. follow on the next frame (Services.pollLayout).
end

return Services
