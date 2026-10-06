-- Shared PlayerGui lookups: bounded waits plus HUD open-button paths that survive
-- UIButton layout-stable wrappers (nested __UIButtonInner + relocated descendants).
--
-- Hardened against two Roblox quirks that bite ScreenGuis with ResetOnSpawn=true:
--   1) The engine may parent an empty ScreenGui into PlayerGui first and stream
--      descendants in a few network ticks later. Heavy popups (Shop/ItemShop have
--      100-300+ descendants under Container) can lose the race against a short
--      WaitForChild timeout during a busy first-join.
--   2) Each respawn destroys the old ScreenGui and clones a fresh one. A caller
--      that grabbed the original instance is now holding a parentless ghost; that
--      ghost will never receive Container, so the wait yields forever.
-- waitChild() re-resolves the live ScreenGui from PlayerGui by name whenever the
-- given parent goes orphaned, and waits for game:IsLoaded() before timing out so
-- heavy joins don't false-negative.

local Players = game:GetService("Players")

local DEFAULT_WAIT_SEC = 60
local POLL_STEP_SEC = 0.1

local GuiResolve = {}

local function getPlayerGui(): PlayerGui?
	local plr = Players.LocalPlayer
	if not plr then
		return nil
	end
	return plr:FindFirstChildOfClass("PlayerGui")
end

local function isOrphanedScreen(parent: Instance): boolean
	if not parent:IsA("ScreenGui") then
		return false
	end
	if parent.Parent == nil then
		return true
	end
	local playerGui = getPlayerGui()
	return playerGui ~= nil and parent.Parent ~= playerGui
end

local function resolveLiveScreen(originalName: string): ScreenGui?
	local playerGui = getPlayerGui()
	if not playerGui then
		return nil
	end
	local live = playerGui:FindFirstChild(originalName)
	if live and live:IsA("ScreenGui") then
		return live
	end
	return nil
end

local function waitForFirstSpawnSettled()
	-- Roblox wipes and re-clones every ResetOnSpawn=true ScreenGui on first
	-- character spawn. Scripts that grabbed a ScreenGui before that wipe end up
	-- holding a parentless ghost. Block until the character exists so the
	-- re-clone has already happened.
	local plr = Players.LocalPlayer
	if not plr then
		return
	end
	if not plr.Character then
		plr.CharacterAdded:Wait()
	end
end

function GuiResolve.waitChild(parent: Instance, childName: string, timeoutSec: number?): Instance?
	local timeout = if timeoutSec ~= nil then timeoutSec else DEFAULT_WAIT_SEC
	local screenName = if parent:IsA("ScreenGui") then parent.Name else nil
	local current: Instance = parent

	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	waitForFirstSpawnSettled()

	-- After first spawn the StarterGui re-clone may have replaced our ScreenGui;
	-- resolve to the live instance now before we start polling for its child.
	if screenName and isOrphanedScreen(current) then
		local fresh = resolveLiveScreen(screenName)
		if fresh then
			current = fresh
		end
	end

	local deadline = os.clock() + timeout
	while true do
		local existing = current:FindFirstChild(childName)
		if existing then
			return existing
		end

		if screenName and isOrphanedScreen(current) then
			local fresh = resolveLiveScreen(screenName)
			if fresh and fresh ~= current then
				current = fresh
				continue
			end
		end

		local remaining = deadline - os.clock()
		if remaining <= 0 then
			warn(
				("[GuiResolve] Timed out after %ds waiting for child %q under %s."):format(
					timeout,
					childName,
					current:GetFullName()
				)
			)
			return nil
		end

		local step = math.min(POLL_STEP_SEC, remaining)
		task.wait(step)
	end
end

--[[
	HUD icon pattern: Btn (Frame/ImageButton slot) ► Container (GuiButton overlay), or Btn is the GuiButton.
	After UIKit/UIAnimations reparent for layouts, Btn may wrap __UIButtonInner; Container may nest under Inner.
]]
function GuiResolve.sideToggleOpenButton(navRow: Instance, buttonName: string, timeoutSec: number?): GuiButton?
	local marker = GuiResolve.waitChild(navRow, buttonName, timeoutSec)
	if not marker then
		return nil
	end

	local container = marker:FindFirstChild("Container")
	if container and container:IsA("GuiButton") then
		return container
	end
	if marker:IsA("GuiButton") then
		return marker :: GuiButton
	end
	local inner = marker:FindFirstChild("__UIButtonInner")
	if inner and inner:IsA("GuiButton") then
		local nested = inner:FindFirstChild("Container")
		if nested and nested:IsA("GuiButton") then
			return nested
		end
		return inner
	end
	local anyBtn = marker:FindFirstChildWhichIsA("GuiButton", true)
	return if anyBtn then anyBtn :: GuiButton else nil
end

return GuiResolve
