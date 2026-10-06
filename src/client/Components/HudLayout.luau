--!strict
--[[
	HudLayout
	StarterPlayerScripts/Client/Components/HudLayout

	Where things may go at the top of the screen, so nothing placed top
	centre (sighting / Hunt banners, steal banners, the tutorial card,
	toasts) ever covers the camp panel's Lock button. On a wide screen the
	camp panel (top left) and the top-centre stack sit side by side; on a
	phone or a 4:3 tablet a centred box would overlap the panel, so the
	stack drops below it instead.

	  HudLayout.SetCampBounds(right?, bottom?)
	      PlotController: the camp panel's right and bottom edges in screen
	      px (AbsolutePosition space), or nil when it isn't shown.
	  HudLayout.CampClearance(widthPx, scale) -> number?
	      The camp panel's bottom edge (screen px, AbsolutePosition space) if
	      a box widthPx wide, centred on the screen, would overlap it
	      horizontally; nil when there's room beside it. Callers add their
	      own gap, like they do for NotificationController.ReservedBottom.
	  HudLayout.TopCentreBase(scale) -> number
	      Gui y (px from the very top of the screen, for IgnoreGuiInset
	      guis) just under Roblox's top bar and the HUD's Base/Eggs buttons,
	      which sit in the top-bar row.
	  HudLayout.TopCentreTop(origin, scale, widthPx) -> number
	      TopCentreBase, or lower when the box must clear the camp panel.
	      `origin` is any GuiBase2d whose AbsolutePosition is the gui's
	      (0, 0) (the ScreenGui itself, or a full-screen frame in it).
	  HudLayout.SetBottomReserve(px?) / HudLayout.BottomReserve() -> number
	      HudController: how far up from the bottom edge of the screen its
	      bottom-centre cluster (buff chips, cash, hotbar) reaches, in px.
	      Things in the middle of the screen (toasts, the tutorial card, the
	      camera viewfinder's readout) stay above it. Measured from the
	      bottom, so it means the same in every ScreenGui.
	  HudLayout.Changed
	      Fires when the camp bounds or the bottom reserve change.
	      NotificationController relays it as ReservationsChanged, so
	      everything that already re-places on that signal follows too.

	Tunables: Config.UI.Layout (TravelTop, TravelHeight, TopGap, EdgeMargin).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local layout = Config.UI.Layout

local HudLayout = {}

HudLayout.Changed = Signal.new()

local campRight: number? = nil
local campBottom: number? = nil
local bottomReserve = 0

function HudLayout.SetCampBounds(right: number?, bottom: number?)
	if right == campRight and bottom == campBottom then
		return
	end
	campRight = right
	campBottom = bottom
	HudLayout.Changed:Fire()
end

function HudLayout.SetBottomReserve(px: number?)
	local value = math.max(0, px or 0)
	if value == bottomReserve then
		return
	end
	bottomReserve = value
	HudLayout.Changed:Fire()
end

function HudLayout.BottomReserve(): number
	return bottomReserve
end

function HudLayout.CampClearance(widthPx: number, scale: number): number?
	local right = campRight
	local bottom = campBottom
	local camera = Workspace.CurrentCamera
	if not right or not bottom or not camera then
		return nil
	end
	local left = (camera.ViewportSize.X - widthPx) / 2
	if left >= right + layout.EdgeMargin * scale then
		return nil
	end
	return bottom
end

function HudLayout.TopCentreBase(scale: number): number
	local insetY = GuiService:GetGuiInset().Y
	local travelBottom = math.max(layout.TravelTop, layout.TravelTop * scale) + layout.TravelHeight * scale
	return math.max(insetY, travelBottom) + layout.TopGap * scale
end

function HudLayout.TopCentreTop(origin: GuiBase2d, scale: number, widthPx: number): number
	local top = HudLayout.TopCentreBase(scale)
	local clearance = HudLayout.CampClearance(widthPx, scale)
	if clearance then
		top = math.max(top, clearance - origin.AbsolutePosition.Y + layout.TopGap * scale)
	end
	return top
end

return HudLayout
