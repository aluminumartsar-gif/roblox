--!nocheck
-- Cooperative scheduler on a VIRTUAL clock.
--
-- Every piece of game code runs in a coroutine created here. Game threads
-- yield (task.wait, WaitForChild, InvokeServer, Signal:Wait, ...) and are
-- resumed by the frame loop; the scenario advances the clock frame by frame
-- with Sched.advance(seconds). Nothing here ever sleeps for real.

local Report = require("./report")

local Sched = {}

Sched.now = 0 -- virtual seconds since the run started
Sched.frameCount = 0
Sched.frameDt = 1 / 30
-- Fixed virtual wall clock so every run is identical: 2026-10-06 20:00 UTC.
Sched.EPOCH = 1791316800
Sched.CLOCK_BASE = 1000 -- os.clock() at virtual time 0
Sched.current = nil -- the game thread being resumed right now

Sched.onFrame = nil -- function(dt) — RunService events (set by services.luau)
Sched.afterFrame = nil -- function() — WaitForChild abort checks etc.

local meta: { [thread]: { name: string?, cancelled: boolean? } } = setmetatable({}, { __mode = "k" })
local waiting = {} -- { co=thread?, fn=function?, at=number, args=table?, seq=number }
local deferred = {} -- { co=thread, args=table }
local seq = 0

Report.now = function()
	return Sched.now
end

local function errHandler(err)
	local co = coroutine.running()
	local m = meta[co]
	Report.threadError(err, debug.traceback(tostring(err), 2), m and m.name)
	return err
end

--- A new game thread running fn (errors are reported, never propagated).
function Sched.create(fn: (...any) -> ...any, name: string?): thread
	local co = coroutine.create(function(...)
		xpcall(fn, errHandler, ...)
	end)
	meta[co] = { name = name }
	return co
end

function Sched.nameOf(co: thread): string?
	local m = meta[co]
	return m and m.name
end

function Sched.isCancelled(co: thread): boolean
	local m = meta[co]
	return m ~= nil and m.cancelled == true
end

--- Resumes a suspended thread now. Returns false if it couldn't be resumed.
function Sched.resume(co: thread, ...: any): boolean
	if coroutine.status(co) ~= "suspended" then
		return false
	end
	local m = meta[co]
	if m and m.cancelled then
		return false
	end
	local prev = Sched.current
	Sched.current = co
	local ok, err = coroutine.resume(co, ...)
	Sched.current = prev
	if not ok then
		-- A thread the game created itself (coroutine.create) died with an error.
		Report.threadError(err, nil, m and m.name)
	end
	return true
end

function Sched.spawn(fnOrThread: any, ...: any): thread
	if type(fnOrThread) == "thread" then
		if coroutine.status(fnOrThread) == "dead" then
			error("cannot resume dead coroutine", 2)
		end
		Sched.resume(fnOrThread, ...)
		return fnOrThread
	end
	if type(fnOrThread) ~= "function" then
		error("invalid argument #1 to 'spawn' (function or thread expected, got " .. typeof(fnOrThread) .. ")", 2)
	end
	local co = Sched.create(fnOrThread)
	Sched.resume(co, ...)
	return co
end

function Sched.defer(fnOrThread: any, ...: any): thread
	local co
	if type(fnOrThread) == "thread" then
		co = fnOrThread
	elseif type(fnOrThread) == "function" then
		co = Sched.create(fnOrThread)
	else
		error("invalid argument #1 to 'defer' (function or thread expected, got " .. typeof(fnOrThread) .. ")", 2)
	end
	table.insert(deferred, { co = co, args = table.pack(...) })
	return co
end

--- Resume `co` (with args) at virtual time `at`.
function Sched.schedule(co: thread, at: number, args: { any }?)
	seq += 1
	table.insert(waiting, { co = co, at = at, args = args, seq = seq })
end

--- Internal timer: call fn (on the harness side, not in a game thread) at `at`.
function Sched.after(delay: number, fn: () -> ())
	seq += 1
	local entry = { fn = fn, at = Sched.now + math.max(0, delay), seq = seq }
	table.insert(waiting, entry)
	return entry
end

function Sched.cancelTimer(entry)
	if entry then
		entry.cancelled = true
	end
end

function Sched.delay(seconds: number?, fnOrThread: any, ...: any): thread
	local co
	if type(fnOrThread) == "thread" then
		co = fnOrThread
	elseif type(fnOrThread) == "function" then
		co = Sched.create(fnOrThread)
	else
		error("invalid argument #2 to 'delay' (function or thread expected, got " .. typeof(fnOrThread) .. ")", 2)
	end
	Sched.schedule(co, Sched.now + math.max(0, tonumber(seconds) or 0), table.pack(...))
	return co
end

local function assertYieldable(what: string)
	local co = coroutine.running()
	if not coroutine.isyieldable() or meta[co] == nil and Sched.current == nil then
		error("attempt to yield from outside a coroutine (" .. what .. ")", 3)
	end
	return co
end

--- task.wait: yields until at least `seconds` have passed (next frame for 0).
function Sched.wait(seconds: number?): number
	local co = assertYieldable("task.wait")
	local start = Sched.now
	Sched.schedule(co, Sched.now + math.max(0, tonumber(seconds) or 0), nil)
	coroutine.yield()
	return Sched.now - start
end

--- Yields the current game thread for `seconds` (async API emulation).
function Sched.sleep(seconds: number)
	local co = assertYieldable("async call")
	Sched.schedule(co, Sched.now + seconds, nil)
	coroutine.yield()
end

function Sched.cancel(co: thread)
	if type(co) ~= "thread" then
		error("invalid argument #1 to 'cancel' (thread expected, got " .. typeof(co) .. ")", 2)
	end
	if co == coroutine.running() then
		error("cannot cancel the running thread", 2)
	end
	local m = meta[co]
	if not m then
		m = {}
		meta[co] = m
	end
	m.cancelled = true
	if coroutine.status(co) == "suspended" then
		coroutine.close(co)
	end
end

--- Runs deferred threads until there are none left.
function Sched.drain()
	local rounds = 0
	while #deferred > 0 do
		rounds += 1
		if rounds > 200 then
			Report.add("FAIL", "Script errors", "task.defer re-entrancy limit reached (a deferred thread keeps deferring itself)", nil)
			deferred = {}
			break
		end
		local list = deferred
		deferred = {}
		for _, d in list do
			Sched.resume(d.co, table.unpack(d.args, 1, d.args.n))
		end
	end
end

local function resumeDue()
	local list = waiting
	waiting = {}
	local due = {}
	local now = Sched.now + 1e-9
	for _, w in list do
		if w.cancelled then
			continue
		end
		if w.co and (meta[w.co] and meta[w.co].cancelled or coroutine.status(w.co) == "dead") then
			continue
		end
		if w.at <= now then
			table.insert(due, w)
		else
			table.insert(waiting, w)
		end
	end
	table.sort(due, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.seq < b.seq
	end)
	for _, w in due do
		if w.fn then
			local ok, err = pcall(w.fn)
			if not ok then
				Report.add("HARNESS", "Harness errors", tostring(err), nil, debug.traceback())
			end
		elseif w.args then
			Sched.resume(w.co, table.unpack(w.args, 1, w.args.n))
		else
			Sched.resume(w.co)
		end
		Sched.drain()
	end
end

--- One frame: RunService events, then due threads, then deferred threads.
function Sched.frame(dt: number?)
	dt = dt or Sched.frameDt
	Sched.now += dt
	Sched.frameCount += 1
	if Sched.onFrame then
		Sched.onFrame(dt)
	end
	Sched.drain()
	resumeDue()
	Sched.drain()
	if Sched.afterFrame then
		Sched.afterFrame()
	end
end

--- Advances the virtual clock by `seconds`, frame by frame.
function Sched.advance(seconds: number)
	Sched.drain()
	local target = Sched.now + seconds - 1e-6
	while Sched.now < target do
		Sched.frame(math.min(Sched.frameDt, math.max(1e-3, target - Sched.now + 1e-6)))
	end
end

--- Runs fn in a fresh game thread right now (and lets deferred work finish).
function Sched.run(fn: (...any) -> ...any, name: string?, ...: any): thread
	local co = Sched.create(fn, name)
	Sched.resume(co, ...)
	Sched.drain()
	return co
end

function Sched.pendingCount(): number
	return #waiting
end

return Sched
