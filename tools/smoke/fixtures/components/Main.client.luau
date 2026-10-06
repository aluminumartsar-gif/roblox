--!strict
-- Exercises every builder in the new UI components (src/client/Components/UI
-- and Window, pulled in through include.txt) before any screen uses them:
--   bash tools/smoke/run.sh --fixture components
-- Expected: no failures. The harness then clicks every visible button.

local Players = game:GetService("Players")

local Components = script.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Window = require(Components:WaitForChild("Window"))
local Icon = require(Components:WaitForChild("Icon"))
local ScreenScale = require(Components:WaitForChild("ScreenScale"))

local C = Theme.Colors

-- Every font role and weight resolves.
for _, role in ipairs({ "Display", "Heading", "Body", "Notes", "Mono" }) do
	for _, weight in ipairs({ "Light", "Regular", "Medium", "SemiBold", "Bold", "Heavy" }) do
		Theme.Font(role, weight)
	end
end
Theme.RarityColor("Secret")
Theme.RarityColor("Epic")
Theme.RarityColor("NotARarity")
Theme.Mix(C.Ember, C.Moon, 0.5)

local window = Window.new({
	Name = "SmokeWindow",
	Title = "Smoke Test",
	Icon = "Shop",
	Size = Vector2.new(760, 470),
	Info = "Pages 0/7",
})
local opened = 0
window.OnOpen = function()
	opened += 1
end

local list = UI.ScrollList({ Layout = "List", Gap = 6, Parent = window.Body })
UI.Text({ Text = "Body text", Role = "Body", Parent = list })
UI.Text({ Text = "<b>Rich</b> heading", Role = "Heading", Parent = list })
UI.Title("Field Journal", 36, { Parent = list })
UI.Panel({ Rivets = true, Size = UDim2.fromOffset(120, 80), Parent = list })
UI.Card({ Accent = C.Ember, Parent = list })
UI.Inset({ Size = UDim2.fromOffset(200, 40), Parent = list })
UI.Paper({ Parent = list })
UI.Divider({ Color = C.Ember, Parent = list })
UI.Icon("Star", 24, { Parent = list })

local clicks = 0
local button = UI.Button({
	Text = "Buy egg",
	Icon = "Cash",
	Variant = "Cash",
	OnClick = function()
		clicks += 1
	end,
	Parent = list,
})
UI.SetButtonText(button, "Bought")
UI.SetButtonVariant(button, "Danger")
UI.SetButtonEnabled(button, false)
UI.SetButtonEnabled(button, true)
UI.SetButtonIcon(button, "Lock")
UI.SetButtonIcon(button, nil)
UI.SetButtonIcon(button, "Egg")
for _, variant in ipairs({ "Primary", "Secondary", "Danger", "Cash", "Moon", "Ghost" }) do
	UI.Button({ Text = variant, Variant = variant, Uppercase = false, Parent = list })
end

local tile = UI.IconButton({ Icon = "Book", Label = "Codex", OnClick = function() end, Parent = list })
UI.SetBadge(tile, true)
UI.SetBadge(tile, true, "3")
UI.SetBadge(tile, false)

local tabs = UI.new("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.fromOffset(400, 40), Parent = list }, {
	UI.List({ FillDirection = Enum.FillDirection.Horizontal, Padding = 4 }),
})
local tabA = UI.Tab({ Text = "All", Icon = "Star", OnClick = function() end, Parent = tabs })
local tabB = UI.Tab({ Text = "Rare", Color = C.Moon, Bar = "Left", Parent = tabs })
UI.SetTabSelected(tabA, true)
UI.SetTabSelected(tabB, false)

local _, box = UI.Input({ PlaceholderText = "Search cryptids", Parent = list })
box.Text = "yeti"
UI.Input({ PlaceholderText = "No icon", Icon = false, Parent = list })

local bar = UI.ProgressBar({ Text = "Hatching", Color = C.Moss, Parent = list })
UI.SetProgress(bar, 0.5)
UI.SetProgress(bar, 0.9, 0.3)
UI.SetProgress(bar, 0)

local pill = UI.Pill({ Text = "Owned", Color = C.Moss, Parent = list })
UI.SetPill(pill, "Soon", C.Ember)
local filled = UI.Pill({ Text = "Legendary", Filled = true, Color = Theme.RarityColor("Legendary"), Parent = list })
UI.SetPill(filled, "Mythic", Theme.RarityColor("Mythic"))

local grid = UI.ScrollList({ Layout = "Grid", CellSize = UDim2.fromOffset(100, 120), Size = UDim2.fromOffset(500, 260), Parent = list })
for i = 1, 6 do
	UI.Card({ Name = "Card" .. i, LayoutOrder = i, Parent = grid })
end
UI.ScrollList({ Direction = "X", Size = UDim2.fromOffset(500, 80), Parent = list })

-- Our own pixel-sized UI scaled for phones.
local hud = UI.new("ScreenGui", { Name = "SmokeHud", ResetOnSpawn = false, Parent = Players.LocalPlayer:WaitForChild("PlayerGui") })
local chip = UI.Card({ Size = UDim2.fromOffset(120, 40), Parent = hud })
UI.Scale(chip)
ScreenScale.Apply(UI.Panel({ Size = UDim2.fromOffset(200, 60), Parent = hud }))
Icon.addLeft(UI.Text({ Text = "Cash", Parent = hud }), "Cash", 20)

-- Open / close / reopen, a second window, the registry.
window:Open()
task.wait(1)
window:SetTitle("Renamed")
window:SetInfo("Pages 3/7")
window:SetInfo(nil)
window:Close()
task.wait(0.5)
window:Open()
local second = Window.new({ Name = "SmokeSecond", Title = "Second", Backdrop = false, Size = Vector2.new(400, 300) })
second:Open() -- closes the first
task.wait(0.5)
assert(Window.Get("SmokeWindow") == window, "Window.Get didn't find the window")
assert(not window:IsOpen(), "opening a second window didn't close the first")
second:Close()
task.wait(0.5)
window:Open() -- left open for the harness to click through
print(string.format("components fixture: built everything (opened %d times, %d clicks so far, any open: %s)",
	opened, clicks, tostring(Window.AnyOpen())))
