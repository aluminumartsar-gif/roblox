--!nocheck
-- The mock Instance: a locked userdata whose every member access is checked
-- against the reflection data (reflect.luau).
--
--   * reads: implemented method > property (stored or default) > event >
--     child with that name > stub for a real-but-unimplemented method >
--     error "X is not a valid member of Class".
--   * writes: property must exist, be writable, and the value must match the
--     declared datatype (Roblox's own coercions are allowed: numbers to
--     strings, numeric strings to numbers, enum names/values to EnumItems).
--
-- Mistakes are raised as errors in the game thread, like Roblox does, and
-- also recorded right away (so a pcall can't hide them from the report).

local roblox = require("@lune/roblox")
local Reflect = require("./reflect")
local Report = require("./report")
local Sched = require("./sched")
local Signal = require("./signal")
local Typeof = require("./typeof")

local Inst = {}

local S = {} -- proxy -> state
Inst.S = S
Inst.game = nil -- the DataModel proxy (set by services.luau)
Inst.Behaviors = {} -- className -> { methods, getters, setters, init, parentChanged, propChanged }
Inst.unimplemented = {} -- "Class:Method" -> true
Inst.created = 0

local typeOf = Typeof.typeof

--------------------------------------------------------------------------
-- Raising API misuse
--------------------------------------------------------------------------

--- Raises `message` as an error at the game line that caused it, and
--- records it under `category` (a FAILURE) even if a pcall catches it.
function Inst.raise(message: string, category: string?): never
	local level, loc = Report.gameLevel()
	if not level then
		Report.add("HARNESS", "Harness errors", message, nil, debug.traceback())
		error(message, 2)
	end
	Report.add("FAIL", category or "Invalid API use", message, loc)
	Report.markReported(loc .. ": " .. message)
	error(message, level)
end
local raise = Inst.raise

--------------------------------------------------------------------------
-- Class info: reflection record + Lua behaviours along the superclass chain
--------------------------------------------------------------------------

local infoCache = {}

local function classInfo(className: string)
	local info = infoCache[className]
	if info then
		return info
	end
	local rec = Reflect.class(className)
	if not rec then
		return nil
	end
	local chain = {}
	local c = rec
	while c do
		table.insert(chain, 1, c.name)
		c = if c.superclass then Reflect.class(c.superclass) else nil
	end
	info = {
		rec = rec,
		name = className,
		methods = {},
		getters = {},
		setters = {},
		inits = {},
		parentHooks = {},
		propHooks = {},
		stubs = {},
	}
	for _, n in chain do
		local b = Inst.Behaviors[n]
		if b then
			for k, v in b.methods or {} do
				info.methods[k] = v
			end
			for k, v in b.getters or {} do
				info.getters[k] = v
			end
			for k, v in b.setters or {} do
				info.setters[k] = v
			end
			if b.init then
				table.insert(info.inits, b.init)
			end
			if b.parentChanged then
				table.insert(info.parentHooks, b.parentChanged)
			end
			if b.propChanged then
				table.insert(info.propHooks, b.propChanged)
			end
		end
	end
	infoCache[className] = info
	return info
end
Inst.classInfo = classInfo

function Inst.isA(proxy: any, className: string): boolean
	local st = S[proxy]
	return st ~= nil and st.info.rec.isA[className] == true
end

function Inst.state(proxy: any)
	return S[proxy]
end

function Inst.is(v: any): boolean
	return S[v] ~= nil
end

local function selfState(self: any, method: string)
	local st = S[self]
	if not st then
		raise("Expected ':' not '.' calling member function " .. method, "Invalid API arguments")
	end
	return st
end
Inst.selfState = selfState

--------------------------------------------------------------------------
-- Names and tree queries
--------------------------------------------------------------------------

function Inst.fullName(proxy: any): string
	local parts = {}
	local cur = proxy
	while cur do
		local st = S[cur]
		if cur == Inst.game then
			break
		end
		table.insert(parts, 1, st.name)
		cur = st.parent
	end
	return table.concat(parts, ".")
end

local function findChild(st, name: string)
	for _, c in st.children do
		if S[c].name == name then
			return c
		end
	end
	return nil
end
Inst.findChild = findChild

function Inst.inGame(proxy: any): boolean
	local cur = proxy
	while cur do
		if cur == Inst.game then
			return true
		end
		cur = S[cur].parent
	end
	return false
end

function Inst.isDescendantOf(proxy: any, ancestor: any): boolean
	local cur = S[proxy].parent
	while cur do
		if cur == ancestor then
			return true
		end
		cur = S[cur].parent
	end
	return false
end

local function descendants(st, out)
	for _, c in st.children do
		table.insert(out, c)
		descendants(S[c], out)
	end
	return out
end
Inst.descendants = function(proxy)
	return descendants(S[proxy], {})
end

--------------------------------------------------------------------------
-- Signals on instances
--------------------------------------------------------------------------

local function eventSignal(proxy, st, name: string)
	local sigs = st.signals
	if not sigs then
		sigs = {}
		st.signals = sigs
	end
	local sig = sigs[name]
	if not sig then
		sig = Signal.new(st.className .. "." .. name)
		sigs[name] = sig
	end
	return sig
end
Inst.eventSignal = function(proxy, name)
	return eventSignal(proxy, S[proxy], name)
end

--- Fires an event on an instance (only if anyone listens).
function Inst.fire(proxy: any, name: string, ...: any)
	local st = S[proxy]
	local sig = st and st.signals and st.signals[name]
	if sig then
		Signal.fire(sig, ...)
	end
end

function Inst.hasListeners(proxy: any, name: string): boolean
	local st = S[proxy]
	local sig = st and st.signals and st.signals[name]
	return sig ~= nil and Signal.hasConnections(sig)
end

local function propSignal(st, prop: string)
	local ps = st.propSignals
	if not ps then
		ps = {}
		st.propSignals = ps
	end
	local sig = ps[prop]
	if not sig then
		sig = Signal.new(st.className .. "." .. prop .. " changed")
		ps[prop] = sig
	end
	return sig
end

--- Fires GetPropertyChangedSignal(key) and Changed after a property changed.
function Inst.changed(proxy: any, st, key: string, value: any)
	local ps = st.propSignals and st.propSignals[key]
	if ps then
		Signal.fire(ps)
	end
	local ch = st.signals and st.signals.Changed
	if ch then
		if st.info.rec.isA.ValueBase then
			if key == "Value" then
				Signal.fire(ch, value)
			end
		else
			Signal.fire(ch, key)
		end
	end
	for _, hook in st.info.propHooks do
		hook(proxy, st, key, value)
	end
end

--- Instances whose AbsoluteSize/AbsolutePosition someone listens to (fired
--- on viewport resizes, see services.luau).
Inst.layoutWatchers = setmetatable({}, { __mode = "k" })

--------------------------------------------------------------------------
-- Property values
--------------------------------------------------------------------------

local DATATYPE_TYPEOF = {
	Color3uint8 = "Color3",
	OptionalCFrame = "CFrame",
	Content = "Content",
}

local NUMERIC = { Float32 = true, Float64 = true, Int32 = true, Int64 = true, int = true, float = true, double = true }
local NILLABLE = { OptionalCFrame = true, PhysicalProperties = true }
local ANYTHING = {
	BinaryString = true,
	SharedString = true,
	UniqueId = true,
	Tags = true,
	Attributes = true,
	SecurityCapabilities = true,
	MaterialColors = true,
	NetAssetRef = true,
	Unknown = true,
}

local function datatypeDefault(p)
	local dt = p.datatype
	if dt == "Bool" then
		return false
	elseif dt == "String" or dt == "ContentId" then
		return ""
	elseif NUMERIC[dt] then
		return 0
	elseif p.enumName then
		local e = Reflect.enum(p.enumName)
		return e and e.first or nil
	elseif dt == "Color3" or dt == "Color3uint8" then
		return roblox.Color3.new()
	elseif dt == "UDim2" then
		return roblox.UDim2.new()
	elseif dt == "UDim" then
		return roblox.UDim.new()
	elseif dt == "Vector2" then
		return roblox.Vector2.zero
	elseif dt == "Vector3" then
		return roblox.Vector3.zero
	elseif dt == "CFrame" then
		return roblox.CFrame.new()
	elseif dt == "Rect" then
		return roblox.Rect.new(0, 0, 0, 0)
	elseif dt == "NumberRange" then
		return roblox.NumberRange.new(0)
	elseif dt == "NumberSequence" then
		return roblox.NumberSequence.new(0)
	elseif dt == "ColorSequence" then
		return roblox.ColorSequence.new(roblox.Color3.new(1, 1, 1))
	elseif dt == "Font" then
		return roblox.Font.fromEnum(roblox.Enum.Font.Legacy)
	elseif dt == "BrickColor" then
		return roblox.BrickColor.new("Medium stone grey")
	elseif dt == "Vector2int16" then
		return roblox.Vector2int16.new(0, 0)
	elseif dt == "Vector3int16" then
		return roblox.Vector3int16.new(0, 0, 0)
	end
	return nil
end

-- Defaults the DB doesn't carry (it stores serialized names for some, and
-- leaves inherited layout properties out). Keyed by property name; enum
-- values are only used when the property's enum matches.
local EXTRA_DEFAULTS = {
	Health = 100,
	MaxHealth = 100,
	Enabled = true,
	Visible = true,
	Archivable = true,
	Localize = true,
	AutoJumpEnabled = true,
	CanLoadCharacterAppearance = true,
	DevEnableMouseLock = true,
	Neutral = true,
	CornerRadius = roblox.UDim.new(0, 8),
	CameraMaxZoomDistance = 128,
	CameraMinZoomDistance = 0.5,
	HealthDisplayDistance = 100,
	NameDisplayDistance = 100,
	MaxDistance = 10000,
	MinDistance = 10,
	FillDirection = roblox.Enum.FillDirection.Vertical,
	HorizontalAlignment = roblox.Enum.HorizontalAlignment.Left,
	VerticalAlignment = roblox.Enum.VerticalAlignment.Top,
	SortOrder = roblox.Enum.SortOrder.LayoutOrder,
	ZIndexBehavior = roblox.Enum.ZIndexBehavior.Sibling,
	Material = roblox.Enum.Material.Plastic,
	SizeConstraint = roblox.Enum.SizeConstraint.RelativeXY,
	Face = roblox.Enum.NormalId.Front,
	BorderMode = roblox.Enum.BorderMode.Outline,
	TopSurface = roblox.Enum.SurfaceType.Smooth,
	BottomSurface = roblox.Enum.SurfaceType.Smooth,
	BrickColor = roblox.BrickColor.new("Medium stone grey"),
}

-- Per-class defaults that differ from EXTRA_DEFAULTS (UIGridLayout and
-- UIPageLayout fill horizontally; UIListLayout fills vertically).
local CLASS_DEFAULTS: { [string]: { [string]: any } } = {
	UIGridLayout = {
		FillDirection = roblox.Enum.FillDirection.Horizontal,
		CellSize = roblox.UDim2.new(0, 100, 0, 100),
		CellPadding = roblox.UDim2.new(0, 5, 0, 5),
	},
	UIPageLayout = { FillDirection = roblox.Enum.FillDirection.Horizontal },
}

local function defaultValue(st, key: string, p)
	local v = st.info.rec.defaults[key]
	if v == nil then
		local perClass = CLASS_DEFAULTS[st.className]
		v = perClass and perClass[key]
	end
	if v == nil then
		v = EXTRA_DEFAULTS[key]
		if v == nil then
			v = datatypeDefault(p)
		end
	end
	if v ~= nil then
		st.props[key] = v
	end
	return v
end

--- Current value of a property (no access checks).
function Inst.get(proxy: any, key: string): any
	local st = S[proxy]
	local info = st.info
	local g = info.getters[key]
	if g then
		return g(proxy, st)
	end
	local v = st.props[key]
	if v == nil then
		local p = info.rec.props[key]
		if p then
			v = defaultValue(st, key, p)
		end
	end
	return v
end

--- Stores a property value and fires change signals if it changed.
function Inst.setRaw(proxy: any, st, key: string, value: any)
	local old = st.props[key]
	if old == nil then
		local p = st.info.rec.props[key]
		if p then
			old = defaultValue(st, key, p)
		end
	end
	if old == value then
		return
	end
	st.props[key] = value
	Inst.changed(proxy, st, key, value)
end

local function badType(p, expected: string, value: any): never
	raise(
		string.format("Unable to assign property %s. %s expected, got %s", p.name, expected, typeOf(value)),
		"Invalid property values"
	)
end

local function coerceEnum(p, value: any): any
	local info = Reflect.enum(p.enumName)
	if not info then
		return value
	end
	local t = typeOf(value)
	if t == "EnumItem" then
		local owner = Reflect.enumNameOf(value)
		if owner ~= p.enumName then
			raise(
				string.format(
					"Unable to assign property %s. EnumItem of type %s expected, got an EnumItem of type %s",
					p.name,
					p.enumName,
					tostring(owner)
				),
				"Invalid property values"
			)
		end
		return value
	elseif t == "string" then
		local item = info.byName[value]
		if item then
			return item
		end
		raise(
			string.format('Unable to assign property %s. Invalid value "%s" for enum %s', p.name, value, p.enumName),
			"Invalid property values"
		)
	elseif t == "number" then
		local item = info.byValue[value]
		if item then
			return item
		end
		raise(
			string.format("Unable to assign property %s. Invalid value %s for enum %s", p.name, tostring(value), p.enumName),
			"Invalid property values"
		)
	end
	badType(p, "EnumItem", value)
	return nil
end

--- Checks (and coerces like Roblox) a value written to property p.
function Inst.coerce(st, p, value: any): any
	local dt = p.datatype
	if dt == "String" or dt == "ContentId" then
		local t = type(value)
		if t == "string" then
			return value
		elseif t == "number" then
			return tostring(value)
		end
		badType(p, "string", value)
	elseif dt == "Bool" then
		if type(value) == "boolean" then
			return value
		end
		Report.add(
			"WARN",
			"Suspicious property values",
			string.format("%s.%s set to a %s (Roblox treats it as %s)", st.className, p.name, typeOf(value), tostring(not not value)),
			Report.callerLocation()
		)
		return not not value
	elseif NUMERIC[dt] then
		local t = type(value)
		if t == "number" then
			return value
		elseif t == "string" and tonumber(value) then
			return tonumber(value)
		end
		badType(p, "number", value)
	elseif p.enumName then
		return coerceEnum(p, value)
	elseif dt == "Ref" then
		if value == nil then
			return nil
		end
		local vs = S[value]
		if not vs then
			badType(p, "Instance", value)
		end
		if p.refClass and not vs.info.rec.isA[p.refClass] then
			raise(
				string.format("Unable to assign property %s. %s expected, got %s", p.name, p.refClass, vs.className),
				"Invalid property values"
			)
		end
		return value
	elseif ANYTHING[dt] then
		return value
	end
	if value == nil and NILLABLE[dt] then
		return nil
	end
	local expected = DATATYPE_TYPEOF[dt] or dt
	if typeOf(value) == expected then
		return value
	end
	badType(p, expected, value)
	return nil
end

--------------------------------------------------------------------------
-- Member access
--------------------------------------------------------------------------

local function stubFor(info, key: string)
	local stub = info.stubs[key]
	if stub then
		return stub
	end
	local label = info.name .. ":" .. key
	stub = function(self, ...)
		local st = selfState(self, key)
		local id = st.info.name .. ":" .. key
		if not Inst.unimplemented[id] then
			Inst.unimplemented[id] = true
		end
		Report.add("WARN", "Unimplemented API (stubbed, returned nil)", id, Report.callerLocation())
		return nil
	end
	info.stubs[key] = stub
	return stub
end

local function indexInstance(self, key)
	local st = S[self]
	local info = st.info
	local m = info.methods[key]
	if m then
		return m
	end
	local rec = info.rec
	local p = rec.props[key]
	if p then
		local g = info.getters[key]
		if g then
			return g(self, st)
		end
		local v = st.props[key]
		if v == nil then
			v = defaultValue(st, key, p)
		end
		return v
	end
	if rec.events[key] then
		return eventSignal(self, st, key)
	end
	if type(key) == "string" then
		local child = findChild(st, key)
		if child then
			return child
		end
	end
	if rec.functions[key] then
		return stubFor(info, key)
	end
	if rec.callbacks[key] then
		raise(
			string.format("%s is a callback member of %s; you can only set the callback value, get is not available", key, st.className),
			"Invalid members"
		)
	end
	local blocked = rec.blocked[key]
	if blocked then
		raise(string.format("The current thread cannot access '%s' (%s)", tostring(key), blocked), "Invalid members")
	end
	raise(string.format('%s is not a valid member of %s "%s"', tostring(key), st.className, Inst.fullName(self)), "Invalid members")
	return nil
end

local function newindexInstance(self, key, value)
	local st = S[self]
	local info = st.info
	local rec = info.rec
	local p = rec.props[key]
	if p then
		if p.readOnly then
			if p.reason then
				raise(string.format("The current thread cannot write '%s' (%s)", key, p.reason), "Read-only property writes")
			end
			raise(string.format("Unable to assign property %s. Property is read only", key), "Read-only property writes")
		end
		if st.destroyed and key ~= "Parent" then
			-- Allowed in Roblox; nothing to warn about.
		end
		local v = Inst.coerce(st, p, value)
		local s = info.setters[key]
		if s then
			s(self, st, v)
			return
		end
		Inst.setRaw(self, st, key, v)
		return
	end
	if rec.callbacks[key] then
		if value ~= nil and type(value) ~= "function" then
			raise(string.format("Unable to assign callback %s. function expected, got %s", key, typeOf(value)), "Invalid property values")
		end
		st.callbacks = st.callbacks or {}
		st.callbacks[key] = value
		return
	end
	if rec.events[key] or rec.functions[key] or info.methods[key] then
		raise(string.format("%s cannot be assigned to", tostring(key)), "Invalid members")
	end
	local blocked = rec.blocked[key]
	if blocked then
		raise(string.format("The current thread cannot write '%s' (%s)", tostring(key), blocked), "Invalid members")
	end
	raise(string.format('%s is not a valid member of %s "%s"', tostring(key), st.className, Inst.fullName(self)), "Invalid members")
end

local function tostringInstance(self)
	return S[self].name
end

--------------------------------------------------------------------------
-- Creation
--------------------------------------------------------------------------

local nextId = 0

--- Internal creation: no creatable check (services, Tweens, InputObjects).
function Inst.create(className: string): any
	local info = classInfo(className)
	if not info then
		error("smoke: unknown class " .. tostring(className), 2)
	end
	local proxy = newproxy(true)
	local mt = getmetatable(proxy)
	mt.__index = indexInstance
	mt.__newindex = newindexInstance
	mt.__tostring = tostringInstance
	mt.__metatable = "The metatable is locked"
	nextId += 1
	Inst.created += 1
	local st = {
		proxy = proxy,
		info = info,
		className = className,
		name = className,
		parent = nil,
		children = {},
		props = {},
		attrs = nil,
		tags = nil,
		signals = nil,
		propSignals = nil,
		callbacks = nil,
		destroyed = false,
		parentLocked = false,
		id = nextId,
	}
	S[proxy] = st
	Typeof.registry[proxy] = "Instance"
	for _, init in info.inits do
		init(proxy, st)
	end
	return proxy
end

--- Instance.new for game code.
function Inst.new(className: any, parent: any): any
	if type(className) ~= "string" then
		raise("invalid argument #1 to 'new' (string expected, got " .. typeOf(className) .. ")", "Invalid API arguments")
	end
	local rec = Reflect.class(className)
	if not rec then
		raise(string.format('Unable to create an Instance of type "%s" (no such class)', className), "Invalid class names")
	end
	if not rec.creatable then
		raise(string.format('Unable to create an Instance of type "%s" (not creatable)', className), "Invalid class names")
	end
	local proxy = Inst.create(className)
	local st = S[proxy]
	st.createdAt = Report.callerLocation()
	if parent ~= nil then
		proxy.Parent = parent
	end
	return proxy
end

--------------------------------------------------------------------------
-- CollectionService tags
--------------------------------------------------------------------------

Inst.tagged = {} -- tag -> { [proxy]: true }
local tagSignals = {} -- tag -> { added, removed }

function Inst.tagSignal(tag: string, which: string)
	local t = tagSignals[tag]
	if not t then
		t = {
			added = Signal.new("CollectionService.InstanceAdded(" .. tag .. ")"),
			removed = Signal.new("CollectionService.InstanceRemoved(" .. tag .. ")"),
		}
		tagSignals[tag] = t
	end
	return t[which]
end

local function fireTag(tag: string, which: string, proxy: any)
	local t = tagSignals[tag]
	if t then
		Signal.fire(t[which], proxy)
	end
end

function Inst.addTag(proxy: any, tag: string)
	local st = S[proxy]
	st.tags = st.tags or {}
	if st.tags[tag] then
		return
	end
	st.tags[tag] = true
	Inst.tagged[tag] = Inst.tagged[tag] or {}
	Inst.tagged[tag][proxy] = true
	if Inst.inGame(proxy) then
		fireTag(tag, "added", proxy)
	end
end

function Inst.removeTag(proxy: any, tag: string)
	local st = S[proxy]
	if not st.tags or not st.tags[tag] then
		return
	end
	st.tags[tag] = nil
	if Inst.tagged[tag] then
		Inst.tagged[tag][proxy] = nil
	end
	if Inst.inGame(proxy) then
		fireTag(tag, "removed", proxy)
	end
end

function Inst.getTagged(tag: string): { any }
	local out = {}
	local set = Inst.tagged[tag]
	if set then
		for proxy in set do
			if Inst.inGame(proxy) then
				table.insert(out, proxy)
			end
		end
	end
	table.sort(out, function(a, b)
		return S[a].id < S[b].id
	end)
	return out
end

--------------------------------------------------------------------------
-- WaitForChild bookkeeping (resolution happens on ChildAdded / rename)
--------------------------------------------------------------------------

Inst.pendingWaits = {} -- list of waits, see methods.WaitForChild

local function resolveWaits(parent: any, child: any)
	local name = S[child].name
	local matched = {}
	for _, w in Inst.pendingWaits do
		if not w.done and w.parent == parent and w.name == name then
			w.done = true
			if w.timer then
				Sched.cancelTimer(w.timer)
			end
			table.insert(matched, w)
		end
	end
	if #matched == 0 then
		return
	end
	local live = {}
	for _, w in Inst.pendingWaits do
		if not w.done then
			table.insert(live, w)
		end
	end
	Inst.pendingWaits = live
	for _, w in matched do
		local waited = Sched.now - w.start
		if not w.timeout and waited >= 1 then
			Report.add(
				"WARN",
				"Infinite-yield risks",
				string.format("WaitForChild(\"%s\") with no timeout on %s had to wait %.1fs (it would hang forever if the child never came)", w.name, Inst.fullName(parent), waited),
				w.location
			)
		end
		Sched.resume(w.co, child)
	end
end
Inst.resolveWaits = resolveWaits

--------------------------------------------------------------------------
-- Parenting, destroying, cloning
--------------------------------------------------------------------------

local function forSelfAndDescendants(proxy, fn)
	fn(proxy)
	for _, c in table.clone(S[proxy].children) do
		forSelfAndDescendants(c, fn)
	end
end

local function fireAncestors(start, eventName, arg)
	local cur = start
	while cur do
		Inst.fire(cur, eventName, arg)
		cur = S[cur].parent
	end
end

local function setTagPresence(proxy, entering: boolean)
	forSelfAndDescendants(proxy, function(p)
		local tags = S[p].tags
		if tags then
			for tag in tags do
				fireTag(tag, if entering then "added" else "removed", p)
			end
		end
	end)
end

function Inst.setParent(proxy: any, st, newParent: any, internal: boolean?)
	if st.parentLocked then
		raise(
			string.format(
				"The Parent property of %s is locked, current parent: NULL, new parent %s",
				st.name,
				if newParent then S[newParent].name else "NULL"
			),
			"Invalid property values"
		)
	end
	local old = st.parent
	if old == newParent then
		return
	end
	if newParent ~= nil then
		if newParent == proxy or Inst.isDescendantOf(newParent, proxy) then
			raise(
				string.format(
					"Attempt to set parent of %s to %s would result in circular reference",
					Inst.fullName(proxy),
					Inst.fullName(newParent)
				),
				"Invalid property values"
			)
		end
	end
	local wasInGame = Inst.inGame(proxy)
	if old then
		-- DescendantRemoving fires on the old ancestors before the move.
		local cur = old
		while cur do
			if Inst.hasListeners(cur, "DescendantRemoving") then
				forSelfAndDescendants(proxy, function(p)
					Inst.fire(cur, "DescendantRemoving", p)
				end)
			end
			cur = S[cur].parent
		end
		local siblings = S[old].children
		local idx = table.find(siblings, proxy)
		if idx then
			table.remove(siblings, idx)
		end
		st.parent = nil
		Inst.fire(old, "ChildRemoved", proxy)
	end
	st.parent = newParent
	if newParent then
		table.insert(S[newParent].children, proxy)
		Inst.fire(newParent, "ChildAdded", proxy)
		local cur = newParent
		while cur do
			if Inst.hasListeners(cur, "DescendantAdded") then
				forSelfAndDescendants(proxy, function(p)
					Inst.fire(cur, "DescendantAdded", p)
				end)
			end
			cur = S[cur].parent
		end
		resolveWaits(newParent, proxy)
	end
	forSelfAndDescendants(proxy, function(p)
		Inst.fire(p, "AncestryChanged", proxy, newParent)
	end)
	Inst.changed(proxy, st, "Parent", newParent)
	local nowInGame = Inst.inGame(proxy)
	if wasInGame ~= nowInGame then
		setTagPresence(proxy, nowInGame)
	end
	for _, hook in st.info.parentHooks do
		hook(proxy, st, old, newParent)
	end
end

function Inst.destroy(proxy: any)
	local st = S[proxy]
	if st.destroyed then
		return
	end
	Inst.fire(proxy, "Destroying")
	st.destroyed = true
	for _, c in table.clone(st.children) do
		Inst.destroy(c)
	end
	if st.parent then
		st.parentLocked = false
		Inst.setParent(proxy, st, nil, true)
	end
	st.parentLocked = true
	if st.signals then
		for _, sig in st.signals do
			Signal.disconnectAll(sig)
		end
	end
	if st.propSignals then
		for _, sig in st.propSignals do
			Signal.disconnectAll(sig)
		end
	end
	if st.attrSignals then
		for _, sig in st.attrSignals do
			Signal.disconnectAll(sig)
		end
	end
end

function Inst.clone(proxy: any, map: { [any]: any }?): any
	local st = S[proxy]
	if Inst.get(proxy, "Archivable") == false then
		return nil
	end
	local top = map == nil
	map = map or {}
	local copy = Inst.create(st.className)
	local cs = S[copy]
	map[proxy] = copy
	cs.name = st.name
	for k, v in st.props do
		cs.props[k] = v
	end
	if st.attrs then
		cs.attrs = table.clone(st.attrs)
	end
	if st.callbacks then
		cs.callbacks = table.clone(st.callbacks)
	end
	cs.source = st.source
	cs.sourcePath = st.sourcePath
	for _, c in st.children do
		local cc = Inst.clone(c, map)
		if cc then
			S[cc].parent = copy
			table.insert(cs.children, cc)
		end
	end
	if st.tags then
		for tag in st.tags do
			Inst.addTag(copy, tag)
		end
	end
	if top then
		-- References inside the copied tree point at the copies (PrimaryPart, ...).
		for orig, cp in map do
			local cps = S[cp]
			for k, v in cps.props do
				if S[v] and map[v] then
					cps.props[k] = map[v]
				end
			end
		end
	end
	return copy
end

--------------------------------------------------------------------------
-- Attributes
--------------------------------------------------------------------------

local ATTRIBUTE_TYPES = {
	["nil"] = true,
	boolean = true,
	number = true,
	string = true,
	UDim = true,
	UDim2 = true,
	BrickColor = true,
	Color3 = true,
	Vector2 = true,
	Vector3 = true,
	CFrame = true,
	NumberSequence = true,
	ColorSequence = true,
	NumberRange = true,
	Rect = true,
	Font = true,
	EnumItem = true,
}

local function attrSignal(st, name: string)
	st.attrSignals = st.attrSignals or {}
	local sig = st.attrSignals[name]
	if not sig then
		sig = Signal.new(st.className .. ' attribute "' .. name .. '" changed')
		st.attrSignals[name] = sig
	end
	return sig
end

function Inst.setAttribute(proxy: any, name: string, value: any)
	local st = S[proxy]
	st.attrs = st.attrs or {}
	if st.attrs[name] == value then
		return
	end
	st.attrs[name] = value
	local sig = st.attrSignals and st.attrSignals[name]
	if sig then
		Signal.fire(sig)
	end
	Inst.fire(proxy, "AttributeChanged", name)
end

--------------------------------------------------------------------------
-- Instance methods
--------------------------------------------------------------------------

local function checkString(v: any, argIndex: number, method: string)
	if type(v) ~= "string" then
		raise(
			string.format("invalid argument #%d to '%s' (string expected, got %s)", argIndex, method, typeOf(v)),
			"Invalid API arguments"
		)
	end
end

local function checkClassName(v: any, method: string)
	checkString(v, 1, method)
	if not Reflect.exists(v) then
		Report.add("WARN", "Suspicious API arguments", string.format("%s(%q): no class is called that", method, v), Report.callerLocation())
	end
end

local M = {}

function M.FindFirstChild(self, name, recursive)
	local st = selfState(self, "FindFirstChild")
	checkString(name, 1, "FindFirstChild")
	local c = findChild(st, name)
	if c or not recursive then
		return c
	end
	for _, d in descendants(st, {}) do
		if S[d].name == name then
			return d
		end
	end
	return nil
end
M.findFirstChild = M.FindFirstChild

function M.FindFirstChildOfClass(self, className)
	local st = selfState(self, "FindFirstChildOfClass")
	checkClassName(className, "FindFirstChildOfClass")
	for _, c in st.children do
		if S[c].className == className then
			return c
		end
	end
	return nil
end

function M.FindFirstChildWhichIsA(self, className, recursive)
	local st = selfState(self, "FindFirstChildWhichIsA")
	checkClassName(className, "FindFirstChildWhichIsA")
	local list = if recursive then descendants(st, {}) else st.children
	for _, c in list do
		if S[c].info.rec.isA[className] then
			return c
		end
	end
	return nil
end

function M.FindFirstDescendant(self, name)
	local st = selfState(self, "FindFirstDescendant")
	checkString(name, 1, "FindFirstDescendant")
	for _, d in descendants(st, {}) do
		if S[d].name == name then
			return d
		end
	end
	return nil
end

function M.FindFirstAncestor(self, name)
	local st = selfState(self, "FindFirstAncestor")
	checkString(name, 1, "FindFirstAncestor")
	local cur = st.parent
	while cur do
		if S[cur].name == name then
			return cur
		end
		cur = S[cur].parent
	end
	return nil
end

function M.FindFirstAncestorOfClass(self, className)
	local st = selfState(self, "FindFirstAncestorOfClass")
	checkClassName(className, "FindFirstAncestorOfClass")
	local cur = st.parent
	while cur do
		if S[cur].className == className then
			return cur
		end
		cur = S[cur].parent
	end
	return nil
end

function M.FindFirstAncestorWhichIsA(self, className)
	local st = selfState(self, "FindFirstAncestorWhichIsA")
	checkClassName(className, "FindFirstAncestorWhichIsA")
	local cur = st.parent
	while cur do
		if S[cur].info.rec.isA[className] then
			return cur
		end
		cur = S[cur].parent
	end
	return nil
end

function M.GetChildren(self)
	local st = selfState(self, "GetChildren")
	return table.clone(st.children)
end
M.getChildren = M.GetChildren
M.children = M.GetChildren

function M.GetDescendants(self)
	local st = selfState(self, "GetDescendants")
	return descendants(st, {})
end

function M.IsA(self, className)
	local st = selfState(self, "IsA")
	checkClassName(className, "IsA")
	return st.info.rec.isA[className] == true
end
M.isA = M.IsA

function M.IsDescendantOf(self, ancestor)
	selfState(self, "IsDescendantOf")
	if ancestor == nil then
		return false
	end
	if not S[ancestor] then
		raise("invalid argument #1 to 'IsDescendantOf' (Instance expected, got " .. typeOf(ancestor) .. ")", "Invalid API arguments")
	end
	return Inst.isDescendantOf(self, ancestor)
end

function M.IsAncestorOf(self, descendant)
	selfState(self, "IsAncestorOf")
	if descendant == nil then
		return false
	end
	if not S[descendant] then
		raise("invalid argument #1 to 'IsAncestorOf' (Instance expected, got " .. typeOf(descendant) .. ")", "Invalid API arguments")
	end
	return Inst.isDescendantOf(descendant, self)
end

function M.GetFullName(self)
	selfState(self, "GetFullName")
	return Inst.fullName(self)
end

function M.GetDebugId(self)
	local st = selfState(self, "GetDebugId")
	return "SMOKE_" .. st.id
end

function M.Destroy(self)
	selfState(self, "Destroy")
	Inst.destroy(self)
end
M.destroy = M.Destroy

function M.Remove(self)
	local st = selfState(self, "Remove")
	Inst.setParent(self, st, nil)
end
M.remove = M.Remove

function M.ClearAllChildren(self)
	local st = selfState(self, "ClearAllChildren")
	for _, c in table.clone(st.children) do
		Inst.destroy(c)
	end
end

function M.Clone(self)
	selfState(self, "Clone")
	return Inst.clone(self)
end
M.clone = M.Clone

function M.GetPropertyChangedSignal(self, prop)
	local st = selfState(self, "GetPropertyChangedSignal")
	checkString(prop, 1, "GetPropertyChangedSignal")
	local p = st.info.rec.props[prop]
	if not p then
		raise(string.format("%s is not a valid property name.", prop), "Invalid API arguments")
	end
	if prop == "AbsoluteSize" or prop == "AbsolutePosition" or prop == "AbsoluteContentSize" or prop == "AbsoluteCanvasSize" then
		Inst.layoutWatchers[self] = true
	end
	return propSignal(st, prop)
end

function M.GetAttribute(self, name)
	local st = selfState(self, "GetAttribute")
	checkString(name, 1, "GetAttribute")
	return st.attrs and st.attrs[name]
end

function M.GetAttributes(self)
	local st = selfState(self, "GetAttributes")
	return if st.attrs then table.clone(st.attrs) else {}
end

function M.SetAttribute(self, name, value)
	selfState(self, "SetAttribute")
	checkString(name, 1, "SetAttribute")
	if #name > 100 or not string.match(name, "^[%w_]+$") or string.sub(name, 1, 3) == "RBX" then
		raise(string.format("Attribute name '%s' is invalid (letters, digits and _ only, at most 100, not starting with RBX)", name), "Invalid API arguments")
	end
	local t = typeOf(value)
	if not ATTRIBUTE_TYPES[t] then
		raise(string.format("%s is not a supported attribute type", t), "Invalid API arguments")
	end
	Inst.setAttribute(self, name, value)
end

function M.GetAttributeChangedSignal(self, name)
	local st = selfState(self, "GetAttributeChangedSignal")
	checkString(name, 1, "GetAttributeChangedSignal")
	return attrSignal(st, name)
end

function M.AddTag(self, tag)
	selfState(self, "AddTag")
	checkString(tag, 1, "AddTag")
	Inst.addTag(self, tag)
end

function M.RemoveTag(self, tag)
	selfState(self, "RemoveTag")
	checkString(tag, 1, "RemoveTag")
	Inst.removeTag(self, tag)
end

function M.HasTag(self, tag)
	local st = selfState(self, "HasTag")
	checkString(tag, 1, "HasTag")
	return st.tags ~= nil and st.tags[tag] == true
end

function M.GetTags(self)
	local st = selfState(self, "GetTags")
	local out = {}
	if st.tags then
		for t in st.tags do
			table.insert(out, t)
		end
	end
	table.sort(out)
	return out
end

function M.GetActor(self)
	selfState(self, "GetActor")
	return nil
end

function M.GetStyled(self, prop)
	selfState(self, "GetStyled")
	return self[prop]
end

M.WaitForChild = nil -- defined below

--- WaitForChild: yields on the scheduler until the child appears.
function M.WaitForChild(self, name, timeout)
	local st = selfState(self, "WaitForChild")
	checkString(name, 1, "WaitForChild")
	if timeout ~= nil and type(timeout) ~= "number" then
		raise("invalid argument #2 to 'WaitForChild' (number expected, got " .. typeOf(timeout) .. ")", "Invalid API arguments")
	end
	local child = findChild(st, name)
	if child then
		return child
	end
	local co = coroutine.running()
	if not coroutine.isyieldable() then
		error("attempt to yield from outside a coroutine", 2)
	end
	local w = {
		co = co,
		parent = self,
		name = name,
		timeout = timeout,
		start = Sched.now,
		location = Report.callerLocation(),
		path = Inst.fullName(self) .. "." .. name,
		done = false,
	}
	if timeout then
		w.timer = Sched.after(timeout, function()
			if not w.done then
				w.done = true
				Sched.resume(co, nil)
			end
		end)
	end
	table.insert(Inst.pendingWaits, w)
	local result, abortMessage = coroutine.yield()
	if abortMessage then
		error(abortMessage, 2)
	end
	return result
end

Inst.Behaviors.Instance = {
	methods = M,
	getters = {
		Name = function(proxy, st)
			return st.name
		end,
		Parent = function(proxy, st)
			return st.parent
		end,
		ClassName = function(proxy, st)
			return st.className
		end,
	},
	setters = {
		Name = function(proxy, st, value)
			if st.name == value then
				return
			end
			st.name = value
			Inst.changed(proxy, st, "Name", value)
			if st.parent then
				resolveWaits(st.parent, proxy)
			end
		end,
		Parent = function(proxy, st, value)
			Inst.setParent(proxy, st, value)
		end,
	},
}

return Inst
