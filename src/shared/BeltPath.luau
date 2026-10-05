--!strict
--[[
	BeltPath
	ReplicatedStorage/Shared/BeltPath

	Where everything on the egg belt is at a given moment. Shared so the
	server (reach checks) and every client (drawing) agree exactly, with no
	positions sent over the network: an egg only carries its spawn time, and
	both sides work out the rest from Config.Belt and the server clock.

	The belt is a ring around the hub campfire (world origin). An egg:
	  Rising   climbs out of the start burrow          (Config.Belt.RiseTime)
	  Riding   rides ArcDegrees round the ring         (Config.Belt.TravelTime)
	  Sinking  sinks into the end burrow               (Config.Belt.SinkTime)
	  Gone

	Angles are measured from +X toward +Z, in the direction eggs travel.
	CFrames returned are egg pivots: bottom centre, facing the direction of
	travel.
]]

local Config = require(script.Parent:WaitForChild("Config"))

local BeltPath = {}

local belt = Config.Belt
local EGG_HIDDEN_DEPTH = 4 -- how far below the belt surface an egg starts/ends

local gap = math.rad(360 - belt.ArcDegrees)
local startAngle = math.rad(belt.GapCenterDegrees) + gap / 2
local arc = math.rad(belt.ArcDegrees)

BeltPath.Center = Vector3.new(0, 0, 0)
BeltPath.StartAngle = startAngle
BeltPath.EndAngle = startAngle + arc
BeltPath.Arc = arc
--- Belt surface speed in studs per second (eggs and slats move together).
BeltPath.Speed = belt.Radius * arc / belt.TravelTime

function BeltPath.Lifetime(): number
	return belt.RiseTime + belt.TravelTime + belt.SinkTime
end

function BeltPath.Phase(age: number): string
	if age < 0 then
		return "Rising"
	elseif age < belt.RiseTime then
		return "Rising"
	elseif age < belt.RiseTime + belt.TravelTime then
		return "Riding"
	elseif age < BeltPath.Lifetime() then
		return "Sinking"
	end
	return "Gone"
end

--- A point on the belt's centre line at `angle`, at height `y`.
function BeltPath.PointAt(angle: number, y: number): Vector3
	return BeltPath.Center + Vector3.new(math.cos(angle) * belt.Radius, y, math.sin(angle) * belt.Radius)
end

--- CFrame on the centre line at `angle`, facing the direction of travel.
function BeltPath.FrameAt(angle: number, y: number): CFrame
	local position = BeltPath.PointAt(angle, y)
	local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
	return CFrame.lookAt(position, position + tangent)
end

--- The pivot of an egg that came out `age` seconds ago.
function BeltPath.EggCFrame(age: number): CFrame
	local top = belt.Height
	if age < belt.RiseTime then
		local alpha = math.clamp(age / belt.RiseTime, 0, 1)
		-- Ease out: quick at first, settling onto the belt.
		local eased = 1 - (1 - alpha) ^ 3
		return BeltPath.FrameAt(startAngle, top - EGG_HIDDEN_DEPTH * (1 - eased))
	end
	local ride = age - belt.RiseTime
	if ride < belt.TravelTime then
		return BeltPath.FrameAt(startAngle + arc * (ride / belt.TravelTime), top)
	end
	local alpha = math.clamp((ride - belt.TravelTime) / belt.SinkTime, 0, 1)
	local eased = alpha ^ 2
	return BeltPath.FrameAt(startAngle + arc, top - EGG_HIDDEN_DEPTH * eased)
end

--- The CFrame of slat `index` (1..SlatCount) at server time `now`. Slats
--- loop round the riding arc at belt speed.
function BeltPath.SlatCFrame(index: number, now: number): CFrame
	local spacing = arc / belt.SlatCount
	local travelled = (now * BeltPath.Speed / belt.Radius) % arc
	local angle = startAngle + ((index - 1) * spacing + travelled) % arc
	return BeltPath.FrameAt(angle, belt.Height - 0.1)
end

--- Length of one slat along the belt.
function BeltPath.SlatLength(): number
	return belt.Radius * arc / belt.SlatCount * 0.62
end

return BeltPath
