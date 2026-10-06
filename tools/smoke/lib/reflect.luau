--!nocheck
-- What exists in Roblox, per class.
--
--   * Lune's reflection database (roblox.getReflectionDatabase()): classes,
--     superclasses, creatable/service tags, every property with its datatype,
--     ReadOnly/NotScriptable tags, and real default values.
--   * Roblox's API dump (tools/.lune/API-Dump.json, downloaded by run.sh):
--     events, methods and callbacks (the DB has none), plus each member's
--     script security, so a LocalScript can't use what Roblox wouldn't let it.

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local fs = require("@lune/fs")

local Reflect = {}

local db = roblox.getReflectionDatabase()
local Enum = roblox.Enum

Reflect.dbVersion = tostring(db.Version)
Reflect.apiVersion = "?"

type ApiClass = {
	name: string,
	superclass: string?,
	tags: { [string]: boolean },
	props: { [string]: any },
	events: { [string]: any },
	functions: { [string]: any },
	callbacks: { [string]: any },
}

local api: { [string]: ApiClass } = {}
local dbClassNames: { [string]: boolean } = {}
for _, name in db:GetClassNames() do
	dbClassNames[name] = true
end

local function securityOk(sec: any, which: string): boolean
	if sec == nil then
		return true
	end
	if type(sec) == "string" then
		return sec == "None"
	end
	return sec[which] == "None"
end

local function tagSet(list: { string }?): { [string]: boolean }
	local s = {}
	if list then
		for _, t in list do
			if type(t) == "string" then
				s[t] = true
			end
		end
	end
	return s
end

function Reflect.loadApiDump(path: string)
	local raw = serde.decode("json", fs.readFile(path))
	for _, c in raw.Classes do
		local rec: ApiClass = {
			name = c.Name,
			superclass = if c.Superclass ~= "<<<ROOT>>>" then c.Superclass else nil,
			tags = tagSet(c.Tags),
			props = {},
			events = {},
			functions = {},
			callbacks = {},
		}
		for _, m in c.Members do
			local tags = tagSet(m.Tags)
			if m.MemberType == "Property" then
				rec.props[m.Name] = { valueType = m.ValueType, security = m.Security, tags = tags }
			elseif m.MemberType == "Event" then
				rec.events[m.Name] = { security = m.Security, tags = tags }
			elseif m.MemberType == "Function" then
				rec.functions[m.Name] = { security = m.Security, tags = tags, yields = tags.Yields == true }
			elseif m.MemberType == "Callback" then
				rec.callbacks[m.Name] = { security = m.Security, tags = tags }
			end
		end
		api[c.Name] = rec
	end
end

local PRIMITIVES = {
	bool = "Bool",
	int = "Int32",
	int64 = "Int64",
	float = "Float32",
	double = "Float64",
	string = "String",
}

--- DB-style datatype ("Color3", "Enum.Font", "Ref", "String", ...) for an
--- API dump ValueType, plus the class a Ref must be.
local function apiDatatype(vt: any): (string, string?)
	if not vt then
		return "Unknown", nil
	end
	if vt.Category == "Primitive" then
		return PRIMITIVES[vt.Name] or vt.Name, nil
	elseif vt.Category == "Enum" then
		return "Enum." .. vt.Name, nil
	elseif vt.Category == "Class" then
		return "Ref", vt.Name
	end
	return vt.Name, nil
end

export type PropRec = {
	name: string,
	owner: string,
	datatype: string,
	enumName: string?,
	refClass: string?,
	readable: boolean,
	writable: boolean,
	readOnly: boolean,
	reason: string?,
}

export type ClassRec = {
	name: string,
	superclass: string?,
	isA: { [string]: boolean },
	creatable: boolean,
	service: boolean,
	exists: boolean,
	props: { [string]: PropRec },
	events: { [string]: boolean },
	functions: { [string]: { yields: boolean } },
	callbacks: { [string]: boolean },
	blocked: { [string]: string }, -- member -> why a game script can't use it
	defaults: { [string]: any },
}

local cache: { [string]: ClassRec | false } = {}

local function superOf(name: string): string?
	if dbClassNames[name] then
		local s = db:GetClass(name).Superclass
		if s and s ~= "" then
			return s
		end
	end
	local a = api[name]
	return a and a.superclass or nil
end

function Reflect.exists(name: string): boolean
	return dbClassNames[name] == true or api[name] ~= nil
end

function Reflect.class(name: string): ClassRec?
	local hit = cache[name]
	if hit ~= nil then
		return hit or nil
	end
	if not Reflect.exists(name) then
		cache[name] = false
		return nil
	end
	local parentName = superOf(name)
	local parent = if parentName then Reflect.class(parentName) else nil

	local rec: ClassRec = {
		name = name,
		superclass = parentName,
		isA = {},
		creatable = true,
		service = false,
		exists = true,
		props = {},
		events = {},
		functions = {},
		callbacks = {},
		blocked = {},
		defaults = {},
	}
	if parent then
		for k in parent.isA do
			rec.isA[k] = true
		end
		for k, v in parent.props do
			rec.props[k] = v
		end
		for k, v in parent.events do
			rec.events[k] = v
		end
		for k, v in parent.functions do
			rec.functions[k] = v
		end
		for k, v in parent.callbacks do
			rec.callbacks[k] = v
		end
		for k, v in parent.blocked do
			rec.blocked[k] = v
		end
	end
	rec.isA[name] = true

	local dbc = if dbClassNames[name] then db:GetClass(name) else nil
	local apc = api[name]

	-- Creatable / service
	local tags = {}
	if dbc then
		for _, t in dbc.Tags do
			tags[t] = true
		end
	end
	if apc then
		for t in apc.tags do
			tags[t] = true
		end
	end
	rec.service = tags.Service == true
	rec.creatable = not (tags.NotCreatable or tags.Service)

	-- Properties: union of the DB's and the API dump's at this level.
	local names: { [string]: boolean } = {}
	if dbc then
		for pname in dbc.Properties do
			names[pname] = true
		end
	end
	if apc then
		for pname in apc.props do
			names[pname] = true
		end
	end
	for pname in names do
		local dp = dbc and dbc.Properties[pname]
		local ap = apc and apc.props[pname]
		local datatype, refClass
		if dp then
			datatype = dp.Datatype
		end
		if ap then
			local adt, aref = apiDatatype(ap.valueType)
			datatype = datatype or adt
			refClass = aref
		end
		local readable, writable, readOnly, reason = true, true, false, nil
		if ap then
			if ap.tags.NotScriptable then
				readable, writable, reason = false, false, "not scriptable"
			else
				readable = securityOk(ap.security, "Read")
				writable = securityOk(ap.security, "Write")
				if not readable then
					reason = "lacking capability (" .. tostring(type(ap.security) == "table" and ap.security.Read or ap.security) .. ")"
				end
				if ap.tags.ReadOnly then
					readOnly = true
				end
			end
		else
			-- Only the DB knows it: trust its scriptability.
			local s = dp.Scriptability
			if s == "None" or s == "Custom" then
				readable, writable, reason = false, false, "not scriptable"
			elseif s == "Read" then
				readOnly = true
			end
		end
		if dp then
			for _, t in dp.Tags do
				if t == "ReadOnly" then
					readOnly = true
				end
			end
		end
		if not readable then
			rec.blocked[pname] = reason or "not accessible"
			rec.props[pname] = nil
		else
			rec.blocked[pname] = nil
			local enumName = if string.sub(datatype, 1, 5) == "Enum." then string.sub(datatype, 6) else nil
			rec.props[pname] = {
				name = pname,
				owner = name,
				datatype = datatype,
				enumName = enumName,
				refClass = if refClass and refClass ~= "Instance" then refClass else nil,
				readable = true,
				writable = writable and not readOnly,
				readOnly = readOnly or not writable,
				reason = if not writable then "lacking capability" else nil,
			}
		end
	end

	if apc then
		for ename, e in apc.events do
			if securityOk(e.security, "Read") and not e.tags.NotScriptable then
				rec.events[ename] = true
				rec.blocked[ename] = nil
			else
				rec.events[ename] = nil
				rec.blocked[ename] = "lacking capability (" .. tostring(e.security) .. ")"
			end
		end
		for fname, f in apc.functions do
			if securityOk(f.security, "Read") and not f.tags.NotScriptable then
				rec.functions[fname] = { yields = f.yields }
				rec.blocked[fname] = nil
			else
				rec.functions[fname] = nil
				rec.blocked[fname] = "lacking capability (" .. tostring(f.security) .. ")"
			end
		end
		for cname, c in apc.callbacks do
			if securityOk(c.security, "Read") and not c.tags.NotScriptable then
				rec.callbacks[cname] = true
				rec.blocked[cname] = nil
			else
				rec.callbacks[cname] = nil
				rec.blocked[cname] = "lacking capability (" .. tostring(c.security) .. ")"
			end
		end
	end

	-- Real default values for this exact class.
	if dbc then
		local ok, defaults = pcall(function()
			return dbc.DefaultProperties
		end)
		if ok and defaults then
			for k, v in defaults do
				rec.defaults[k] = v
			end
		end
	end

	cache[name] = rec
	return rec
end

--------------------------------------------------------------------------
-- Enums
--------------------------------------------------------------------------

local enumCache: { [string]: any } = {}

--- { byName, byValue, first, enum } for an enum name, or nil if unknown.
function Reflect.enum(enumName: string): any?
	local hit = enumCache[enumName]
	if hit ~= nil then
		return hit or nil
	end
	local ok, e = pcall(function()
		return Enum[enumName]
	end)
	if not ok or e == nil then
		enumCache[enumName] = false
		return nil
	end
	local info = { enum = e, byName = {}, byValue = {}, first = nil, name = enumName }
	local items = e:GetEnumItems()
	table.sort(items, function(a, b)
		return a.Value < b.Value
	end)
	for _, item in items do
		info.byName[item.Name] = item
		info.byValue[item.Value] = item
	end
	info.first = items[1]
	enumCache[enumName] = info
	return info
end

--- The name of the enum an EnumItem belongs to.
function Reflect.enumNameOf(item: any): string?
	local ok, t = pcall(function()
		return item.EnumType
	end)
	if not ok then
		return nil
	end
	local s = tostring(t)
	return (string.gsub(s, "^Enum%.", ""))
end

return Reflect
