--!nocheck
-- Mock RBXScriptSignal / RBXScriptConnection.
--
-- Firing runs every handler in its own new thread right away (Roblox's
-- immediate signal behaviour): an error in one handler is reported with its
-- traceback and does not stop the others. Threads blocked in :Wait() are
-- resumed with the fired arguments.

local Report = require("./report")
local Sched = require("./sched")
local Typeof = require("./typeof")

local Signal = {}

type SignalState = {
	name: string,
	conns: { any },
	waiters: { thread },
	proxy: any,
}

local states: { [any]: SignalState } = setmetatable({}, { __mode = "k" })
local connStates: { [any]: any } = setmetatable({}, { __mode = "k" })

local fireDepth = 0
local MAX_DEPTH = 120

local function newConnection(st: SignalState, fn: (...any) -> (), once: boolean, location: string?)
	local c = { fn = fn, connected = true, once = once, signal = st, location = location }
	local proxy
	proxy = Typeof.proxy("RBXScriptConnection", {
		__index = function(_, key)
			if key == "Connected" then
				return c.connected
			elseif key == "Disconnect" or key == "disconnect" then
				return function(self)
					if self ~= proxy then
						error("Expected ':' not '.' calling member function Disconnect", 2)
					end
					c.connected = false
				end
			end
			error(tostring(key) .. " is not a valid member of RBXScriptConnection", 2)
		end,
		__newindex = function(_, key)
			error(tostring(key) .. " cannot be assigned to", 2)
		end,
		__tostring = function()
			return "Connection"
		end,
	})
	c.proxy = proxy
	connStates[proxy] = c
	table.insert(st.conns, c)
	return proxy
end

local function checkHandler(fn: any, method: string)
	if type(fn) ~= "function" then
		error("Attempt to connect failed: Passed value is not a function", 3)
	end
end

local methods = {}

function methods.Connect(st: SignalState, fn: any)
	checkHandler(fn, "Connect")
	return newConnection(st, fn, false, Report.callerLocation())
end
methods.connect = methods.Connect
methods.ConnectParallel = methods.Connect

function methods.Once(st: SignalState, fn: any)
	checkHandler(fn, "Once")
	return newConnection(st, fn, true, Report.callerLocation())
end

function methods.Wait(st: SignalState)
	local co = coroutine.running()
	if not coroutine.isyieldable() then
		error("attempt to yield from outside a coroutine", 3)
	end
	table.insert(st.waiters, co)
	return coroutine.yield()
end
methods.wait = methods.Wait

--- Creates a signal. Returns the user-facing proxy.
function Signal.new(name: string): any
	local st: SignalState = { name = name, conns = {}, waiters = {}, proxy = nil }
	local proxy
	proxy = Typeof.proxy("RBXScriptSignal", {
		__index = function(_, key)
			local m = methods[key]
			if m then
				return function(self, ...)
					if self ~= proxy then
						error("Expected ':' not '.' calling member function " .. tostring(key), 2)
					end
					return m(st, ...)
				end
			end
			error(tostring(key) .. " is not a valid member of RBXScriptSignal", 2)
		end,
		__newindex = function(_, key)
			error(tostring(key) .. " cannot be assigned to", 2)
		end,
		__tostring = function()
			return "Signal " .. name
		end,
	})
	st.proxy = proxy
	states[proxy] = st
	return proxy
end

function Signal.state(proxy: any): SignalState?
	return states[proxy]
end

function Signal.isSignal(v: any): boolean
	return states[v] ~= nil
end

function Signal.hasConnections(proxy: any): boolean
	local st = states[proxy]
	if not st then
		return false
	end
	for _, c in st.conns do
		if c.connected then
			return true
		end
	end
	return #st.waiters > 0
end

--- Fires the signal: each live handler runs in a new thread, now.
function Signal.fire(proxy: any, ...: any)
	local st = states[proxy]
	if not st then
		return
	end
	if #st.conns == 0 and #st.waiters == 0 then
		return
	end
	if fireDepth >= MAX_DEPTH then
		Report.add("FAIL", "Script errors", "Maximum event re-entrancy depth exceeded for " .. st.name, Report.callerLocation())
		return
	end
	fireDepth += 1
	-- Compact + snapshot
	local live = {}
	for _, c in st.conns do
		if c.connected then
			table.insert(live, c)
		end
	end
	st.conns = live
	local snapshot = table.clone(live)
	for _, c in snapshot do
		if c.connected then
			if c.once then
				c.connected = false
			end
			local co = Sched.create(c.fn, st.name .. " handler" .. (c.location and (" connected at " .. c.location) or ""))
			Sched.resume(co, ...)
		end
	end
	if #st.waiters > 0 then
		local waiters = st.waiters
		st.waiters = {}
		for _, co in waiters do
			Sched.resume(co, ...)
		end
	end
	fireDepth -= 1
end

function Signal.disconnectAll(proxy: any)
	local st = states[proxy]
	if not st then
		return
	end
	for _, c in st.conns do
		c.connected = false
	end
	st.conns = {}
end

--- The game locations that connected to this signal (for reports).
function Signal.connectionSites(proxy: any): { string }
	local st = states[proxy]
	local out = {}
	if st then
		for _, c in st.conns do
			if c.connected and c.location then
				table.insert(out, c.location)
			end
		end
	end
	return out
end

return Signal
