--!nocheck
-- Roblox datatypes Lune doesn't have (TweenInfo, Random, DateTime,
-- RaycastParams, OverlapParams), and a checked `Enum` global whose bad item
-- names are reported like Roblox reports them.

local roblox = require("@lune/roblox")
local Inst = require("./inst")
local Reflect = require("./reflect")
local Sched = require("./sched")
local Typeof = require("./typeof")

local raise = Inst.raise
local typeOf = Typeof.typeof
local Enum = roblox.Enum

local Datatypes = {}

local function readOnlyProxy(typeName: string, fields: { [string]: any }, methods: { [string]: any }?, tostr: (() -> string)?)
	local proxy
	proxy = Typeof.proxy(typeName, {
		__index = function(_, key)
			local v = fields[key]
			if v ~= nil then
				return v
			end
			local m = methods and methods[key]
			if m then
				return m
			end
			raise(string.format("%s is not a valid member of %s", tostring(key), typeName), "Invalid members")
			return nil
		end,
		__newindex = function(_, key)
			raise(string.format("%s cannot be assigned to", tostring(key)), "Invalid members")
		end,
		__tostring = tostr or function()
			return typeName
		end,
	})
	return proxy
end

local function argCheck(v: any, expected: string, index: number, fn: string, optional: boolean?)
	if v == nil and optional then
		return
	end
	if typeOf(v) ~= expected then
		raise(
			string.format("invalid argument #%d to '%s' (%s expected, got %s)", index, fn, expected, typeOf(v)),
			"Invalid API arguments"
		)
	end
end

local function enumArg(v: any, enumName: string, index: number, fn: string)
	if v == nil then
		return
	end
	if typeOf(v) ~= "EnumItem" or Reflect.enumNameOf(v) ~= enumName then
		raise(
			string.format("invalid argument #%d to '%s' (Enum.%s expected, got %s)", index, fn, enumName, typeOf(v)),
			"Invalid API arguments"
		)
	end
end

--------------------------------------------------------------------------
-- TweenInfo
--------------------------------------------------------------------------

Datatypes.TweenInfo = {
	new = function(time, easingStyle, easingDirection, repeatCount, reverses, delayTime)
		argCheck(time, "number", 1, "TweenInfo.new", true)
		enumArg(easingStyle, "EasingStyle", 2, "TweenInfo.new")
		enumArg(easingDirection, "EasingDirection", 3, "TweenInfo.new")
		argCheck(repeatCount, "number", 4, "TweenInfo.new", true)
		argCheck(reverses, "boolean", 5, "TweenInfo.new", true)
		argCheck(delayTime, "number", 6, "TweenInfo.new", true)
		local fields = {
			Time = time or 1,
			EasingStyle = easingStyle or Enum.EasingStyle.Quad,
			EasingDirection = easingDirection or Enum.EasingDirection.Out,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
			DelayTime = delayTime or 0,
		}
		return readOnlyProxy("TweenInfo", fields, nil, function()
			return string.format("Time:%s DelayTime:%s RepeatCount:%s Reverses:%s EasingDirection:%s EasingStyle:%s",
				tostring(fields.Time), tostring(fields.DelayTime), tostring(fields.RepeatCount), tostring(fields.Reverses),
				fields.EasingDirection.Name, fields.EasingStyle.Name)
		end)
	end,
}

--- The fields of a TweenInfo proxy (for TweenService).
function Datatypes.tweenInfoFields(info: any)
	return {
		Time = info.Time,
		EasingStyle = info.EasingStyle,
		EasingDirection = info.EasingDirection,
		RepeatCount = info.RepeatCount,
		Reverses = info.Reverses,
		DelayTime = info.DelayTime,
	}
end

--------------------------------------------------------------------------
-- Random (xorshift32, deterministic)
--------------------------------------------------------------------------

local randomSeeds = 0

local function newRandom(seed: number?)
	local s
	if seed == nil then
		randomSeeds += 1
		s = 0x2545F491 + randomSeeds * 7919
	else
		s = math.floor(math.abs(seed)) % 4294967296
	end
	if s == 0 then
		s = 0x9E3779B9
	end
	local state = s
	local function nextU32()
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		return state
	end
	local function nextFloat()
		return nextU32() / 4294967296
	end
	local proxy
	local methods = {}
	function methods.NextNumber(self, min, max)
		if self ~= proxy then
			raise("Expected ':' not '.' calling member function NextNumber", "Invalid API arguments")
		end
		argCheck(min, "number", 1, "NextNumber", true)
		argCheck(max, "number", 2, "NextNumber", true)
		local lo, hi = min or 0, max or 1
		if min ~= nil and max == nil then
			raise("invalid argument #2 to 'NextNumber' (number expected, got nil)", "Invalid API arguments")
		end
		return lo + (hi - lo) * nextFloat()
	end
	function methods.NextInteger(self, min, max)
		if self ~= proxy then
			raise("Expected ':' not '.' calling member function NextInteger", "Invalid API arguments")
		end
		argCheck(min, "number", 1, "NextInteger")
		argCheck(max, "number", 2, "NextInteger")
		if max < min then
			raise("invalid argument #2 to 'NextInteger' (interval is empty)", "Invalid API arguments")
		end
		return math.floor(min) + math.floor(nextFloat() * (math.floor(max) - math.floor(min) + 1))
	end
	function methods.NextUnitVector(self)
		local x, y, z = nextFloat() * 2 - 1, nextFloat() * 2 - 1, nextFloat() * 2 - 1
		local v = roblox.Vector3.new(x, y, z)
		if v.Magnitude < 1e-6 then
			return roblox.Vector3.new(0, 1, 0)
		end
		return v.Unit
	end
	function methods.Shuffle(self, t)
		argCheck(t, "table", 1, "Shuffle")
		for i = #t, 2, -1 do
			local j = math.floor(nextFloat() * i) + 1
			t[i], t[j] = t[j], t[i]
		end
	end
	function methods.Clone(self)
		return newRandom(state)
	end
	proxy = readOnlyProxy("Random", {}, methods)
	return proxy
end

Datatypes.Random = {
	new = function(seed)
		argCheck(seed, "number", 1, "Random.new", true)
		return newRandom(seed)
	end,
}

--------------------------------------------------------------------------
-- DateTime (on the virtual clock)
--------------------------------------------------------------------------

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function newDateTime(millis: number)
	local fields = {
		UnixTimestampMillis = math.floor(millis),
		UnixTimestamp = math.floor(millis / 1000),
	}
	local methods = {}
	local function parts()
		local t = os.date("!*t", math.floor(millis / 1000))
		return {
			Year = t.year,
			Month = t.month,
			Day = t.day,
			Hour = t.hour,
			Minute = t.min,
			Second = t.sec,
			Millisecond = math.floor(millis % 1000),
		}
	end
	function methods.ToUniversalTime()
		return parts()
	end
	methods.ToLocalTime = methods.ToUniversalTime
	function methods.ToIsoDate()
		local p = parts()
		return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", p.Year, p.Month, p.Day, p.Hour, p.Minute, p.Second)
	end
	function methods.FormatUniversalTime(_, format, locale)
		argCheck(format, "string", 1, "FormatUniversalTime")
		argCheck(locale, "string", 2, "FormatUniversalTime")
		local p = parts()
		local out = format
		out = string.gsub(out, "YYYY", string.format("%04d", p.Year))
		out = string.gsub(out, "MM", string.format("%02d", p.Month))
		out = string.gsub(out, "DD", string.format("%02d", p.Day))
		out = string.gsub(out, "HH", string.format("%02d", p.Hour))
		out = string.gsub(out, "mm", string.format("%02d", p.Minute))
		out = string.gsub(out, "ss", string.format("%02d", p.Second))
		return out
	end
	methods.FormatLocalTime = methods.FormatUniversalTime
	return readOnlyProxy("DateTime", fields, methods, function()
		return methods.ToIsoDate()
	end)
end

Datatypes.DateTime = {
	now = function()
		return newDateTime((Sched.EPOCH + Sched.now) * 1000)
	end,
	fromUnixTimestamp = function(s)
		argCheck(s, "number", 1, "fromUnixTimestamp")
		return newDateTime(s * 1000)
	end,
	fromUnixTimestampMillis = function(ms)
		argCheck(ms, "number", 1, "fromUnixTimestampMillis")
		return newDateTime(ms)
	end,
	fromUniversalTime = function(y, mo, d, h, mi, s, ms)
		local days = daysFromCivil(y or 1970, mo or 1, d or 1)
		return newDateTime(((days * 86400) + (h or 0) * 3600 + (mi or 0) * 60 + (s or 0)) * 1000 + (ms or 0))
	end,
	fromLocalTime = function(y, mo, d, h, mi, s, ms)
		local days = daysFromCivil(y or 1970, mo or 1, d or 1)
		return newDateTime(((days * 86400) + (h or 0) * 3600 + (mi or 0) * 60 + (s or 0)) * 1000 + (ms or 0))
	end,
	fromIsoDate = function(iso)
		argCheck(iso, "string", 1, "fromIsoDate")
		local y, mo, d, h, mi, s = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
		if not y then
			return nil
		end
		local days = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d))
		return newDateTime(((days * 86400) + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)) * 1000)
	end,
}

--------------------------------------------------------------------------
-- RaycastParams / OverlapParams
--------------------------------------------------------------------------

local function paramsType(typeName: string, defaults: { [string]: any }, checks: { [string]: string })
	return {
		new = function()
			local values = table.clone(defaults)
			values.FilterDescendantsInstances = {}
			local proxy
			local methods = {
				AddToFilter = function(self, v)
					if typeOf(v) == "Instance" then
						table.insert(values.FilterDescendantsInstances, v)
					elseif type(v) == "table" then
						for _, x in v do
							if typeOf(x) ~= "Instance" then
								raise("AddToFilter: table may only contain Instances", "Invalid API arguments")
							end
							table.insert(values.FilterDescendantsInstances, x)
						end
					else
						raise("invalid argument #1 to 'AddToFilter' (Instance or table expected, got " .. typeOf(v) .. ")", "Invalid API arguments")
					end
				end,
			}
			proxy = Typeof.proxy(typeName, {
				__index = function(_, key)
					if values[key] ~= nil then
						local v = values[key]
						if key == "FilterDescendantsInstances" then
							return table.clone(v)
						end
						return v
					end
					local m = methods[key]
					if m then
						return m
					end
					raise(string.format("%s is not a valid member of %s", tostring(key), typeName), "Invalid members")
					return nil
				end,
				__newindex = function(_, key, value)
					local expected = checks[key]
					if not expected then
						raise(string.format("%s is not a valid member of %s", tostring(key), typeName), "Invalid members")
					end
					if key == "FilterDescendantsInstances" then
						if type(value) ~= "table" then
							raise("Unable to assign property FilterDescendantsInstances. table expected, got " .. typeOf(value), "Invalid property values")
						end
						for _, x in value do
							if typeOf(x) ~= "Instance" then
								raise("Unable to assign property FilterDescendantsInstances. Array of Instances expected", "Invalid property values")
							end
						end
						values[key] = table.clone(value)
						return
					end
					if expected:sub(1, 5) == "Enum." then
						if typeOf(value) ~= "EnumItem" or Reflect.enumNameOf(value) ~= expected:sub(6) then
							raise(string.format("Unable to assign property %s. %s expected, got %s", key, expected, typeOf(value)), "Invalid property values")
						end
					elseif typeOf(value) ~= expected then
						raise(string.format("Unable to assign property %s. %s expected, got %s", key, expected, typeOf(value)), "Invalid property values")
					end
					values[key] = value
				end,
				__tostring = function()
					return typeName
				end,
			})
			return proxy
		end,
	}
end

Datatypes.RaycastParams = paramsType("RaycastParams", {
	FilterType = Enum.RaycastFilterType.Exclude,
	IgnoreWater = false,
	CollisionGroup = "Default",
	RespectCanCollide = false,
	BruteForceAllSlow = false,
}, {
	FilterDescendantsInstances = "table",
	FilterType = "Enum.RaycastFilterType",
	IgnoreWater = "boolean",
	CollisionGroup = "string",
	RespectCanCollide = "boolean",
	BruteForceAllSlow = "boolean",
})

Datatypes.OverlapParams = paramsType("OverlapParams", {
	FilterType = Enum.RaycastFilterType.Exclude,
	CollisionGroup = "Default",
	RespectCanCollide = false,
	BruteForceAllSlow = false,
	MaxParts = 0,
}, {
	FilterDescendantsInstances = "table",
	FilterType = "Enum.RaycastFilterType",
	CollisionGroup = "string",
	RespectCanCollide = "boolean",
	BruteForceAllSlow = "boolean",
	MaxParts = "number",
})

--------------------------------------------------------------------------
-- Enum (checked)
--------------------------------------------------------------------------

local enumProxies = {}

local function enumProxy(name: string)
	local p = enumProxies[name]
	if p then
		return p
	end
	local info = Reflect.enum(name)
	local methods = {
		GetEnumItems = function()
			return info.enum:GetEnumItems()
		end,
		FromName = function(_, itemName)
			return info.byName[itemName]
		end,
		FromValue = function(_, value)
			return info.byValue[value]
		end,
	}
	p = Typeof.proxy("Enum", {
		__index = function(_, key)
			local item = info.byName[key]
			if item then
				return item
			end
			local m = methods[key]
			if m then
				return m
			end
			raise(string.format('%s is not a valid member of "Enum.%s"', tostring(key), name), "Invalid enum items")
			return nil
		end,
		__newindex = function(_, key)
			raise(string.format("%s cannot be assigned to", tostring(key)), "Invalid enum items")
		end,
		__tostring = function()
			return name
		end,
	})
	enumProxies[name] = p
	return p
end

Datatypes.Enum = Typeof.proxy("Enums", {
	__index = function(_, key)
		if key == "GetEnums" then
			return function()
				local out = {}
				for _, e in Enum:GetEnums() do
					local n = string.gsub(tostring(e), "^Enum%.", "")
					table.insert(out, enumProxy(n))
				end
				return out
			end
		end
		if type(key) ~= "string" or not Reflect.enum(key) then
			raise(string.format('%s is not a valid member of "Enum"', tostring(key)), "Invalid enum items")
		end
		return enumProxy(key)
	end,
	__newindex = function(_, key)
		raise(string.format("%s cannot be assigned to", tostring(key)), "Invalid enum items")
	end,
	__tostring = function()
		return "Enums"
	end,
})

return Datatypes
