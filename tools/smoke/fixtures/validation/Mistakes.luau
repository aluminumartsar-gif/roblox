--!strict
-- Deliberate mistakes. Each one runs in its own thread so one error doesn't
-- hide the next; the smoke harness must report every one (see expect.txt).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local gui = Instance.new("ScreenGui")
gui.Name = "FixtureGui"
gui.ResetOnSpawn = true -- destroyed on respawn: a warning
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Parent = gui
local label = Instance.new("TextLabel")
label.Parent = frame

local mistakes: { () -> () } = {
	-- a typo'd property name
	function()
		(frame :: any).BackgroundColour = Color3.new(1, 0, 0)
	end,
	-- an enum item that doesn't exist
	function()
		label.Font = (Enum.Font :: any).Nope
	end,
	-- the wrong type for a property
	function()
		(frame :: any).Size = "100,100"
	end,
	-- a class that doesn't exist / can't be created
	function()
		Instance.new("Nope" :: any)
	end,
	function()
		Instance.new("Players" :: any)
	end,
	-- a read-only property
	function()
		(frame :: any).AbsoluteSize = Vector2.new(10, 10)
	end,
	-- an unknown service
	function()
		game:GetService("NopeService" :: any)
	end,
	-- attribute of an unsupported type
	function()
		frame:SetAttribute("Owner", frame :: any)
	end,
	-- property changed signal for a property that doesn't exist
	function()
		frame:GetPropertyChangedSignal("Nope" :: any):Connect(function() end)
	end,
	-- an EnumItem of the wrong enum
	function()
		label.TextXAlignment = Enum.Font.Arial :: any
	end,
	-- nil into a string property
	function()
		label.Text = nil :: any
	end,
	-- tweening a property that can't be tweened
	function()
		TweenService:Create(label, TweenInfo.new(0.5), { Text = "hi" }):Play()
	end,
	-- waits forever (no timeout)
	function()
		ReplicatedStorage:WaitForChild("DoesNotExist")
	end,
	-- an unimplemented-but-real API (stubbed: a warning)
	function()
		(Players :: any):GetFriendsAsync(1)
	end,
	-- a plain warn (a warning)
	function()
		warn("fixture: this is a warning")
	end,
	-- an error swallowed by pcall (a note)
	function()
		pcall(function()
			error("fixture: swallowed by pcall")
		end)
	end,
}

for _, fn in ipairs(mistakes) do
	task.spawn(fn)
end

-- A runtime error inside an event handler (every frame for a moment).
local connection: RBXScriptConnection
local frames = 0
connection = RunService.RenderStepped:Connect(function()
	frames += 1
	if frames > 3 then
		connection:Disconnect()
	end
	local nothing: any = nil
	print(nothing.y)
end)

return {}
