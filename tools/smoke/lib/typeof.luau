--!nocheck
-- typeof() for the mock objects. Mock instances, signals and datatypes are
-- newproxy userdata registered here with their Roblox type name; everything
-- else (Lune's Vector3, Color3, EnumItem, ...) uses the real typeof.

local Typeof = {}

Typeof.registry = setmetatable({}, { __mode = "k" }) :: { [any]: string }

local nativeTypeof = typeof

function Typeof.typeof(v: any): string
	local t = Typeof.registry[v]
	if t then
		return t
	end
	return nativeTypeof(v)
end

--- A locked userdata whose metatable is `mt` (fields are copied in).
function Typeof.proxy(typeName: string, mt: { [string]: any }): any
	local p = newproxy(true)
	local m = getmetatable(p)
	for k, v in mt do
		m[k] = v
	end
	m.__metatable = "The metatable is locked"
	Typeof.registry[p] = typeName
	return p
end

return Typeof
