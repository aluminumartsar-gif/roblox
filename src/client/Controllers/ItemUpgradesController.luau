-- ItemUpgradesPopup: shovel station upgrades (luck, dig speed, walk speed).
-- Expects the ScreenGui from StarterGui (designed in Studio). Row frames can be
-- tagged with String attribute `ShovelUpgradeStat` = "luck" | "greenBar" | "walkSpeed",
-- or named with hints (e.g. luckRow, GreenBar, WalkSpeed).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local ShovelUpgradeConfig = require(ConfigFolder:WaitForChild("ShovelUpgradeConfig"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local UpgradePurchaseVFX = require(Components:WaitForChild("UpgradePurchaseVFX"))

local UIKit = script.Parent.Parent:WaitForChild("UIKit")
local Screen = require(UIKit:WaitForChild("Screen"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local ItemUpgradesController = {}

export type StatRow = {
	statId: ShovelUpgradeConfig.StatId,
	-- Main shop-style headline (e.g. "+25% Dig Multiplier"); never a label inside a buy button.
	promoLabel: TextLabel?,
	levelLabel: TextLabel?, -- optional dedicated "Level x / y" slot
	effectLabel: TextLabel?, -- optional extra line outside buttons (not used if same as promo)
	costLabel: TextLabel?, -- optional separate price label
	-- Optional "before → after" stat boxes (total bonus % at current level vs after one purchase).
	valueLabelCurrent: TextLabel?,
	valueLabelNext: TextLabel?,
	buyButton: GuiButton,
}

local screenHandle: Screen.ScreenHandle?
local rows: { StatRow } = {}
local statusLabel: TextLabel? = nil
local upgradeRequestRemote: RemoteEvent? = nil
local onManualClose: (() -> ())?
local isPanelOpen = false

local snapshot = {
	money = 0,
	rebirths = 0,
	shovelUpgrades = {
		luck = 0,
		greenBar = 0,
		walkSpeed = 0,
	},
	shovelUpgradeCosts = {
		luck = ShovelUpgradeConfig.getUpgradeCost("luck", 0, 0),
		greenBar = ShovelUpgradeConfig.getUpgradeCost("greenBar", 0, 0),
		walkSpeed = ShovelUpgradeConfig.getUpgradeCost("walkSpeed", 0, 0),
	},
}

local ROW_ATTR = "ShovelUpgradeStat"

local NAME_HINTS: { [ShovelUpgradeConfig.StatId]: { string } } = {
	luck = {
		"luckrow",
		"luck",
		"digluck",
		"dig_luck",
		"dig",
		"multiplier",
		"digmultiplier",
		"digmulti",
	},
	greenBar = {
		"greenbarrow",
		"greenbar",
		"green_bar",
		"barsize",
		"barrow",
		"green",
		"biggerbar",
	},
	walkSpeed = {
		"walkspeedrow",
		"walkspeed",
		"walk_speed",
		"speedrow",
		"speed",
		"walk",
	},
}

local function normalizeRowKey(s: string): string
	return (string.lower(s):gsub("%s+", ""):gsub("_", ""))
end

local function rowTitle(statId: ShovelUpgradeConfig.StatId): string
	if statId == "luck" then
		return "Dig luck"
	elseif statId == "greenBar" then
		return "Dig speed"
	end

	return "Walk speed"
end

-- Visible headline matching the designed UI ("Dig Multiplier", not the shorter rowTitle).
local function promoDisplayName(statId: ShovelUpgradeConfig.StatId): string
	if statId == "luck" then
		return "Dig Multiplier"
	elseif statId == "greenBar" then
		return "Dig Speed"
	end
	return "Walkspeed"
end

local function isDescendantOfGuiButton(inst: Instance): boolean
	local a: Instance? = inst
	while a and a ~= game do
		if a:IsA("GuiButton") then
			return true
		end
		a = a.Parent
	end
	return false
end

local function findDeepTextLabelExcludingButtons(frame: Instance, names: { string }): TextLabel?
	for _, d in frame:GetDescendants() do
		if d:IsA("TextLabel") and not isDescendantOfGuiButton(d) then
			for _, n in names do
				if d.Name == n then
					return d
				end
			end
		end
	end

	return nil
end

local function sortedTextLabelsOutsideButtons(frame: Instance): { TextLabel }
	local list: { TextLabel } = {}
	for _, d in frame:GetDescendants() do
		if d:IsA("TextLabel") and not isDescendantOfGuiButton(d) then
			table.insert(list, d)
		end
	end

	table.sort(list, function(a: TextLabel, b: TextLabel)
		local ap, bp = a.AbsolutePosition, b.AbsolutePosition
		if math.abs(ap.Y - bp.Y) > 4 then
			return ap.Y < bp.Y
		end
		return ap.X < bp.X
	end)

	return list
end

local function isBareNumericLabel(lab: TextLabel): boolean
	local t = (lab.Text:gsub("^%s+", ""):gsub("%s+$", ""))
	return string.match(t, "^%d+$") ~= nil
end

-- Value boxes often use plain digits or "12%" placeholders in Studio.
local function isBareStatPreviewNumberLabel(lab: TextLabel): boolean
	local t = (lab.Text:gsub("^%s+", ""):gsub("%s+$", ""))
	if string.match(t, "^%d+$") then
		return true
	end
	if string.match(t, "^%d+%%%s*$") then
		return true
	end
	return false
end

local PREVIEW_CURRENT_NAMES =
	{ "Current", "CurrentValue", "Before", "From", "Now", "Old", "Prev", "ValueCurrent", "LeftValue" }
local PREVIEW_NEXT_NAMES = { "Next", "NextValue", "After", "To", "New", "NextBonus", "ValueNext", "RightValue" }

local function reservedLabelSet(
	promo: TextLabel?,
	level: TextLabel?,
	effect: TextLabel?,
	cost: TextLabel?
): { [TextLabel]: boolean }
	local r: { [TextLabel]: boolean } = {}
	if promo then
		r[promo] = true
	end
	if level then
		r[level] = true
	end
	if effect then
		r[effect] = true
	end
	if cost then
		r[cost] = true
	end
	return r
end

local function findNamedPreviewLabel(frame: Instance, names: { string }, reserved: { [TextLabel]: boolean }): TextLabel?
	for _, n in names do
		local lab = findDeepTextLabelExcludingButtons(frame, { n })
		if lab and not reserved[lab] then
			return lab
		end
	end
	return nil
end

local function findBareNumericPreviewPair(
	frame: Instance,
	reserved: { [TextLabel]: boolean }
): (TextLabel?, TextLabel?)
	local labs: { TextLabel } = {}
	for _, d in frame:GetDescendants() do
		if d:IsA("TextLabel") and not isDescendantOfGuiButton(d) and not reserved[d :: TextLabel] then
			if isBareStatPreviewNumberLabel(d :: TextLabel) then
				table.insert(labs, d :: TextLabel)
			end
		end
	end
	if #labs < 2 then
		return nil, nil
	end

	table.sort(labs, function(a: TextLabel, b: TextLabel)
		local ap, bp = a.AbsolutePosition, b.AbsolutePosition
		if math.abs(ap.Y - bp.Y) > 6 then
			return ap.Y < bp.Y
		end
		return ap.X < bp.X
	end)

	local byY: { [number]: { TextLabel } } = {}
	for _, lab in labs do
		local y = math.floor(lab.AbsolutePosition.Y / 4 + 0.5) * 4
		local bucket = byY[y]
		if not bucket then
			bucket = {}
			byY[y] = bucket
		end
		table.insert(bucket, lab)
	end
	for _, group in byY do
		if #group >= 2 then
			table.sort(group, function(a, b)
				return a.AbsolutePosition.X < b.AbsolutePosition.X
			end)
			return group[1], group[2]
		end
	end

	return labs[1], labs[2]
end

local function findValuePreviewPair(
	frame: Instance,
	reserved: { [TextLabel]: boolean }
): (TextLabel?, TextLabel?)
	local cur = findNamedPreviewLabel(frame, PREVIEW_CURRENT_NAMES, reserved)
	local nxt = findNamedPreviewLabel(frame, PREVIEW_NEXT_NAMES, reserved)
	if cur and nxt and cur ~= nxt then
		return cur, nxt
	end
	return findBareNumericPreviewPair(frame, reserved)
end

local function setPreviewValueLabel(lab: TextLabel, valuePct: number)
	local raw = (lab.Text:gsub("^%s+", ""):gsub("%s+$", ""))
	if string.find(raw, "%%", 1, true) then
		lab.Text = ("%d%%"):format(valuePct)
	else
		lab.Text = tostring(valuePct)
	end
end

local function attachValuePreviewLabels(row: StatRow, frame: Instance): StatRow
	local reserved = reservedLabelSet(row.promoLabel, row.levelLabel, row.effectLabel, row.costLabel)
	local cur, nxt = findValuePreviewPair(frame, reserved)
	return {
		statId = row.statId,
		promoLabel = row.promoLabel,
		levelLabel = row.levelLabel,
		effectLabel = row.effectLabel,
		costLabel = row.costLabel,
		valueLabelCurrent = cur,
		valueLabelNext = nxt,
		buyButton = row.buyButton,
	}
end

local function pickPromoLabel(frame: Instance, statId: ShovelUpgradeConfig.StatId): TextLabel?
	local sortedOutside = sortedTextLabelsOutsideButtons(frame)

	for _, lab in sortedOutside do
		local low = string.lower(lab.Text)
		if statId == "luck" and string.find(low, "multiplier", 1, true) then
			return lab
		end
		if statId == "greenBar"
			and (
				(string.find(low, "green", 1, true) and string.find(low, "bar", 1, true))
				or (string.find(low, "dig", 1, true) and string.find(low, "speed", 1, true))
			)
		then
			return lab
		end
		if statId == "walkSpeed" and string.find(low, "walk", 1, true) then
			return lab
		end
	end

	local best: TextLabel? = nil
	local bestScore = -1
	for _, lab in sortedOutside do
		if isBareNumericLabel(lab) then
			-- preview digits (0 / 5), not the headline
		elseif string.find(lab.Text, "Level", 1, true) then
			-- dedicated level line, not promo
		else
			local score = #lab.Text * 10 + lab.TextSize
			if score > bestScore then
				bestScore = score
				best = lab
			end
		end
	end

	return best
end

local function findFirstTextButton(parent: Instance, names: { string }): TextButton?
	for _, n in names do
		local c = parent:FindFirstChild(n)
		if c and c:IsA("TextButton") then
			return c
		end
	end

	return nil
end

local function aggregatedGuiButtonText(btn: GuiButton): string
	local chunks = { string.lower(btn.Name) }
	if btn:IsA("TextButton") then
		table.insert(chunks, string.lower((btn :: TextButton).Text))
	end
	for _, d in btn:GetDescendants() do
		if d:IsA("TextLabel") then
			table.insert(chunks, string.lower((d :: TextLabel).Text))
		elseif d:IsA("TextButton") then
			table.insert(chunks, string.lower((d :: TextButton).Text))
		end
	end
	return table.concat(chunks, " ")
end

local function looksLikeRobuxPurchaseButton(btn: GuiButton): boolean
	local blob = aggregatedGuiButtonText(btn)
	return string.find(blob, "r%s*%$", 1) ~= nil
		or string.find(blob, "%$%s*r", 1) ~= nil
		or string.find(blob, "robux", 1, true) ~= nil
end

local function isUnderRobuxPurchaseButton(inst: Instance): boolean
	local p: Instance? = inst.Parent
	while p and p ~= game do
		if p:IsA("TextButton") or p:IsA("ImageButton") then
			if looksLikeRobuxPurchaseButton(p :: GuiButton) then
				return true
			end
		end
		p = p.Parent
	end
	return false
end

local function findFirstBuyControlLegacy(parent: Instance): GuiButton?
	for _, n in { "Buy", "Upgrade", "UpgradeBtn", "PurchaseBtn", "Button", "Cash", "Purchase" } do
		for _, d in parent:GetDescendants() do
			if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Name == n then
				local g = d :: GuiButton
				if not looksLikeRobuxPurchaseButton(g) then
					return g
				end
			end
		end
	end

	for _, d in parent:GetDescendants() do
		if d:IsA("TextButton") or d:IsA("ImageButton") then
			local g = d :: GuiButton
			if not looksLikeRobuxPurchaseButton(g) then
				return g
			end
		end
	end

	return nil
end

-- Prefer the in-game cash purchase control (template often uses ImageButton + labels, plus a Robux button).
local function findCashPurchaseButton(frame: Instance): GuiButton?
	local best: GuiButton? = nil
	local bestScore = -1

	local function consider(btn: GuiButton)
		if looksLikeRobuxPurchaseButton(btn) then
			return
		end

		local blob = aggregatedGuiButtonText(btn)
		local hasDollar = string.find(blob, "%$", 1, true) ~= nil
		local nm = string.lower(btn.Name)
		local hinted = string.find(nm, "cash", 1, true) or string.find(nm, "buy", 1, true)
			or string.find(nm, "coin", 1, true) or string.find(nm, "money", 1, true)
		local area = btn.AbsoluteSize.X * btn.AbsoluteSize.Y
		local score = area
		if hasDollar then
			score += 1e9
		end
		if hinted then
			score += 1e6
		end
		if score > bestScore then
			bestScore = score
			best = btn
		end
	end

	for _, d in frame:GetDescendants() do
		if d:IsA("TextButton") or d:IsA("ImageButton") then
			consider(d :: GuiButton)
		end
	end

	if best then
		return best
	end

	return findFirstBuyControlLegacy(frame)
end

-- Bind one Studio row: labels commonly used in the designed UI (never inside purchase buttons).
local function tryBindRow(frame: Instance, statId: ShovelUpgradeConfig.StatId): StatRow?
	if not (frame:IsA("Frame") or frame:IsA("CanvasGroup")) then
		return nil
	end

	local title = findDeepTextLabelExcludingButtons(frame, { "Title", "Name", "Label", "ItemName" })
	local levelLabel = findDeepTextLabelExcludingButtons(frame, { "Level", "LevelLabel", "Lvl" })
	local effectLabel = findDeepTextLabelExcludingButtons(frame, { "Effect", "Description", "Bonus", "Subtitle" })
	local costLabel = findDeepTextLabelExcludingButtons(frame, { "Cost", "Price", "Amount" })
	local buyButton = findCashPurchaseButton(frame)

	local promoLabel = title or effectLabel
	if not promoLabel then
		promoLabel = pickPromoLabel(frame, statId)
	end

	if not promoLabel or not buyButton then
		return nil
	end

	if effectLabel == promoLabel then
		effectLabel = nil
	end

	return attachValuePreviewLabels({
		statId = statId,
		promoLabel = promoLabel,
		levelLabel = levelLabel,
		effectLabel = effectLabel,
		costLabel = costLabel,
		buyButton = buyButton,
	}, frame)
end

local function tryBindRowFlexible(frame: Instance, statId: ShovelUpgradeConfig.StatId): StatRow?
	if not (frame:IsA("Frame") or frame:IsA("CanvasGroup")) then
		return nil
	end

	local levelLabel = findDeepTextLabelExcludingButtons(frame, { "Level", "LevelLabel", "CurrentLevel", "Lvl", "Current" })
	local effectLabel = findDeepTextLabelExcludingButtons(frame, { "Effect", "Description", "Bonus", "Subtitle", "Stat", "Multiplier" })
	local costLabel = findDeepTextLabelExcludingButtons(frame, { "Cost", "Price", "Amount", "CashCost", "MoneyCost" })

	if not costLabel then
		for _, d in frame:GetDescendants() do
			if
				d:IsA("TextLabel")
				and not isDescendantOfGuiButton(d)
				and string.find(d.Text, "%$", 1, true)
				and not isUnderRobuxPurchaseButton(d)
			then
				costLabel = d
				break
			end
		end
	end

	local promoLabel = pickPromoLabel(frame, statId)
	if not promoLabel then
		local titleTag = findDeepTextLabelExcludingButtons(frame, { "Title", "Name", "ItemName", "Header" })
		promoLabel = titleTag or effectLabel
	end

	if effectLabel == promoLabel then
		effectLabel = nil
	end

	local buyButton = findCashPurchaseButton(frame)
	if not promoLabel or not buyButton then
		return nil
	end

	return attachValuePreviewLabels({
		statId = statId,
		promoLabel = promoLabel,
		levelLabel = levelLabel,
		effectLabel = effectLabel,
		costLabel = costLabel,
		buyButton = buyButton,
	}, frame)
end

local function tryBindAnyRow(frame: Instance, statId: ShovelUpgradeConfig.StatId): StatRow?
	return tryBindRow(frame, statId) or tryBindRowFlexible(frame, statId)
end

local function statIdFromRowText(frame: Instance): ShovelUpgradeConfig.StatId?
	local blob = ""
	for _, d in frame:GetDescendants() do
		if d:IsA("TextLabel") then
			blob ..= " " .. string.lower(d.Text)
		end
	end

	if string.find(blob, "walk", 1, true) then
		return "walkSpeed"
	end
	if string.find(blob, "green", 1, true) and string.find(blob, "bar", 1, true) then
		return "greenBar"
	end
	if string.find(blob, "dig", 1, true) and string.find(blob, "multiplier", 1, true) then
		return "luck"
	end
	if string.find(blob, "dig", 1, true) then
		return "luck"
	end

	return nil
end

local function statFromFrame(frame: Instance): ShovelUpgradeConfig.StatId?
	local attr = frame:GetAttribute(ROW_ATTR)
	if type(attr) == "string" and ShovelUpgradeConfig.isStatId(attr) then
		return attr :: ShovelUpgradeConfig.StatId
	end

	local key = normalizeRowKey(frame.Name)
	for _, statId in ShovelUpgradeConfig.STAT_IDS do
		for _, hint in NAME_HINTS[statId] do
			if key == hint or string.find(key, hint, 1, true) then
				return statId
			end
		end
	end

	return statIdFromRowText(frame)
end

local function findCloseButton(screenGui: ScreenGui): GuiButton?
	local named = screenGui:FindFirstChild("CloseBtn", true)
	if named and named:IsA("GuiButton") then
		return named
	end

	for _, d in screenGui:GetDescendants() do
		if d.Name == "CloseBtn" and d:IsA("GuiButton") then
			return d
		end
	end

	return nil
end

local function isPanel(gui: Instance?): boolean
	if not gui or not gui:IsA("GuiObject") then
		return false
	end
	return gui:IsA("Frame")
		or gui:IsA("ImageLabel")
		or gui:IsA("ImageButton")
		or gui:IsA("CanvasGroup")
end

local SCROLL_NAME_HINTS: { [string]: boolean } = {
	scroll = true,
	scrollingframe = true,
	list = true,
	upgradelist = true,
	itemlist = true,
}

-- Studio often uses a Folder named "Container" for organization; treat like ItemShop's Frame root.
local POPUP_ROOT_NAMES = { "Container", "Main", "Panel", "Root", "Window" }

local function collectContainerRoots(inst: Instance): { GuiObject }
	local roots: { GuiObject } = {}
	if inst:IsA("GuiObject") then
		table.insert(roots, inst)
	elseif inst:IsA("Folder") then
		for _, ch in inst:GetChildren() do
			if ch:IsA("GuiObject") then
				table.insert(roots, ch)
			end
		end
	end
	return roots
end

local function tryResolveFromRoot(screenGui: ScreenGui, root: GuiObject): (GuiObject?, Instance?)
	local bg = root:FindFirstChild("Background")
	if isPanel(bg) then
		return root, bg
	end

	local scrollInRoot: ScrollingFrame? = nil
	for _, d in root:GetDescendants() do
		if d:IsA("ScrollingFrame") then
			if SCROLL_NAME_HINTS[string.lower(d.Name)] then
				scrollInRoot = d
				break
			end
			if not scrollInRoot then
				scrollInRoot = d
			end
		end
	end

	if scrollInRoot then
		local bgHost: GuiObject = root
		local node: Instance? = scrollInRoot.Parent
		while node and node ~= root and node ~= screenGui do
			if node:IsA("GuiObject") and isPanel(node) then
				bgHost = node :: GuiObject
				break
			end
			node = node.Parent
		end
		return root, bgHost
	end

	return nil, nil
end

-- Any nested "Background" panel; shallowest wins (main panel, not nested badges).
local function resolveByNamedBackgroundPanel(screenGui: ScreenGui): (GuiObject?, Instance?)
	local bestBg: GuiObject? = nil
	local bestDepth = math.huge
	for _, d in screenGui:GetDescendants() do
		if d.Name ~= "Background" or not isPanel(d) or not d:IsA("GuiObject") then
			continue
		end
		local depth = 0
		local cur: Instance? = d
		while cur and cur.Parent ~= screenGui do
			depth += 1
			cur = cur.Parent
		end
		if cur == nil then
			continue
		end
		if depth >= bestDepth then
			continue
		end
		bestDepth = depth
		bestBg = d :: GuiObject
	end
	if not bestBg then
		return nil, nil
	end
	local top = bestBg
	while top.Parent ~= screenGui and top.Parent do
		top = top.Parent :: GuiObject
	end
	return top, bestBg
end

-- Fallback: lone top-level GuiObject (no named popup root folder), optionally with Background child panel.
local function resolveViaSingleRootChild(screenGui: ScreenGui): (GuiObject?, Instance?)
	local top: GuiObject?
	for _, ch in screenGui:GetChildren() do
		if not ch:IsA("GuiObject") then
			continue
		end
		if top ~= nil then
			return nil, nil
		end
		top = ch :: GuiObject
	end
	if top == nil then
		return nil, nil
	end

	local bg = top:FindFirstChild("Background")
	if isPanel(bg) then
		return top, bg
	end

	return top, top
end

-- First ScrollingFrame under the popup; prefers common names so we don't grab a stray mini-scroll.
local function findPreferredScrollingFrame(screenGui: ScreenGui): ScrollingFrame?
	local fallback: ScrollingFrame? = nil
	for _, d in screenGui:GetDescendants() do
		if d:IsA("ScrollingFrame") then
			if SCROLL_NAME_HINTS[string.lower(d.Name)] then
				return d
			end
			if not fallback then
				fallback = d
			end
		end
	end
	return fallback
end

local function countRowLikeChildren(parent: Instance): number
	local n = 0
	for _, ch in parent:GetChildren() do
		if ch:IsA("Frame") or ch:IsA("CanvasGroup") then
			n += 1
		end
	end
	return n
end

-- Templates that use a plain Frame + UIListLayout (no ScrollingFrame) for upgrade rows.
local function findRowListLayoutHostUnder(root: Instance, navBar: Frame?): GuiObject?
	local best: GuiObject? = nil
	local bestScore = 0
	for _, d in root:GetDescendants() do
		if not (d:IsA("Frame") or d:IsA("CanvasGroup")) then
			continue
		end
		if navBar and d:IsDescendantOf(navBar) then
			continue
		end
		if d:FindFirstChildOfClass("UIListLayout") == nil then
			continue
		end
		local score = countRowLikeChildren(d)
		if score >= 1 and score > bestScore then
			bestScore = score
			best = d :: GuiObject
		end
	end
	return best
end

local function topContainerHolding(screenGui: ScreenGui, inst: Instance): GuiObject
	for _, ch in screenGui:GetChildren() do
		if ch:IsA("GuiObject") and inst:IsDescendantOf(ch) then
			return ch :: GuiObject
		end
	end
	return inst :: GuiObject
end

-- When there is no ScrollingFrame at all, find the list that holds row cards.
local function resolveViaRowListLayout(screenGui: ScreenGui): (GuiObject?, GuiObject?)
	local bestHost: GuiObject? = nil
	local bestScore = 0
	for _, d in screenGui:GetDescendants() do
		if not (d:IsA("Frame") or d:IsA("CanvasGroup")) then
			continue
		end
		if d:FindFirstChildOfClass("UIListLayout") == nil then
			continue
		end
		local score = countRowLikeChildren(d)
		if score >= 1 and score > bestScore then
			bestScore = score
			bestHost = d :: GuiObject
		end
	end
	if not bestHost then
		return nil, nil
	end
	local topContainer = topContainerHolding(screenGui, bestHost)
	local bgHost: GuiObject = bestHost
	local node: Instance? = bestHost.Parent
	while node and node ~= screenGui do
		if node:IsA("GuiObject") and isPanel(node) then
			bgHost = node :: GuiObject
			break
		end
		node = node.Parent
	end
	return topContainer, bgHost
end

local function resolveContainerAndBackground(screenGui: ScreenGui): (GuiObject?, Instance?)
	for _, hintName in POPUP_ROOT_NAMES do
		local inst = screenGui:FindFirstChild(hintName)
		if inst then
			for _, root in collectContainerRoots(inst) do
				local c, bg = tryResolveFromRoot(screenGui, root)
				if c and bg then
					return c, bg
				end
			end
		end
	end

	for _, child in screenGui:GetChildren() do
		if child:IsA("GuiObject") then
			local bg = child:FindFirstChild("Background")
			if isPanel(bg) then
				return child :: GuiObject, bg
			end
			if child:FindFirstChildWhichIsA("ScrollingFrame", true) then
				return child :: GuiObject, child
			end
		end
	end

	local rootBg = screenGui:FindFirstChild("Background")
	if isPanel(rootBg) then
		local parent = rootBg.Parent
		if parent and parent:IsA("GuiObject") and parent ~= screenGui then
			return parent :: GuiObject, rootBg
		end
		return rootBg :: GuiObject, rootBg
	end

	local scroll = findPreferredScrollingFrame(screenGui)
	if scroll then
		local topContainer: GuiObject? = nil
		for _, ch in screenGui:GetChildren() do
			if ch:IsA("GuiObject") and scroll:IsDescendantOf(ch) then
				topContainer = ch :: GuiObject
				break
			end
		end

		if not topContainer then
			local p = scroll.Parent
			if p and p:IsA("GuiObject") then
				topContainer = p :: GuiObject
			else
				topContainer = scroll
			end
		end

		local bgHost: GuiObject = topContainer
		local node: Instance? = scroll.Parent
		while node and node ~= screenGui do
			if node:IsA("GuiObject") and isPanel(node) then
				bgHost = node :: GuiObject
				break
			end
			node = node.Parent
		end

		return topContainer, bgHost
	end

	local listContainer, listBg = resolveViaRowListLayout(screenGui)
	if listContainer and listBg then
		return listContainer, listBg
	end

	local namedContainer, namedBg = resolveByNamedBackgroundPanel(screenGui)
	if namedContainer and namedBg then
		return namedContainer, namedBg
	end

	local singleRoot, singleBg = resolveViaSingleRootChild(screenGui)
	if singleRoot and singleBg then
		return singleRoot, singleBg
	end

	return nil, nil
end

local function findNavBar(root: Instance): Frame?
	local nav = root:FindFirstChild("NavBar")
	if nav and nav:IsA("Frame") then
		return nav
	end
	return nil
end

-- Prefer ScrollingFrame; otherwise a Frame/CanvasGroup with UIListLayout + row cards (no scroll in hierarchy).
local function findScrollOrRowListHost(root: Instance): Instance
	local navBar = findNavBar(root)

	local function okRegion(inst: Instance): boolean
		if not navBar then
			return true
		end
		return not inst:IsDescendantOf(navBar)
	end

	for _, n in { "Scroll", "ScrollingFrame", "List", "UpgradeList", "ItemList", "Content" } do
		local c = root:FindFirstChild(n)
		if c and c:IsA("ScrollingFrame") and okRegion(c) then
			return c
		end
	end

	for _, ch in root:GetChildren() do
		if ch:IsA("ScrollingFrame") and okRegion(ch) then
			return ch
		end
	end

	for _, d in root:GetDescendants() do
		if d:IsA("ScrollingFrame") and okRegion(d) then
			return d
		end
	end

	local listHost = findRowListLayoutHostUnder(root, navBar)
	if listHost then
		return listHost
	end

	return root
end

-- Prefer a scrolling list under Background but outside NavBar (if any); else a list-layout row host.
local function findScrollHost(root: Instance): Instance
	return findScrollOrRowListHost(root)
end

local function ensureUiListLayout(scroll: Instance): UIListLayout
	local lay = scroll:FindFirstChildOfClass("UIListLayout")
	if lay then
		return lay
	end

	lay = Instance.new("UIListLayout")
	lay.Name = "List"
	lay.Padding = UDim.new(0, 10)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = scroll
	return lay
end

local function setStatus(text: string, isError: boolean)
	local label = statusLabel
	if not label then
		return
	end

	label.Text = text
	label.TextColor3 = if isError then Color3.fromRGB(220, 80, 80) else Color3.fromRGB(80, 160, 90)
end

-- Child TextLabels with Active = true steal clicks from ImageButton parents.
-- GuiButton.Active = false disables input entirely, so maxed rows would ignore clicks (no feedback).
local function prepareBuyButtonForInput(btn: GuiButton)
	btn.Active = true
	local anyBtn = btn :: any
	if typeof(anyBtn.Interactable) == "boolean" then
		anyBtn.Interactable = true
	end
	for _, d in btn:GetDescendants() do
		if d:IsA("TextLabel") then
			d.Active = false
		end
	end
end

local function refreshRow(statId: ShovelUpgradeConfig.StatId)
	local level = ShovelUpgradeConfig.clampLevelForStat(statId, snapshot.shovelUpgrades[statId])
	-- Always derive next cost from current level (partial payloads often omit shovelUpgradeCosts).
	local cost = ShovelUpgradeConfig.getUpgradeCost(statId, level, snapshot.rebirths)
	snapshot.shovelUpgradeCosts[statId] = cost
	local maxed = ShovelUpgradeConfig.isStatMaxed(statId, level)

	for _, row in rows do
		if row.statId == statId then
			local bonusPct = ShovelUpgradeConfig.getTotalBonusPercentForStat(statId, level)
			local headline = ("+%d%% %s"):format(bonusPct, promoDisplayName(statId))
			local secondary = ("+%d%% %s"):format(bonusPct, rowTitle(statId))

			if row.promoLabel then
				row.promoLabel.Text = headline
			end
			if row.levelLabel and row.levelLabel ~= row.promoLabel then
				if statId == "walkSpeed" then
					row.levelLabel.Text = ("Level %d / %d"):format(level, ShovelUpgradeConfig.MAX_WALK_SPEED_LEVEL)
				else
					row.levelLabel.Text = ("Level %d"):format(level)
				end
			end
			if row.effectLabel and row.effectLabel ~= row.promoLabel then
				row.effectLabel.Text = secondary
			end
			if row.valueLabelCurrent then
				setPreviewValueLabel(row.valueLabelCurrent, bonusPct)
			end
			if row.valueLabelNext then
				local nextBonus = if maxed
					then bonusPct
					else ShovelUpgradeConfig.getTotalBonusPercentForStat(statId, level + 1)
				setPreviewValueLabel(row.valueLabelNext, nextBonus)
			end
			if maxed then
				local cl = row.costLabel
				if cl then
					cl.Text = "MAX"
				end
				if row.buyButton:IsA("TextButton") then
					row.buyButton.Text = "Maxed"
				else
					local priceLbl: TextLabel? = nil
					for _, d in row.buyButton:GetDescendants() do
						if d:IsA("TextLabel") and string.find(d.Text, "%$", 1, true) then
							priceLbl = d
							break
						end
					end
					if not priceLbl then
						for _, d in row.buyButton:GetDescendants() do
							if d:IsA("TextLabel") then
								priceLbl = d
								break
							end
						end
					end
					if priceLbl then
						priceLbl.Text = "Maxed"
					end
				end
				row.buyButton.AutoButtonColor = false
			else
				local cl = row.costLabel
				if cl then
					cl.Text = FormatUtil.money(cost)
				end
				if row.buyButton:IsA("TextButton") then
					row.buyButton.Text = FormatUtil.money(cost)
				else
					local priceLbl: TextLabel? = nil
					for _, d in row.buyButton:GetDescendants() do
						if d:IsA("TextLabel") and string.find(d.Text, "%$", 1, true) then
							priceLbl = d
							break
						end
					end
					if not priceLbl then
						for _, d in row.buyButton:GetDescendants() do
							if d:IsA("TextLabel") then
								priceLbl = d
								break
							end
						end
					end
					if priceLbl then
						priceLbl.Text = FormatUtil.money(cost)
					end
				end
				row.buyButton.AutoButtonColor = true
			end
			prepareBuyButtonForInput(row.buyButton)
			break
		end
	end
end

function ItemUpgradesController.applyEconomyPayload(payload: any)
	if type(payload) ~= "table" then
		return
	end

	if payload.money ~= nil then
		snapshot.money = math.floor(tonumber(payload.money) or snapshot.money)
	end
	if payload.rebirths ~= nil then
		snapshot.rebirths = tonumber(payload.rebirths) or snapshot.rebirths
	end

	local up = payload.shovelUpgrades
	if type(up) == "table" then
		snapshot.shovelUpgrades.luck = ShovelUpgradeConfig.clampLevelForStat("luck", up.luck)
		snapshot.shovelUpgrades.greenBar = ShovelUpgradeConfig.clampLevelForStat("greenBar", up.greenBar)
		snapshot.shovelUpgrades.walkSpeed = ShovelUpgradeConfig.clampLevelForStat("walkSpeed", up.walkSpeed)
	end

	for _, sid in ShovelUpgradeConfig.STAT_IDS do
		refreshRow(sid)
	end
end

function ItemUpgradesController.refreshUI()
	for _, statId in ShovelUpgradeConfig.STAT_IDS do
		refreshRow(statId)
	end
	setStatus("", false)
end

function ItemUpgradesController.open()
	if screenHandle then
		ItemUpgradesController.refreshUI()
		isPanelOpen = true
		screenHandle.open()
	end
end

function ItemUpgradesController.close()
	if screenHandle then
		screenHandle.close()
	end
end

function ItemUpgradesController.isOpen(): boolean
	return isPanelOpen
end

function ItemUpgradesController.setManualCloseHandler(handler: () -> ())
	onManualClose = handler
end

local function wireBuy(row: StatRow)
	prepareBuyButtonForInput(row.buyButton)

	local lastRequestAt = 0.0
	local function requestPurchase()
		local now = os.clock()
		if now - lastRequestAt < 0.2 then
			return
		end
		lastRequestAt = now

		local statId = row.statId
		local level = ShovelUpgradeConfig.clampLevelForStat(statId, snapshot.shovelUpgrades[statId])
		if ShovelUpgradeConfig.isStatMaxed(statId, level) then
			setStatus("Already maxed.", true)
			return
		end

		if not upgradeRequestRemote then
			warn("[ItemUpgrades] ShovelUpgradeRequest remote missing.")
			setStatus("Can't upgrade right now.", true)
			return
		end

		setStatus("", false)
		upgradeRequestRemote:FireServer(statId)
	end

	row.buyButton.Activated:Connect(requestPurchase)
	row.buyButton.MouseButton1Click:Connect(requestPurchase)
end

function ItemUpgradesController.start()
	if screenHandle then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = playerGui:WaitForChild("ItemUpgradesPopup") :: ScreenGui
	local waitedContainer = GuiResolve.waitChild(screenGui, "Container")
	if not waitedContainer then
		warn('[ItemUpgrades] Expected ScreenGui "ItemUpgradesPopup" with child "Container". Upgrade UI disabled.')
		return
	end

	if waitedContainer.Parent and waitedContainer.Parent:IsA("ScreenGui") then
		screenGui = waitedContainer.Parent :: ScreenGui
	end

	local container, bg = resolveContainerAndBackground(screenGui)
	if not container or not bg then
		warn(
			"[ItemUpgrades] Could not resolve layout. Expected ItemUpgradesPopup > Container > Background (Frame or ImageLabel), "
				.. "or a Frame with a ScrollingFrame. Match ItemShopPopup structure if unsure."
		)
		return
	end

	local closeBtn = findCloseButton(screenGui)
	local navBar = findNavBar(bg)

	local contentHost = bg:FindFirstChild("UpgradeContent") :: Frame?
	if not contentHost then
		contentHost = Instance.new("Frame")
		contentHost.Name = "UpgradeContent"
		contentHost.BackgroundTransparency = 1
		if navBar then
			contentHost.Position = UDim2.new(0.04, 0, 0.14, 0)
			contentHost.Size = UDim2.new(0.92, 0, 0.78, 0)
		else
			contentHost.Size = UDim2.new(1, -24, 1, -24)
			contentHost.Position = UDim2.new(0, 12, 0, 12)
		end
		contentHost.Parent = bg
	end

	local sl = contentHost:FindFirstChild("Status") :: TextLabel?
	if not sl then
		sl = Instance.new("TextLabel")
		sl.Name = "Status"
		sl.BackgroundTransparency = 1
		sl.Font = Enum.Font.GothamMedium
		sl.TextSize = 14
		sl.TextXAlignment = Enum.TextXAlignment.Left
		sl.Text = ""
		sl.TextColor3 = Color3.fromRGB(80, 160, 90)
		sl.Size = UDim2.new(1, -8, 0, 22)
		sl.Position = UDim2.new(0, 4, 0, 0)
		sl.LayoutOrder = 0
		sl.Parent = contentHost
	end
	statusLabel = sl

	local scroll = findScrollHost(bg)
	if scroll == bg then
		scroll = contentHost:FindFirstChild("Scroll") :: ScrollingFrame?
		if not scroll then
			scroll = Instance.new("ScrollingFrame")
			scroll.Name = "Scroll"
			scroll.BackgroundTransparency = 1
			scroll.BorderSizePixel = 0
			scroll.ScrollBarThickness = 6
			scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
			scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
			scroll.Size = UDim2.new(1, 0, 1, -28)
			scroll.Position = UDim2.new(0, 0, 0, 26)
			scroll.Parent = contentHost
		end
	end

	local listHost = scroll
	if listHost:IsA("ScrollingFrame") or listHost:IsA("Frame") or listHost:IsA("CanvasGroup") then
		ensureUiListLayout(listHost)
		RunService.Heartbeat:Wait()
	end

	upgradeRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.SHOVEL_UPGRADE_REQUEST_REMOTE
	)

	local upgradeResultRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.SHOVEL_UPGRADE_RESULT_REMOTE
	)

	upgradeResultRemote.OnClientEvent:Connect(function(result: any)
		if type(result) ~= "table" then
			return
		end

		if result.success then
			setStatus("", false)
			local cost = tonumber(result.cost)
			if cost and cost > 0 then
				UpgradePurchaseVFX.play(screenGui, cost)
			end
		else
			setStatus(if type(result.message) == "string" then result.message else "Couldn't upgrade.", true)
		end

		if result.shovelUpgrades and type(result.shovelUpgrades) == "table" then
			ItemUpgradesController.applyEconomyPayload({
				shovelUpgrades = result.shovelUpgrades,
				money = result.money,
			})
		end
	end)

	rows = {}
	local bound: { [ShovelUpgradeConfig.StatId]: boolean } = {
		luck = false,
		greenBar = false,
		walkSpeed = false,
	}

	local rowFrames: { Instance } = {}
	if listHost:IsA("ScrollingFrame") or listHost:IsA("Frame") or listHost:IsA("CanvasGroup") then
		for _, ch in listHost:GetChildren() do
			if ch:IsA("Frame") or ch:IsA("CanvasGroup") then
				table.insert(rowFrames, ch)
			end
		end

		-- Studio often wraps cards: host > Holder > three cards
		if #rowFrames == 1 then
			local holder = rowFrames[1]
			local nested: { Instance } = {}
			for _, ch in holder:GetChildren() do
				if ch:IsA("Frame") or ch:IsA("CanvasGroup") then
					table.insert(nested, ch)
				end
			end
			if #nested > 0 then
				rowFrames = nested
			end
		end

		table.sort(rowFrames, function(a, b)
			local ga, gb = a :: GuiObject, b :: GuiObject
			if ga.LayoutOrder ~= gb.LayoutOrder then
				return ga.LayoutOrder < gb.LayoutOrder
			end
			return a.Name < b.Name
		end)
	end

	for _, frame in rowFrames do
		local statId = statFromFrame(frame)
		if statId and not bound[statId] then
			local row = tryBindAnyRow(frame, statId)
			if row then
				bound[statId] = true
				table.insert(rows, row)
				wireBuy(row)
			end
		end
	end

	for index, statId in ipairs(ShovelUpgradeConfig.STAT_IDS) do
		if not bound[statId] then
			local frame = rowFrames[index]
			if frame then
				local row = tryBindAnyRow(frame, statId)
				if row then
					bound[statId] = true
					table.insert(rows, row)
					wireBuy(row)
				end
			end
		end
	end

	for _, statId in ShovelUpgradeConfig.STAT_IDS do
		if not bound[statId] then
			warn(
				("[ItemUpgrades] No row bound for %s. Add a frame with attribute %s=%q or rename the row (e.g. luckRow).")
					:format(statId, ROW_ATTR, statId)
			)
		end
	end

	ItemUpgradesController.refreshUI()

	local dummyBtn = Instance.new("ImageButton")
	dummyBtn.Visible = false
	dummyBtn.Parent = screenGui

	screenHandle = Screen.bind({
		guiName = "ItemUpgradesPopup",
		screen = screenGui,
		container = container,
		openButton = dummyBtn,
		closeButton = nil,
	})

	if closeBtn then
		closeBtn.Activated:Connect(function()
			if onManualClose then
				onManualClose()
			end
			if screenHandle then
				screenHandle.close()
			end
		end)
	end

	screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if not screenGui.Enabled then
			isPanelOpen = false
		end
	end)
end

return ItemUpgradesController
