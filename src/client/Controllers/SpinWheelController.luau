--!strict
--[[
	SpinWheelController
	StarterPlayerScripts/Client/Controllers/SpinWheelController

	The prize wheel, on the STUD kit's SpinWheel popup, opened from the HUD's
	Spin button (a copy of the Gift button HudController makes for us).

	  wheel     the kit's 6 prize slots, filled clockwise from the top with
	            Config.Retention.Spin.Prizes (icon + amount). Which of the
	            kit's three wheel colours is shown: Spin.WheelStyle.
	  SPIN      asks the server to spin. The SERVER picks the prize, gives it
	            and says which slot it was; we then turn the wheel to land on
	            that slot (a tick sound per slot passed, a fanfare at the
	            end) and show what you won.
	  +3 SPINS  buys the Extra Spins product (Robux; the server prompts).
	  top line  spins left, or the countdown to the next free spin.

	HUD: red "!" while a spin is ready; otherwise the button counts down to
	the next free one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Kit = require(Components:WaitForChild("Kit"))
local HudController = require(script.Parent:WaitForChild("HudController"))
local Retention = require(script.Parent:WaitForChild("DailyRewardsController"))

local SpinWheelController = {}

local SPIN = Config.Retention.Spin
local WHEEL_STYLES = { "SpinWheelPink", "SpinWheelOrange", "SpinWheelRainbow" }
local TICK_MIN_GAP = 0.04 -- seconds; stops the tick sound machine-gunning at full speed

type Slot = { item: ImageLabel, label: TextLabel?, angle: number }

local popup: Kit.Popup
local wheel: GuiObject? = nil
local slots: { Slot } = {}
local spinButton: GuiButton? = nil
local buyButton: GuiButton? = nil
local statusLabel: TextLabel? = nil
local spinning = false
local buying = false
local resultText: string? = nil -- shown on the top line after a spin, until the next one

local function spinState(): { [string]: any }?
	local s = Retention.GetState()
	return s and s.Spin
end

--- Spins available right now: bought ones, plus the free one once its time
--- has come (even if the server hasn't sent fresh state since).
local function spinsNow(spin: { [string]: any }?): number
	if not spin then
		return 0
	end
	local freeReady = (tonumber(spin.NextFreeAt) or 0) <= Retention.ServerNow()
	return (tonumber(spin.Extra) or 0) + (if freeReady then 1 else 0)
end

--------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------

local function renderSlots()
	local spin = spinState()
	local prizes = spin and spin.Prizes or {}
	for i, slot in ipairs(slots) do
		local prize = prizes[i]
		slot.item.Visible = prize ~= nil
		if prize then
			slot.item.Image = Config.Icons[prize.Icon] or ""
			Kit.SetText(slot.label, tostring(prize.Short or ""))
		end
	end
end

local function renderStatus()
	local spin = spinState()
	local spins = spinsNow(spin)
	local text: string
	if not spin then
		text = "Loading..."
	elseif not spin.Enabled then
		text = "The wheel is resting for now."
	elseif spinning then
		text = "Round and round..."
	elseif resultText then
		text = "You won " .. resultText .. "!"
	elseif spins > 0 then
		text = if spins == 1 then "You have 1 spin!" else string.format("You have %d spins!", spins)
	else
		local remaining = (tonumber(spin.NextFreeAt) or 0) - Retention.ServerNow()
		text = "Free spin in " .. Retention.FormatClock(remaining)
	end
	Kit.SetText(statusLabel, text)

	if spinButton then
		local label = if spinning then "..." elseif spins > 0 then string.format("SPIN (%d)", spins) else "NO SPINS"
		Kit.SetButtonText(spinButton, label)
		Kit.SetButtonEnabled(spinButton, spins > 0 and not spinning)
	end
	if buyButton then
		local product = Config.DevProducts.ExtraSpins
		Kit.SetButtonText(buyButton, string.format("+%d  %s", product.Count, Retention.PriceText("ExtraSpins")))
	end
end

local function renderHud()
	local spin = spinState()
	if not spin or not spin.Enabled then
		HudController.SetAlert("SpinBtn", false)
		HudController.SetCaption("SpinBtn", "Spin")
		return
	end
	local spins = spinsNow(spin)
	local readyNow = spins > 0
	HudController.SetAlert("SpinBtn", readyNow)
	if readyNow then
		HudController.SetCaption("SpinBtn", "Spin!")
	else
		HudController.SetCaption("SpinBtn", Retention.FormatClock((tonumber(spin.NextFreeAt) or 0) - Retention.ServerNow()))
	end
end

--------------------------------------------------------------------------
-- Spinning
--------------------------------------------------------------------------

--- Turns the wheel so slot `index` ends up under the pointer, ticking for
--- every slot that passes. Yields until it stops.
local function animateTo(index: number)
	local w = wheel
	local slot = slots[index]
	if not w or not slot then
		return
	end
	local segment = 360 / math.max(1, #slots)
	-- Land somewhere inside the slot, not always dead centre.
	local jitter = (math.random() - 0.5) * segment * 0.5
	local start = w.Rotation % 360
	w.Rotation = start
	local landing = (SPIN.PointerAngle - slot.angle + jitter - start) % 360
	local target = start + SPIN.ExtraTurns * 360 + landing

	local tween = TweenService:Create(w, TweenInfo.new(SPIN.SpinTime, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Rotation = target })
	local lastStep = math.floor(start / segment)
	local lastTick = 0
	local connection = RunService.RenderStepped:Connect(function()
		local step = math.floor(w.Rotation / segment)
		if step ~= lastStep then
			lastStep = step
			local now = os.clock()
			if now - lastTick >= TICK_MIN_GAP then
				lastTick = now
				Retention.Play("SpinTick")
			end
		end
	end)
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	w.Rotation = target % 360
end

local function spin()
	local s = spinState()
	if spinning or not s or spinsNow(s) <= 0 then
		if s and spinsNow(s) <= 0 then
			Retention.Play("Error")
		end
		return
	end
	spinning = true
	resultText = nil
	renderStatus()
	Retention.Play("UIClick")
	local result = Retention.Invoke("SpinWheel")
	if result and result.Ok and typeof(result.Index) == "number" then
		animateTo(result.Index)
		resultText = tostring(result.Text or "a prize")
		Retention.Play("SpinWin")
	end
	spinning = false
	renderStatus()
end

local function buySpins()
	if buying then
		return
	end
	buying = true
	Retention.Play("UIClick")
	Retention.Invoke("PromptPurchase", "Product", "ExtraSpins")
	buying = false
end

--------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------

--- Angle of a slot, in degrees clockwise from the top of the wheel.
local function slotAngle(item: GuiObject, wheelAspect: number): number
	local dx = (item.Position.X.Scale - 0.5) * wheelAspect
	local dy = item.Position.Y.Scale - 0.5
	return math.deg(math.atan2(dx, -dy)) % 360
end

local function build()
	local gui = Kit.Mount("SpinWheel")
	-- The kit ships this screen at DisplayOrder 0, under the HUD and the
	-- tutorial panel. Layer it like the other kit popups (the Daily screen's).
	local dailyTemplate = ReplicatedStorage:WaitForChild("UIKit"):WaitForChild("StarterGui"):WaitForChild("DailyRewards") :: ScreenGui
	gui.DisplayOrder = dailyTemplate.DisplayOrder
	local container = gui:WaitForChild("Container") :: GuiObject
	local content = Kit.Deep(container, "Content")
	if not content then
		warn("[SAC/Spin] the kit's SpinWheel screen has no Content frame")
		popup = Kit.Popup(gui)
		return
	end

	-- One wheel colour.
	local chosen: Instance? = nil
	for _, name in ipairs(WHEEL_STYLES) do
		local frame = content:FindFirstChild(name)
		if frame and frame:IsA("GuiObject") then
			local use = name == SPIN.WheelStyle
			frame.Visible = use
			if use then
				chosen = frame
			end
		end
	end
	if not chosen then
		chosen = content:FindFirstChild(WHEEL_STYLES[1])
		if chosen and chosen:IsA("GuiObject") then
			chosen.Visible = true
		end
	end

	-- The kit's wheel screen has no close button: borrow the Daily screen's.
	local closeTemplate = Kit.Deep(dailyTemplate, "CloseBtn")
	if closeTemplate then
		local close = closeTemplate:Clone()
		close.AnchorPoint = Vector2.new(1, 0)
		close.Position = UDim2.fromScale(0.97, 0.03)
		close.Size = UDim2.fromScale(0.07, 0.07)
		close.SizeConstraint = Enum.SizeConstraint.RelativeXX
		close.ZIndex = 10
		close.Parent = container
	end
	popup = Kit.Popup(gui)
	popup.OnOpen = function()
		resultText = nil
		renderSlots()
		renderStatus()
	end

	if not chosen then
		warn("[SAC/Spin] the kit's SpinWheel screen has no wheel")
		return
	end

	local bottom = chosen:FindFirstChild("BottomWheel")
	if bottom and bottom:IsA("GuiObject") then
		wheel = bottom
		local aspect = bottom:FindFirstChildOfClass("UIAspectRatioConstraint")
		local wheelAspect = if aspect then aspect.AspectRatio else 1
		for _, child in ipairs(bottom:GetChildren()) do
			if child.Name == "Item" and child:IsA("ImageLabel") then
				table.insert(slots, {
					item = child,
					label = child:FindFirstChildWhichIsA("TextLabel"),
					angle = slotAngle(child, wheelAspect),
				})
			end
		end
		-- Prize 1 is the slot nearest the top, then clockwise.
		table.sort(slots, function(a, b)
			return a.angle < b.angle
		end)
	end
	if #slots ~= #SPIN.Prizes then
		warn(string.format("[SAC/Spin] the wheel has %d slots but Config has %d prizes", #slots, #SPIN.Prizes))
	end

	-- Status line above the wheel.
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.AnchorPoint = Vector2.new(0.5, 1)
	status.Position = UDim2.fromScale(0.5, 0.02)
	status.Size = UDim2.fromScale(0.9, 0.09)
	status.FontFace = Font.new("rbxasset://fonts/families/FredokaOne.json")
	status.TextScaled = true
	status.TextColor3 = Color3.new(1, 1, 1)
	status.ZIndex = 5
	status.Text = ""
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(30, 24, 40)
	stroke.Parent = status
	status.Parent = chosen
	statusLabel = status

	-- SPIN on the left, +3 SPINS (Robux) on the right.
	local kitSpin = chosen:FindFirstChild("SpinBtn")
	if kitSpin and kitSpin:IsA("GuiButton") then
		local buy = kitSpin:Clone()
		buy.Name = "BuySpinsBtn"
		buy.Position = UDim2.new(0.75, 0, kitSpin.Position.Y.Scale, kitSpin.Position.Y.Offset)
		buy.Size = UDim2.new(kitSpin.Size.X.Scale * 0.85, 0, kitSpin.Size.Y.Scale * 0.85, 0)
		buy.Parent = chosen
		kitSpin.Position = UDim2.new(0.27, 0, kitSpin.Position.Y.Scale, kitSpin.Position.Y.Offset)
		spinButton = kitSpin
		buyButton = buy
		kitSpin.Activated:Connect(function()
			task.spawn(spin)
		end)
		buy.Activated:Connect(function()
			task.spawn(buySpins)
		end)
	end
end

function SpinWheelController.Open()
	if popup then
		popup:Open()
	end
end

function SpinWheelController.Start()
	build()
	HudController.Bind("SpinBtn", SpinWheelController.Open, "Spin", "Luck")
	HudController.SetAlert("SpinBtn", false)

	Retention.StateChanged:Connect(function()
		renderSlots()
		renderStatus()
		renderHud()
	end)
	if Retention.GetState() then
		renderSlots()
		renderStatus()
		renderHud()
	end

	task.spawn(function()
		while true do
			task.wait(1)
			renderHud()
			if popup and popup:IsOpen() and not spinning then
				renderStatus()
			end
		end
	end)
end

return SpinWheelController
