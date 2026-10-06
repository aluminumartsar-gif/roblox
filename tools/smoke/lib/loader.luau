--!nocheck
-- Builds the data model from default.project.json the way Rojo would, and
-- runs scripts: every script is compiled with Lune's Luau and a custom
-- environment, so `game`, `script`, `Instance`, `task`, `require`, `print`,
-- `typeof`, ... are the mocks.
--
-- Rojo naming: X.client.luau -> LocalScript X, X.server.luau -> Script X,
-- X.luau -> ModuleScript X, a folder with init(.client|.server).luau becomes
-- that script with the folder's other files as children.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Classes = require("./classes")
local Datatypes = require("./datatypes")
local Inst = require("./inst")
local Report = require("./report")
local Sched = require("./sched")
local Services = require("./services")
local Typeof = require("./typeof")
local Util = require("./util")

local S = Inst.S
local raise = Inst.raise
local typeOf = Typeof.typeof

local Loader = {}

Loader.root = "" -- absolute repo root, with trailing slash
Loader.verbose = false
Loader.skipped = {} -- project paths that don't exist (e.g. the git-ignored UI kit)

--------------------------------------------------------------------------
-- Building instances from files
--------------------------------------------------------------------------

local function abs(rel: string): string
	return Loader.root .. rel
end

local SCRIPT_SUFFIXES = {
	{ ".server.luau", "Script" },
	{ ".server.lua", "Script" },
	{ ".client.luau", "LocalScript" },
	{ ".client.lua", "LocalScript" },
	{ ".luau", "ModuleScript" },
	{ ".lua", "ModuleScript" },
}

local function classify(fileName: string): (string?, string?)
	for _, pair in SCRIPT_SUFFIXES do
		if Util.endsWith(fileName, pair[1]) then
			return pair[2], string.sub(fileName, 1, #fileName - #pair[1])
		end
	end
	if Util.endsWith(fileName, ".meta.json") or Util.endsWith(fileName, ".project.json") then
		return nil, nil
	end
	if Util.endsWith(fileName, ".model.json") then
		return "ModelJson", string.sub(fileName, 1, #fileName - 11)
	end
	if Util.endsWith(fileName, ".json") then
		return "JsonModule", string.sub(fileName, 1, #fileName - 5)
	end
	if Util.endsWith(fileName, ".txt") then
		return "StringValue", string.sub(fileName, 1, #fileName - 4)
	end
	return nil, nil
end

local function newScript(className: string, name: string, relPath: string)
	local inst = Inst.create(className)
	local st = S[inst]
	st.name = name
	st.source = fs.readFile(abs(relPath))
	st.sourcePath = relPath
	return inst
end

local function parentTo(child, parent)
	if parent then
		Inst.setParent(child, S[child], parent, true)
	end
end

--- Builds the instance for a file or directory (repo-relative path).
function Loader.buildPath(relPath: string, name: string?, parent: any?): any?
	local full = abs(relPath)
	if fs.isDir(full) then
		local entries = fs.readDir(full)
		table.sort(entries)
		local container
		for _, initName in { "init.server.luau", "init.server.lua", "init.client.luau", "init.client.lua", "init.luau", "init.lua" } do
			if table.find(entries, initName) then
				local className = classify(initName)
				container = newScript(className, name or relPath:match("([^/]+)$"), relPath .. "/" .. initName)
				break
			end
		end
		if not container then
			container = Inst.create("Folder")
			S[container].name = name or relPath:match("([^/]+)$")
		end
		parentTo(container, parent)
		for _, entry in entries do
			if string.match(entry, "^init%.") then
				continue
			end
			local childRel = relPath .. "/" .. entry
			if fs.isDir(abs(childRel)) then
				Loader.buildPath(childRel, entry, container)
			else
				Loader.buildFile(childRel, entry, container)
			end
		end
		return container
	elseif fs.isFile(full) then
		local fileName = relPath:match("([^/]+)$")
		return Loader.buildFile(relPath, fileName, parent, name)
	end
	table.insert(Loader.skipped, relPath)
	return nil
end

function Loader.buildFile(relPath: string, fileName: string, parent: any?, overrideName: string?): any?
	local className, baseName = classify(fileName)
	if not className then
		return nil
	end
	local name = overrideName or baseName
	local inst
	if className == "JsonModule" then
		inst = Inst.create("ModuleScript")
		S[inst].name = name
		S[inst].jsonPath = relPath
		S[inst].sourcePath = relPath
	elseif className == "StringValue" then
		inst = Inst.create("StringValue")
		S[inst].name = name
		S[inst].props.Value = fs.readFile(abs(relPath))
	elseif className == "ModelJson" then
		table.insert(Loader.skipped, relPath .. " (.model.json is not supported by the smoke harness)")
		return nil
	else
		inst = newScript(className, name, relPath)
	end
	parentTo(inst, parent)
	return inst
end

local function applyProperties(inst, props)
	for k, v in props do
		if type(v) ~= "table" then
			pcall(function()
				Inst.setRaw(inst, S[inst], k, v)
			end)
		end
	end
end

--- Applies a project.json node to an existing instance (a service).
function Loader.applyNode(node: { [string]: any }, inst: any)
	if node["$properties"] then
		applyProperties(inst, node["$properties"])
	end
	for _, key in Util.sortedKeys(node) do
		if string.sub(key, 1, 1) == "$" then
			continue
		end
		local child = node[key]
		local created
		if child["$path"] then
			created = Loader.buildPath(child["$path"], key, inst)
		elseif child["$className"] then
			created = Inst.create(child["$className"])
			S[created].name = key
			parentTo(created, inst)
		else
			-- A service under the DataModel, or an existing child.
			created = Services.byClass[key] or Inst.findChild(S[inst], key)
			if not created then
				created = Inst.create("Folder")
				S[created].name = key
				parentTo(created, inst)
			end
		end
		if created then
			Loader.applyNode(child, created)
		end
	end
end

--------------------------------------------------------------------------
-- Realms, environments, require
--------------------------------------------------------------------------

local function locationOf(message: string): (string?, string)
	return Report.splitLocation(message)
end

local MODULE_ERROR = "Requested module experienced an error while loading"
local MODULE_RECURSIVE = "Requested module was required recursively"

local function noteCaught(err: any)
	local message = tostring(err)
	if message == MODULE_ERROR or string.find(message, MODULE_ERROR, 1, true) or string.find(message, "[smoke-abort]", 1, true) then
		return
	end
	local loc, text = locationOf(message)
	Report.add("NOTE", "Errors caught by pcall in game code", text, loc or Report.callerLocation())
end

local nativePcall = pcall
local nativeXpcall = xpcall

local function gamePcall(f, ...)
	local results = table.pack(nativePcall(f, ...))
	if not results[1] then
		noteCaught(results[2])
	end
	return table.unpack(results, 1, results.n)
end

local function gameXpcall(f, handler, ...)
	if type(handler) ~= "function" then
		return nativeXpcall(f, handler, ...)
	end
	return nativeXpcall(f, function(e)
		noteCaught(e)
		return handler(e)
	end, ...)
end

local function joinArgs(...): string
	local n = select("#", ...)
	local parts = table.create(n)
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	return table.concat(parts, " ")
end

Loader.onPrint = nil -- function(kind, text, loc)

local function gamePrint(...)
	local text = joinArgs(...)
	local loc = Report.callerLocation()
	Report.log("print", text, loc)
	if Loader.onPrint then
		Loader.onPrint("print", text, loc)
	end
end

local function gameWarn(...)
	local text = joinArgs(...)
	local loc = Report.callerLocation()
	Report.log("warn", text, loc)
	if Loader.onPrint then
		Loader.onPrint("warn", text, loc)
	end
end

local function checkWaitArg(t: any, fn: string)
	if t ~= nil and type(t) ~= "number" then
		raise("invalid argument #1 to '" .. fn .. "' (number expected, got " .. typeOf(t) .. ")", "Invalid API arguments")
	end
end

local taskLib = table.freeze({
	wait = function(t)
		checkWaitArg(t, "wait")
		return Sched.wait(t)
	end,
	spawn = function(f, ...)
		return Sched.spawn(f, ...)
	end,
	defer = function(f, ...)
		return Sched.defer(f, ...)
	end,
	delay = function(t, f, ...)
		checkWaitArg(t, "delay")
		return Sched.delay(t, f, ...)
	end,
	cancel = function(co)
		return Sched.cancel(co)
	end,
	synchronize = function() end,
	desynchronize = function() end,
})

local osLib = table.freeze({
	time = function(t)
		if t ~= nil then
			return os.time(t)
		end
		return math.floor(Sched.EPOCH + Sched.now)
	end,
	clock = function()
		return Sched.CLOCK_BASE + Sched.now
	end,
	date = function(format, t)
		return os.date(format or "%c", t or math.floor(Sched.EPOCH + Sched.now))
	end,
	difftime = os.difftime,
})

local debugLib = table.freeze({
	traceback = debug.traceback,
	info = debug.info,
	profilebegin = function() end,
	profileend = function() end,
	setmemorycategory = function()
		return ""
	end,
	resetmemorycategory = function() end,
	dumpcodesize = function() end,
})

local userSettings = nil
local function getUserSettings()
	if not userSettings then
		userSettings = Inst.create("UserSettings")
		local ugs = Inst.create("UserGameSettings")
		Inst.setParent(ugs, S[ugs], userSettings)
		Inst.Behaviors.UserSettings = Inst.Behaviors.UserSettings or {}
	end
	return userSettings
end
Inst.Behaviors.UserSettings = {
	methods = {
		GetService = function(self, name)
			Inst.selfState(self, "GetService")
			if name == "UserGameSettings" then
				return Inst.findChild(S[self], "UserGameSettings")
			end
			raise("'" .. tostring(name) .. "' is not a valid UserSettings service", "Invalid services")
		end,
	},
}
Inst.Behaviors.UserSettings.methods.GetService = Inst.Behaviors.UserSettings.methods.GetService

local globalSettings = nil
local function getGlobalSettings()
	if not globalSettings then
		globalSettings = Inst.create("GlobalSettings")
		for name, className in { Rendering = "RenderSettings", Physics = "PhysicsSettings", Network = "NetworkSettings" } do
			if Inst.classInfo(className) then
				local c = Inst.create(className)
				S[c].name = name
				Inst.setParent(c, S[c], globalSettings)
			end
		end
	end
	return globalSettings
end

local FROZEN = {
	TweenInfo = table.freeze(table.clone(Datatypes.TweenInfo)),
	Random = table.freeze(table.clone(Datatypes.Random)),
	DateTime = table.freeze(table.clone(Datatypes.DateTime)),
	RaycastParams = table.freeze(table.clone(Datatypes.RaycastParams)),
	OverlapParams = table.freeze(table.clone(Datatypes.OverlapParams)),
}

local function makeGlobals(realm)
	local g = {
		-- Lua
		assert = assert,
		error = error,
		getmetatable = getmetatable,
		setmetatable = setmetatable,
		ipairs = ipairs,
		pairs = pairs,
		next = next,
		select = select,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		typeof = typeOf,
		rawget = rawget,
		rawset = rawset,
		rawequal = rawequal,
		rawlen = rawlen,
		unpack = table.unpack,
		newproxy = newproxy,
		gcinfo = gcinfo,
		getfenv = getfenv,
		setfenv = setfenv,
		pcall = gamePcall,
		xpcall = gameXpcall,
		collectgarbage = function(opt)
			if opt ~= "count" then
				error("collectgarbage must be called with 'count'", 2)
			end
			return gcinfo()
		end,
		print = gamePrint,
		warn = gameWarn,
		string = string,
		table = table,
		math = math,
		coroutine = coroutine,
		utf8 = utf8,
		bit32 = bit32,
		buffer = buffer,
		vector = vector,
		os = osLib,
		debug = debugLib,
		_VERSION = "Luau",
		-- Roblox
		game = Services.game,
		Game = Services.game,
		workspace = Services.byClass.Workspace,
		Workspace = Services.byClass.Workspace,
		script = nil,
		plugin = nil,
		shared = realm.shared,
		task = taskLib,
		wait = function(t)
			checkWaitArg(t, "wait")
			local waited = Sched.wait(math.max(tonumber(t) or 0.03, 0.03))
			return waited, Sched.now
		end,
		delay = function(t, f)
			checkWaitArg(t, "delay")
			Sched.delay(t, f)
		end,
		spawn = function(f)
			Sched.delay(0, f)
		end,
		tick = function()
			return Sched.EPOCH + Sched.now
		end,
		time = function()
			return Sched.now
		end,
		elapsedTime = function()
			return Sched.now
		end,
		version = function()
			return "0.700.0.7000000"
		end,
		printidentity = function()
			gamePrint("Current identity is 2")
		end,
		settings = getGlobalSettings,
		UserSettings = getUserSettings,
		stats = function()
			return nil
		end,
		Instance = table.freeze({
			new = Inst.new,
			fromExisting = function(inst)
				if not Inst.is(inst) then
					raise("invalid argument #1 to 'fromExisting' (Instance expected, got " .. typeOf(inst) .. ")", "Invalid API arguments")
				end
				return Inst.clone(inst)
			end,
		}),
		Enum = Datatypes.Enum,
		TweenInfo = FROZEN.TweenInfo,
		Random = FROZEN.Random,
		DateTime = FROZEN.DateTime,
		RaycastParams = FROZEN.RaycastParams,
		OverlapParams = FROZEN.OverlapParams,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Vector3int16 = roblox.Vector3int16,
		Vector2int16 = roblox.Vector2int16,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		BrickColor = roblox.BrickColor,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Rect = roblox.Rect,
		Ray = roblox.Ray,
		Region3 = roblox.Region3,
		Region3int16 = roblox.Region3int16,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		PhysicalProperties = roblox.PhysicalProperties,
		Faces = roblox.Faces,
		Axes = roblox.Axes,
		Font = roblox.Font,
		Content = roblox.Content,
	}
	g._G = realm.G
	g.require = realm.require
	return g
end

--- A script realm: its own module cache, _G and shared.
function Loader.newRealm(name: string, isGame: boolean)
	local realm = { name = name, cache = {}, shared = {}, G = {}, isGame = isGame }
	local chains = setmetatable({}, { __mode = "k" }) -- thread -> list of modules being required

	local function compile(inst)
		local st = S[inst]
		if st.jsonPath then
			local data = serde.decode("json", fs.readFile(abs(st.jsonPath)))
			return function()
				return data
			end
		end
		local env = setmetatable({ script = inst }, { __index = realm.globals })
		local ok, fn = nativePcall(luau.load, st.source, {
			debugName = "@" .. (st.sourcePath or Inst.fullName(inst)),
			environment = env,
			injectGlobals = false,
		})
		if not ok then
			local msg = tostring(fn)
			local loc, text = Report.splitLocation((string.gsub(msg, '^%[string "([^"]+)"%]', "%1")))
			Report.add(if isGame then "FAIL" else "HARNESS", "Syntax errors", text, loc or st.sourcePath)
			return nil, msg
		end
		return fn
	end
	realm.compile = compile

	function realm.require(target)
		if not Inst.is(target) then
			if type(target) == "number" then
				raise("require(assetId) is not supported in this smoke harness (and not on the client)", "Invalid API arguments")
			end
			raise("Attempted to call require with invalid argument(s).", "Invalid API arguments")
		end
		local st = S[target]
		if st.className ~= "ModuleScript" then
			raise("Attempted to call require with invalid argument(s). (" .. Inst.fullName(target) .. " is a " .. st.className .. ")", "Invalid API arguments")
		end
		local co = coroutine.running()
		local chain = chains[co]
		local entry = realm.cache[target]
		if entry then
			if entry.state == "loaded" then
				return entry.value
			elseif entry.state == "failed" then
				realm.lastFailure = entry
				error(MODULE_ERROR, 2)
			end
			-- loading
			if chain and table.find(chain, target) then
				local names = {}
				local startIdx = table.find(chain, target)
				for i = startIdx, #chain do
					table.insert(names, S[chain[i]].sourcePath or Inst.fullName(chain[i]))
				end
				table.insert(names, st.sourcePath or Inst.fullName(target))
				Report.add(
					if isGame then "FAIL" else "HARNESS",
					"Require cycles",
					table.concat(names, " -> "),
					Report.callerLocation()
				)
				error(MODULE_RECURSIVE, 2)
			end
			-- Another thread is loading it: wait for it to finish.
			table.insert(entry.waiters, co)
			coroutine.yield()
			if entry.state == "loaded" then
				return entry.value
			end
			error(MODULE_ERROR, 2)
		end
		entry = { state = "loading", waiters = {}, path = st.sourcePath or Inst.fullName(target) }
		realm.cache[target] = entry
		local fn, compileError = compile(target)
		local function finish(state, value, cause)
			entry.state = state
			entry.value = value
			entry.cause = cause
			local waiters = entry.waiters
			entry.waiters = {}
			for _, w in waiters do
				Sched.defer(w)
			end
		end
		if not fn then
			finish("failed", nil, "syntax error: " .. tostring(compileError))
			realm.lastFailure = entry
			error(MODULE_ERROR, 2)
		end
		chain = chain or {}
		chains[co] = chain
		table.insert(chain, target)
		local tb = nil
		local results = table.pack(nativeXpcall(fn, function(e)
			tb = debug.traceback(tostring(e), 2)
			return e
		end))
		table.remove(chain)
		if not results[1] then
			local message = tostring(results[2])
			local cause
			if string.find(message, MODULE_ERROR, 1, true) and realm.lastFailure then
				cause = realm.lastFailure.cause
				entry.via = realm.lastFailure.path
			else
				local loc, text = Report.splitLocation(message)
				cause = (if loc then loc .. ": " else "") .. text
				if not string.find(message, "[smoke-abort]", 1, true) then
					local frames = Report.gameFrames(tb)
					Report.add(
						if isGame then "FAIL" else "HARNESS",
						"Module load errors",
						entry.path .. " errored while loading: " .. text,
						loc or Report.frameLocation(frames[1]),
						if #frames > 0 then table.concat(frames, "\n") else nil
					)
					Report.markReported(message)
				end
			end
			finish("failed", nil, cause)
			realm.lastFailure = entry
			error(MODULE_ERROR, 2)
		end
		if results.n ~= 2 then
			finish("failed", nil, "module returned " .. tostring(results.n - 1) .. " values")
			Report.add(if isGame then "FAIL" else "HARNESS", "Module load errors", entry.path .. ": Module code did not return exactly one value", entry.path)
			realm.lastFailure = entry
			error("Module code did not return exactly one value", 2)
		end
		finish("loaded", results[2], nil)
		return results[2]
	end

	realm.globals = makeGlobals(realm)
	return realm
end

--- Why a module failed to load (root cause), if it did.
function Loader.failureOf(realm, target): string?
	local entry = realm.cache[target]
	if entry and entry.state == "failed" then
		return entry.cause, entry.via
	end
	return nil
end

--- Runs a LocalScript/Script in a new game thread.
function Loader.runScript(realm, inst)
	local fn = realm.compile(inst)
	if not fn then
		return
	end
	Sched.run(fn, (S[inst].sourcePath or Inst.fullName(inst)))
end

return Loader
