local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")
local Workspace    = game:GetService("Workspace")

-- Screen-space dirt splash effect for the dig minigame.
--   DirtSplashUI.burst()   — medium brown burst on each successful hit
--   DirtSplashUI.jackpot() — large golden burst when all required hits complete

local DirtSplashUI = {}

local DIRT_COLORS = {
	Color3.fromRGB(116, 83,  54),
	Color3.fromRGB(145, 108, 70),
	Color3.fromRGB(89,  64,  42),
	Color3.fromRGB(165, 130, 90),
	Color3.fromRGB(72,  54,  36),
}

local JACKPOT_COLORS = {
	Color3.fromRGB(255, 215, 70),
	Color3.fromRGB(255, 180, 40),
	Color3.fromRGB(255, 240, 110),
	Color3.fromRGB(116, 83,  54),
	Color3.fromRGB(200, 160, 60),
}

local splashGui: ScreenGui? = nil

local function getGui(): ScreenGui
	if splashGui and splashGui.Parent then
		return splashGui :: ScreenGui
	end

	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name              = "DirtSplashGui"
	gui.ResetOnSpawn      = false
	gui.IgnoreGuiInset    = true
	gui.DisplayOrder      = 25
	gui.ZIndexBehavior    = Enum.ZIndexBehavior.Sibling
	gui.Parent            = playerGui

	splashGui = gui
	return gui
end

local function getViewportSize(): Vector2
	local camera = Workspace.CurrentCamera
	if camera then
		local vp = camera.ViewportSize
		if vp.X > 0 and vp.Y > 0 then
			return vp
		end
	end
	return Vector2.new(1024, 768)
end

local function spawnParticle(
	gui: ScreenGui,
	colors: { Color3 },
	originX: number,
	originY: number,
	scale: number
)
	-- Fan spread centred on "straight up" (−π/2), ±75°
	local baseAngle  = -math.pi / 2
	local halfSpread = math.rad(75)
	local angle      = baseAngle + (math.random() * 2 - 1) * halfSpread

	local distance = (110 + math.random() * 130) * scale
	local targetX  = originX + math.cos(angle) * distance
	-- Gravity feel: upward peak is roughly 60 % of travel then falls, so add
	-- a downward offset to the final Y so chunks "land" below their apex.
	local targetY  = originY + math.sin(angle) * distance + distance * 0.35

	local w = (7 + math.random() * 14) * scale
	local h = w * (0.5 + math.random() * 0.7)

	local color = colors[math.random(1, #colors)]

	local chunk                     = Instance.new("Frame")
	chunk.Name                      = "DirtChunk"
	chunk.AnchorPoint               = Vector2.new(0.5, 0.5)
	chunk.Position                  = UDim2.fromOffset(originX, originY)
	chunk.Size                      = UDim2.fromOffset(w, h)
	chunk.BackgroundColor3          = color
	chunk.BorderSizePixel           = 0
	chunk.ZIndex                    = 100
	chunk.Rotation                  = math.random(0, 360)
	chunk.Parent                    = gui

	local corner          = Instance.new("UICorner")
	corner.CornerRadius   = UDim.new(0.18, 0)
	corner.Parent         = chunk

	local travel = 0.40 + math.random() * 0.18
	local fade   = travel * 0.55

	TweenService:Create(chunk, TweenInfo.new(travel, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(targetX, targetY),
		Rotation = chunk.Rotation + math.random(-180, 180),
		Size     = UDim2.fromOffset(w * 0.45, h * 0.45),
	}):Play()

	task.delay(travel * 0.45, function()
		if not chunk.Parent then return end
		TweenService:Create(chunk, TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		}):Play()
	end)

	task.delay(travel + fade + 0.05, function()
		if chunk.Parent then chunk:Destroy() end
	end)
end

-- Sprays a small burst of dirt clods. Call on each successful timing-bar hit.
function DirtSplashUI.burst()
	local gui = getGui()
	local vp  = getViewportSize()

	local originX = vp.X * 0.5
	local originY = vp.Y * 0.84

	local count = 7 + math.random(0, 5)
	for i = 1, count do
		-- Very small stagger (0–40 ms) so they don't all fire the same frame.
		task.delay(math.random(0, 4) / 100, function()
			spawnParticle(gui, DIRT_COLORS, originX, originY, 1.0)
		end)
	end

	-- Extra tiny clods close to the origin for depth.
	for _ = 1, 3 do
		task.delay(math.random(0, 2) / 100, function()
			spawnParticle(gui, DIRT_COLORS,
				originX + math.random(-30, 30),
				originY + math.random(-8, 8),
				0.55
			)
		end)
	end
end

-- Sprays a large burst of golden dirt. Call when all required hits complete
-- and the phase transitions to "extra" (jackpot / "Found it!" moment).
function DirtSplashUI.jackpot()
	local gui = getGui()
	local vp  = getViewportSize()

	local originX = vp.X * 0.5
	local originY = vp.Y * 0.84

	-- Three staggered waves for a bigger, building feel.
	local waveDelays = { 0, 0.05, 0.12 }
	local waveCounts = { 10, 8, 7 }

	for w, delay in waveDelays do
		local count = waveCounts[w]
		task.delay(delay, function()
			for _ = 1, count do
				task.delay(math.random(0, 5) / 100, function()
					spawnParticle(gui, JACKPOT_COLORS,
						originX + math.random(-18, 18),
						originY + math.random(-6, 6),
						1.6
					)
				end)
			end
		end)
	end

	-- A handful of smaller brown clods for contrast / grittiness.
	for _ = 1, 6 do
		task.delay(math.random(0, 10) / 100, function()
			spawnParticle(gui, DIRT_COLORS,
				originX + math.random(-22, 22),
				originY + math.random(-10, 10),
				0.9
			)
		end)
	end
end

return DirtSplashUI
