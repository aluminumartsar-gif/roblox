--!nocheck
-- Small helpers shared by the smoke harness modules.

local Util = {}

function Util.sortedKeys(t: { [any]: any }): { any }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

function Util.startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

function Util.endsWith(s: string, suffix: string): boolean
	return suffix == "" or string.sub(s, -#suffix) == suffix
end

function Util.trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

function Util.join(...: string): string
	local parts = {}
	for i = 1, select("#", ...) do
		local p = select(i, ...)
		if p and p ~= "" then
			table.insert(parts, p)
		end
	end
	local s = table.concat(parts, "/")
	s = string.gsub(s, "//+", "/")
	return s
end

-- Short human-readable rendering of a value (remote call logs, reports).
function Util.show(v: any, depth: number?): string
	depth = depth or 0
	local t = typeof(v)
	if t == "string" then
		if #v > 60 then
			v = string.sub(v, 1, 57) .. "..."
		end
		return string.format("%q", v)
	elseif t == "table" then
		if depth >= 2 then
			return "{...}"
		end
		local parts = {}
		local n = 0
		for k, x in v do
			n += 1
			if n > 8 then
				table.insert(parts, "...")
				break
			end
			if type(k) == "number" then
				table.insert(parts, Util.show(x, depth + 1))
			else
				table.insert(parts, tostring(k) .. "=" .. Util.show(x, depth + 1))
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif t == "Instance" then
		return "<" .. tostring(v) .. ">"
	elseif t == "nil" or t == "boolean" or t == "number" then
		return tostring(v)
	end
	return t .. "(" .. tostring(v) .. ")"
end

function Util.showArgs(args: { any }, n: number?): string
	local parts = {}
	for i = 1, n or #args do
		table.insert(parts, Util.show(args[i]))
	end
	return table.concat(parts, ", ")
end

function Util.deepCopy(v: any, seen: { [any]: any }?): any
	if type(v) ~= "table" then
		return v
	end
	seen = seen or {}
	if seen[v] then
		return seen[v]
	end
	local out = {}
	seen[v] = out
	for k, x in v do
		out[Util.deepCopy(k, seen)] = Util.deepCopy(x, seen)
	end
	return out
end

return Util
