--!nocheck
-- Findings collected during one run (one device profile, one Lune process).
-- main.luau merges the runs and prints the final report.

local Report = {}

Report.findings = {} -- key -> finding
Report.order = {} -- keys in first-seen order
Report.output = {} -- captured print/warn lines
Report.step = "startup" -- scenario step label (set by the scenario)
Report.now = function()
	return 0
end
Report.stats = {
	remoteCalls = {}, -- list of { name, kind, args, t }
	remoteCounts = {}, -- name -> count
	clicked = {}, -- screenGui name -> { buttonPath -> clicks }
	buttonsFound = {}, -- screenGui name -> { buttonPath -> true }
	screenGuis = {}, -- name -> { displayOrder, createdAt, destroyed }
	controllersStarted = {},
	controllerOrder = nil,
	mainReady = nil,
	harness = {},
}

local MAX_OUTPUT = 4000
local MAX_FINDINGS_PER_CATEGORY = 400

local categoryCounts = {}

-- Chunk names of game scripts all start with one of these (see loader.luau).
local GAME_PREFIXES = { "src/", "tools/smoke/fixtures/" }

function Report.isGameSource(source: string?): boolean
	if not source then
		return false
	end
	for _, p in GAME_PREFIXES do
		if string.sub(source, 1, #p) == p then
			return true
		end
	end
	return false
end

--- Splits "src/x.luau:12: message" into ("src/x.luau:12", "message").
function Report.splitLocation(message: string): (string?, string)
	local loc, rest = string.match(message, "^([%w_%./%-]+%.luau:%d+): (.*)$")
	if loc then
		return loc, rest
	end
	-- Other chunk names (harness files have absolute paths, no extension)
	loc, rest = string.match(message, "^(/[^:]+:%d+): (.*)$")
	if loc then
		return loc, rest
	end
	return nil, message
end

--- The innermost game-script frame on the current stack: (level, "file:line").
--- `level` is relative to the caller of gameLevel.
function Report.gameLevel(): (number?, string?)
	for level = 2, 60 do
		local source, line = debug.info(level, "sl")
		if source == nil then
			return nil, nil
		end
		if Report.isGameSource(source) then
			return level - 1, source .. ":" .. tostring(line)
		end
	end
	return nil, nil
end

--- "file:line" of the innermost game-script frame on the stack, or nil.
function Report.callerLocation(): string?
	for level = 2, 60 do
		local source, line = debug.info(level, "sl")
		if source == nil then
			return nil
		end
		if Report.isGameSource(source) then
			return source .. ":" .. tostring(line)
		end
	end
	return nil
end

--- Game frames ("src/x.luau:12 function name") from a Luau traceback.
function Report.gameFrames(traceback: string?): { string }
	local frames = {}
	if not traceback then
		return frames
	end
	for line in string.gmatch(traceback, "[^\n]+") do
		line = string.gsub(line, "^%s+", "")
		local src = string.match(line, "^([^:]+):%d+")
		if src and Report.isGameSource(src) then
			table.insert(frames, line)
		end
	end
	return frames
end

function Report.frameLocation(frame: string?): string?
	if not frame then
		return nil
	end
	return string.match(frame, "^([^%s]+:%d+)")
end

--- Records a finding. sev: "FAIL" | "WARN" | "NOTE" | "HARNESS".
function Report.add(sev: string, category: string, message: string, location: string?, detail: string?)
	local key = sev .. "\0" .. category .. "\0" .. (location or "") .. "\0" .. message
	local f = Report.findings[key]
	if f then
		f.count += 1
		return f
	end
	local catKey = sev .. "\0" .. category
	categoryCounts[catKey] = (categoryCounts[catKey] or 0) + 1
	if categoryCounts[catKey] > MAX_FINDINGS_PER_CATEGORY then
		return nil
	end
	f = {
		sev = sev,
		cat = category,
		msg = message,
		loc = location,
		detail = detail,
		count = 1,
		step = Report.step,
		t = Report.now(),
	}
	Report.findings[key] = f
	table.insert(Report.order, key)
	return f
end

function Report.log(kind: string, text: string, location: string?)
	if #Report.output >= MAX_OUTPUT then
		return
	end
	table.insert(Report.output, { kind = kind, text = text, loc = location, t = Report.now(), step = Report.step })
end

-- Error messages already recorded at the moment they were raised (API
-- misuse), so the thread's error handler doesn't record them twice.
local alreadyReported: { [string]: boolean } = {}

function Report.markReported(message: string)
	alreadyReported[message] = true
end

local function cleanRaw(message: string): (string, string?)
	-- Lune's coroutine.resume returns "runtime error: <msg>\nstack traceback:\n..."
	message = string.gsub(message, "^runtime error: ", "")
	local head, tb = string.match(message, "^(.-)\nstack traceback:\n(.*)$")
	if head then
		return head, tb
	end
	return message, nil
end

--- An error that escaped a game thread (script error / handler error).
function Report.threadError(err: any, traceback: string?, threadName: string?)
	local message = tostring(err)
	local rawTb
	message, rawTb = cleanRaw(message)
	traceback = traceback or rawTb
	if alreadyReported[message] then
		return
	end
	if string.find(message, "[smoke-abort]", 1, true) then
		return -- an infinite wait the harness aborted; reported separately
	end
	local loc, text = Report.splitLocation(message)
	local frames = Report.gameFrames(traceback)
	if not loc or not Report.isGameSource(string.match(loc, "^(.-):%d+$")) then
		local first = Report.frameLocation(frames[1])
		if first then
			if loc then
				text = message -- keep the harness location in the text for debugging
			end
			loc = first
		elseif loc then
			-- Raised inside the harness with no game frame: harness bug.
			Report.add("HARNESS", "Harness errors", text, loc, traceback)
			return
		end
	end
	local detail = nil
	if #frames > 0 then
		detail = table.concat(frames, "\n")
	end
	if threadName then
		detail = (detail and (detail .. "\n") or "") .. "(thread: " .. threadName .. ")"
	end
	Report.add("FAIL", "Script errors", text, loc, detail)
end

function Report.toTable()
	local list = {}
	for _, key in Report.order do
		table.insert(list, Report.findings[key])
	end
	return {
		findings = list,
		output = Report.output,
		stats = Report.stats,
	}
end

return Report
