--!nocheck
-- Headless smoke test for the Steal a Cryptid client. Run it with
--   bash tools/smoke/run.sh [--list] [--fixture <name>] [--profile desktop|phone|both] [--verbose]
--
-- The parent process runs one child Lune process per device profile (each
-- gets a fresh mock engine), then merges their findings into one report.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local PROFILES = {
	desktop = { name = "desktop", touch = false, keyboard = true, mouse = true, viewport = roblox.Vector2.new(1920, 1080), label = "1920x1080, mouse + keyboard" },
	phone = { name = "phone", touch = true, keyboard = false, mouse = false, viewport = roblox.Vector2.new(844, 390), label = "844x390, touch only" },
}

local function parseArgs(argv)
	local opts = { profiles = { "desktop", "phone" }, list = false, verbose = false, waitAbort = 5 }
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "--list" then
			opts.list = true
		elseif a == "--verbose" or a == "-v" then
			opts.verbose = true
		elseif a == "--child" then
			opts.child = true
		elseif a == "--fixture" then
			i += 1
			opts.fixture = argv[i]
		elseif a == "--profile" then
			i += 1
			local p = argv[i]
			opts.profiles = if p == "both" then { "desktop", "phone" } else { p }
		elseif a == "--out" then
			i += 1
			opts.out = argv[i]
		elseif a == "--wait-abort" then
			i += 1
			opts.waitAbort = tonumber(argv[i]) or 5
		elseif a == "--start-only" then
			opts.startOnly = true
		elseif a == "--snapshots" then
			i += 1
			opts.snapshots = argv[i]
		elseif a == "--viewport" then
			i += 1
			local w, h = string.match(argv[i] or "", "^(%d+)[xX](%d+)$")
			if not w then
				opts.unknown = "--viewport " .. tostring(argv[i]) .. " (expected WIDTHxHEIGHT, e.g. 1920x1080)"
			else
				opts.viewport = { tonumber(w), tonumber(h) }
			end
		elseif a == "--help" or a == "-h" then
			opts.help = true
		else
			opts.unknown = a
		end
		i += 1
	end
	return opts
end

local opts = parseArgs(process.args)
local ROOT = process.env.SMOKE_ROOT or process.cwd
if string.sub(ROOT, -1) ~= "/" then
	ROOT ..= "/"
end
local API_DUMP = process.env.SMOKE_API or (ROOT .. "tools/.lune/API-Dump.json")
local CALLER_CWD = process.env.SMOKE_CWD or ROOT
if opts.snapshots and string.sub(opts.snapshots, 1, 1) ~= "/" then
	opts.snapshots = (if string.sub(CALLER_CWD, -1) == "/" then CALLER_CWD else CALLER_CWD .. "/") .. opts.snapshots
end
local LUNE = process.env.SMOKE_LUNE or (ROOT .. "tools/.lune/lune")

if opts.help or opts.unknown then
	if opts.unknown then
		stdio.ewrite("unknown option: " .. tostring(opts.unknown) .. "\n")
	end
	print([[usage: bash tools/smoke/run.sh [options]
  --list               print the PlayerGui tree after the scenario
  --fixture <name>     run tools/smoke/fixtures/<name>/ as the client instead of src/client
  --profile <p>        desktop | phone | both (default both)
  --verbose            echo the game's print/warn output as it happens
  --wait-abort <s>     abort WaitForChild calls with no timeout after s virtual seconds (default 5, 0 = never)
  --start-only         only start Main and let 10 seconds pass (quick check)
  --snapshots <dir>    dump the GUI tree as JSON at each UI checkpoint into <dir> (see README)
  --viewport WxH       screen size for the run (default 1920x1080 desktop, 844x390 phone)]])
	process.exit(if opts.unknown then 2 else 0)
end

--------------------------------------------------------------------------
-- Child: one run in a fresh mock engine
--------------------------------------------------------------------------

local function runChild()
	math.randomseed(1234)
	local Reflect = require("./lib/reflect")
	local Report = require("./lib/report")
	local Sched = require("./lib/sched")
	local Inst = require("./lib/inst")
	require("./lib/classes")
	local Services = require("./lib/services")
	local Loader = require("./lib/loader")
	local World = require("./lib/world")
	local Scenario = require("./lib/scenario")

	local profile = PROFILES[opts.profiles[1]]
	assert(profile, "unknown profile " .. tostring(opts.profiles[1]))
	if opts.viewport then
		profile = table.clone(profile)
		profile.viewport = roblox.Vector2.new(opts.viewport[1], opts.viewport[2])
		profile.label = string.format("%dx%d, %s", opts.viewport[1], opts.viewport[2], if profile.touch then "touch only" else "mouse + keyboard")
	end
	local started = os.clock()

	Reflect.loadApiDump(API_DUMP)
	Loader.root = ROOT
	Services.setup(profile)

	-- Project tree (Rojo)
	local project = serde.decode("json", fs.readFile(ROOT .. "default.project.json"))
	local tree = project.tree
	local fixtureDir = nil
	if opts.fixture then
		fixtureDir = "tools/smoke/fixtures/" .. opts.fixture
		if not fs.isDir(ROOT .. fixtureDir) then
			error("no fixture folder " .. fixtureDir)
		end
		local client = tree.StarterPlayer and tree.StarterPlayer.StarterPlayerScripts and tree.StarterPlayer.StarterPlayerScripts.Client
		assert(client, "default.project.json has no StarterPlayer.StarterPlayerScripts.Client node")
		client["$path"] = fixtureDir
	end
	-- Server scripts don't replicate to the client: leave ServerScriptService empty.
	tree.ServerScriptService = nil
	Loader.applyNode(tree, Services.game)
	for _, path in Loader.skipped do
		Report.add("NOTE", "Project paths not built", path .. " (missing on disk; ignored)", nil)
	end

	local RS = Services.byClass.ReplicatedStorage
	local SP = Services.byClass.StarterPlayer
	local sps = Inst.findChild(Inst.S[SP], "StarterPlayerScripts")
	local clientTemplate = sps and Inst.findChild(Inst.S[sps], "Client")
	assert(clientTemplate, "StarterPlayer.StarterPlayerScripts.Client was not built")

	-- A fixture can borrow real client folders (tools/smoke/fixtures/<name>/include.txt,
	-- one path under src/client per line, e.g. "Components").
	if fixtureDir and fs.isFile(ROOT .. fixtureDir .. "/include.txt") then
		for line in string.gmatch(fs.readFile(ROOT .. fixtureDir .. "/include.txt"), "[^\n]+") do
			line = string.gsub(string.gsub(line, "^%s+", ""), "%s+$", "")
			if line ~= "" and string.sub(line, 1, 1) ~= "#" then
				local built = Loader.buildPath("src/client/" .. line, nil, clientTemplate)
				if not built then
					Report.add("HARNESS", "Harness errors", "fixture include.txt: src/client/" .. line .. " does not exist", nil)
				end
			end
		end
	end

	World.build()
	local clientRealm = Loader.newRealm("client", true)
	local client = World.installClient(clientTemplate)

	-- Output capture and classification of warn() lines
	local controllersFolder = Inst.findChild(Inst.S[client], "Controllers")
	local function rootCause(controllerName)
		local module = controllersFolder and Inst.findChild(Inst.S[controllersFolder], controllerName)
		if not module then
			return nil
		end
		local cause, via = Loader.failureOf(clientRealm, module)
		if not cause then
			return nil
		end
		cause = string.gsub(cause, "%[smoke%-abort%] ", "")
		return "root cause: " .. cause .. (if via then " (via " .. via .. ")" else "")
	end
	Loader.onPrint = function(kind, text, loc)
		-- (No stdio here: Lune's stdio is async and would yield the game thread.
		-- --verbose prints the captured log from the parent instead.)
		if kind == "print" then
			local name = string.match(text, "Started ([%w_]+)$")
			if name then
				table.insert(Report.stats.controllersStarted, name)
			end
			local n, m = string.match(text, "(%d+)/(%d+) controllers started")
			if n then
				Report.stats.mainReady = { started = tonumber(n), total = tonumber(m) }
			end
			return
		end
		local controller = string.match(text, "Controller '([%w_]+)'")
		if string.find(text, "failed to require", 1, true)
			or string.find(text, "errored during Start", 1, true)
			or string.find(text, "does not expose a Start", 1, true)
			or string.find(text, "but does not exist", 1, true)
			or string.find(text, "never appeared", 1, true) then
			local detail = controller and rootCause(controller)
			Report.add("FAIL", "Main start failures", text, loc, detail)
			if controller then
				Report.stats.controllerFailures = Report.stats.controllerFailures or {}
				Report.stats.controllerFailures[controller] = { text = text, cause = detail }
			end
		elseif string.match(text, "[%w_%-/]+%.luau:%d+:") or string.find(text, "attempt to ", 1, true) then
			Report.add("FAIL", "Errors caught by pcall and reported with warn()", text, loc)
		else
			Report.add("WARN", "warn() output", text, loc)
		end
	end

	local snapshotIndex = nil
	local ok, err = xpcall(function()
		if opts.snapshots then
			Sched.afterFrame = Scenario.checkWaits
			Scenario.options.waitAbort = opts.waitAbort
			snapshotIndex = require("./lib/snapshot").run(clientRealm, client, opts.snapshots)
			Report.stats.virtualSeconds = Sched.now
			Report.stats.frames = Sched.frameCount
			Report.stats.instances = Inst.created
		else
			Scenario.run(clientRealm, client, { waitAbort = opts.waitAbort, startOnly = opts.startOnly })
		end
	end, function(e)
		return tostring(e) .. "\n" .. debug.traceback()
	end)
	if not ok then
		Report.add("HARNESS", "Harness errors", "the scenario itself crashed: " .. tostring(err), nil)
	end

	local result = Report.toTable()
	result.profile = profile.name
	result.profileLabel = profile.label
	result.realSeconds = os.clock() - started
	result.unimplemented = Inst.unimplemented
	result.dbVersion = Reflect.dbVersion
	result.snapshots = snapshotIndex
	if opts.list then
		result.tree = Scenario.listTree()
	end
	-- Controller order from Main (so the summary can show N/M even if it stalled)
	local main = Inst.findChild(Inst.S[client], "Main")
	if main and Inst.S[main].source then
		local order = {}
		local block = string.match(Inst.S[main].source, "CONTROLLER_ORDER[^=]*=%s*(%b{})")
		if block then
			for name in string.gmatch(block, '"([%w_]+)"') do
				table.insert(order, name)
			end
		end
		result.controllerOrder = order
	end
	fs.writeFile(opts.out, serde.encode("json", result, false))
end

if opts.child then
	runChild()
	process.exit(0)
end

--------------------------------------------------------------------------
-- Parent: run the profiles, merge, print
--------------------------------------------------------------------------

local useColor = process.env.NO_COLOR == nil and process.env.TERM ~= "dumb"

local function color(c: string, text: string): string
	if not useColor then
		return text
	end
	return stdio.color(c) .. text .. stdio.color("reset")
end

local function bold(text: string): string
	if not useColor then
		return text
	end
	return stdio.style("bold") .. text .. stdio.style("reset")
end

local tmpDir = ROOT .. "tools/.lune/tmp"
if not fs.isDir(tmpDir) then
	fs.writeDir(tmpDir)
end

if opts.snapshots and #opts.profiles > 1 then
	opts.profiles = { "desktop" }
end
local wallStart = os.clock()
local results = {}
for _, name in opts.profiles do
	if not PROFILES[name] then
		stdio.ewrite("unknown profile " .. name .. "\n")
		process.exit(2)
	end
	local out = tmpDir .. "/smoke-" .. name .. ".json"
	if fs.isFile(out) then
		fs.removeFile(out)
	end
	local args = { "run", ROOT .. "tools/smoke/main.luau", "--child", "--profile", name, "--out", out, "--wait-abort", tostring(opts.waitAbort) }
	if opts.list then
		table.insert(args, "--list")
	end
	if opts.verbose then
		table.insert(args, "--verbose")
	end
	if opts.startOnly then
		table.insert(args, "--start-only")
	end
	if opts.fixture then
		table.insert(args, "--fixture")
		table.insert(args, opts.fixture)
	end
	if opts.snapshots then
		table.insert(args, "--snapshots")
		table.insert(args, opts.snapshots)
	end
	if opts.viewport then
		table.insert(args, "--viewport")
		table.insert(args, string.format("%dx%d", opts.viewport[1], opts.viewport[2]))
	end
	stdio.ewrite(string.format("smoke: running the %s profile...\n", name))
	local r = process.exec(LUNE, args, { cwd = ROOT, env = { SMOKE_ROOT = ROOT, SMOKE_API = API_DUMP, SMOKE_LUNE = LUNE } })
	if r.stdout ~= "" then
		stdio.write(r.stdout)
	end
	if not fs.isFile(out) then
		stdio.ewrite(string.format("smoke: the %s run crashed (exit %s)\n%s\n%s\n", name, tostring(r.code), r.stdout, r.stderr))
		process.exit(3)
	end
	local result = serde.decode("json", fs.readFile(out))
	table.insert(results, result)
	if opts.verbose then
		for _, o in result.output do
			stdio.write(string.format("[%s %7.2fs %-5s %s] %s\n", name, o.t, o.kind, tostring(o.step), o.text))
		end
	end
end

-- Merge findings across profiles
local merged = {}
local order = {}
for _, result in results do
	for _, f in result.findings do
		local key = f.sev .. "\0" .. f.cat .. "\0" .. (f.loc or "") .. "\0" .. f.msg
		local m = merged[key]
		if not m then
			m = { sev = f.sev, cat = f.cat, msg = f.msg, loc = f.loc, detail = f.detail, count = 0, step = f.step, profiles = {} }
			merged[key] = m
			table.insert(order, key)
		end
		m.count += f.count
		if not table.find(m.profiles, result.profile) then
			table.insert(m.profiles, result.profile)
		end
	end
end

local SEVERITIES = {
	{ "HARNESS", "HARNESS ERRORS (bugs in the smoke harness itself, not the game)", "purple" },
	{ "FAIL", "FAILURES", "red" },
	{ "WARN", "WARNINGS", "yellow" },
	{ "NOTE", "NOTES", "blue" },
}

local function indent(text: string, prefix: string): string
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, prefix .. line)
	end
	return table.concat(out, "\n")
end

local function profileTag(m): string
	if #m.profiles == #results then
		return if #results > 1 then "all profiles" else m.profiles[1]
	end
	return table.concat(m.profiles, ", ")
end

local lines = {}
local function out(s: string?)
	table.insert(lines, s or "")
end

local first = results[1]
out(bold("Steal a Cryptid — client smoke test"))
out(string.format("Reflection DB %s, API dump from %s", tostring(first.dbVersion), API_DUMP))
for _, r in results do
	out(string.format("  %-8s %-28s %6.0f virtual s, %5d frames, %6d instances, %.1f s real",
		r.profile, "(" .. r.profileLabel .. ")", r.stats.virtualSeconds or 0, r.stats.frames or 0, r.stats.instances or 0, r.realSeconds or 0))
end
if opts.fixture then
	out("Fixture: tools/smoke/fixtures/" .. opts.fixture .. " (in place of src/client)")
end
out()

local counts = {}
for _, sev in SEVERITIES do
	local list = {}
	for _, key in order do
		local m = merged[key]
		if m.sev == sev[1] then
			table.insert(list, m)
		end
	end
	counts[sev[1]] = #list
	if #list == 0 then
		continue
	end
	out(color(sev[3], bold(string.format("%s (%d)", sev[2], #list))))
	-- group by category, categories in first-seen order
	local cats, byCat = {}, {}
	for _, m in list do
		if not byCat[m.cat] then
			byCat[m.cat] = {}
			table.insert(cats, m.cat)
		end
		table.insert(byCat[m.cat], m)
	end
	for _, cat in cats do
		out(string.format("  %s (%d)", bold(cat), #byCat[cat]))
		local items = byCat[cat]
		for i, m in items do
			local times = if m.count > 1 then string.format(" ×%d", m.count) else ""
			out("    • " .. m.msg)
			out(string.format("        at %s   [%s; first in step %s]%s", m.loc or "?", profileTag(m), tostring(m.step), times))
			-- The same detail (e.g. one root cause) for a run of findings is printed once, after the run.
			local nextItem = items[i + 1]
			if m.detail and m.detail ~= "" and not (nextItem and nextItem.detail == m.detail) then
				local prev = items[i - 1]
				local shared = prev and prev.detail == m.detail
				out(indent((if shared then "(all of the above) " else "") .. m.detail, "          "))
			end
		end
	end
	out()
end
if counts.FAIL == 0 then
	out(color("green", bold("FAILURES (0)")))
	out()
end

-- Summary
out(bold("SUMMARY"))
for _, r in results do
	local st = r.stats
	local total = if r.controllerOrder then #r.controllerOrder else (st.mainReady and st.mainReady.total or 0)
	local startedSet = {}
	for _, n in st.controllersStarted do
		startedSet[n] = true
	end
	out(string.format("  [%s] controllers started: %d/%d%s", r.profile, #st.controllersStarted, total,
		if st.mainReady then "" else "  (Main never printed 'Client ready': it stalled or errored)"))
	if r.controllerOrder then
		local notStarted = {}
		for _, n in r.controllerOrder do
			if not startedSet[n] then
				local why = st.controllerFailures and st.controllerFailures[n]
				table.insert(notStarted, n .. (if why and why.cause then " — " .. why.cause else if why then "" else " — never reached"))
			end
		end
		if #notStarted > 0 then
			out("      not started:")
			for _, n in notStarted do
				out("        - " .. n)
			end
		end
	end
end
out()
do
	local r = results[1]
	local guis = {}
	for name, g in r.stats.screenGuis do
		table.insert(guis, { name = name, g = g })
	end
	table.sort(guis, function(a, b)
		local da, db = a.g.displayOrder or -1e9, b.g.displayOrder or -1e9
		if da ~= db then
			return da < db
		end
		return a.name < b.name
	end)
	out(string.format("  ScreenGuis put in PlayerGui [%s] (%d):", r.profile, #guis))
	for _, e in guis do
		local g = e.g
		out(string.format("    %-22s %-13s DisplayOrder=%-4s ResetOnSpawn=%-5s created at %s%s", e.name, g.class or "?",
			tostring(g.displayOrder or "-"), tostring(g.resetOnSpawn), tostring(g.createdAt or "?"),
			if (g.count or 1) > 1 then string.format(" (parented %d times)", g.count) else ""))
	end
end
out()
for _, r in results do
	local perGui = {}
	local totalButtons = 0
	for gui, buttons in r.stats.clicked do
		local n = 0
		for _ in buttons do
			n += 1
		end
		totalButtons += n
		table.insert(perGui, string.format("%s %d", gui, n))
	end
	table.sort(perGui)
	out(string.format("  [%s] buttons clicked: %d clicks on %d distinct buttons (%s)", r.profile, r.stats.buttonsClicked or 0, totalButtons,
		if #perGui > 0 then table.concat(perGui, ", ") else "none"))
	local found = {}
	for gui, buttons in r.stats.buttonsFound or {} do
		local n = 0
		for _ in buttons do
			n += 1
		end
		table.insert(found, string.format("%s %d", gui, n))
	end
	table.sort(found)
	out(string.format("  [%s] buttons that existed (visible or not): %s", r.profile, if #found > 0 then table.concat(found, ", ") else "none"))
end
do
	local r = results[1]
	if r.stats.opened and #r.stats.opened > 0 then
		out("  screens opened via Open(): " .. table.concat(r.stats.opened, ", "))
	else
		out("  screens opened via Open(): none (no controller with Open() loaded)")
	end
	if r.stats.prompts then
		out("  prompts simulated: " .. table.concat(r.stats.prompts, ", "))
	end
	if r.stats.actions and #r.stats.actions > 0 then
		out("  ContextActionService actions called: " .. table.concat(r.stats.actions, ", "))
	end
end
out()
for _, r in results do
	local names = {}
	for name, n in r.stats.remoteCounts do
		table.insert(names, string.format("%s ×%d", name, n))
	end
	table.sort(names)
	out(string.format("  [%s] remote calls from the client: %s", r.profile, if #names > 0 then table.concat(names, ", ") else "none"))
end
do
	local r = results[1]
	if #r.stats.remoteCalls > 0 then
		out("  remote call log [" .. r.profile .. "] (first 25):")
		for i, c in r.stats.remoteCalls do
			if i > 25 then
				out(string.format("    ... %d more", #r.stats.remoteCalls - 25))
				break
			end
			out(string.format("    %7.2fs %-14s %s(%s)  from %s", c.t, c.kind, c.name, c.args, tostring(c.loc)))
		end
	end
	if r.stats.calls and #r.stats.calls > 0 then
		local parts = {}
		for _, c in r.stats.calls do
			table.insert(parts, c.kind .. "(" .. c.text .. ")")
		end
		out("  other engine calls [" .. r.profile .. "]: " .. table.concat(parts, ", "))
	end
end
out()

if opts.list then
	for _, r in results do
		out(bold(string.format("PlayerGui after the scenario [%s]:", r.profile)))
		out(r.tree or "(empty)")
		out()
	end
end

if opts.snapshots then
	local idx = results[1].snapshots
	out(bold("SNAPSHOTS"))
	if not idx then
		out("  (none written: the snapshot run crashed, see HARNESS ERRORS)")
	else
		out(string.format("  viewport %dx%d, written to %s", idx.viewport.w, idx.viewport.h, opts.snapshots))
		for _, c in idx.checkpoints or {} do
			out(string.format("    %-16s %3d roots  %s%s", c.name, c.roots, c.file, if c.note then "   (" .. c.note .. ")" else ""))
		end
		for _, sk in idx.skipped or {} do
			out(string.format("    %-16s skipped: %s", sk.name, sk.reason))
		end
	end
	out()
end

-- Fixture self-check
local exitCode = if counts.FAIL > 0 then 1 else 0
if counts.HARNESS > 0 then
	exitCode = 2
end
if opts.snapshots then
	-- The snapshots are the product here: 0 when they were written (game
	-- failures are in the report above), 2 for harness errors.
	exitCode = if counts.HARNESS > 0 or not results[1].snapshots then 2 else 0
end
if opts.fixture then
	local expectPath = ROOT .. "tools/smoke/fixtures/" .. opts.fixture .. "/expect.txt"
	if fs.isFile(expectPath) then
		out(bold("FIXTURE SELF-CHECK (each expected mistake must be reported as a FAILURE)"))
		local allOk = true
		for line in string.gmatch(fs.readFile(expectPath), "[^\n]+") do
			line = string.gsub(line, "^%s+", "")
			line = string.gsub(line, "%s+$", "")
			if line ~= "" and string.sub(line, 1, 1) ~= "#" then
				local hit = nil
				for _, key in order do
					local m = merged[key]
					if m.sev == "FAIL" and (string.find(m.msg, line, 1, true) or string.find(m.cat, line, 1, true)) then
						hit = m
						break
					end
				end
				if hit then
					out(color("green", "  caught  ") .. line .. "  ->  [" .. hit.cat .. "] at " .. tostring(hit.loc))
				else
					allOk = false
					out(color("red", "  MISSED  ") .. line)
				end
			end
		end
		exitCode = if allOk and counts.HARNESS == 0 then 0 else 1
		out(if allOk then color("green", "  all expected mistakes were caught") else color("red", "  some expected mistakes were NOT caught"))
		out()
	end
end

out(string.format("Done in %.1f s. %d failures, %d warnings, %d notes%s.", os.clock() - wallStart, counts.FAIL, counts.WARN, counts.NOTE,
	if counts.HARNESS > 0 then string.format(", %d HARNESS ERRORS", counts.HARNESS) else ""))
print(table.concat(lines, "\n"))
process.exit(exitCode)
