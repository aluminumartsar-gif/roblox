-- Index ScreenGui controller.
-- SideButtons = one button per variant (Normal → Candy, 8 total).
-- All 84 brainrots are always shown. Switching variant changes what
-- "found" means on each card:
--   Normal → card is lit if foundBrainrots[id]
--   Any other variant → card is lit if foundBrainrotVariants[id][variantId]
-- Search box filters by name. TopContents shows "X / 84 Found" for the
-- active variant view. Variant-dot badges on each card always reflect every
-- variant's found status regardless of the active filter.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder   = Shared:WaitForChild("Util")

local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local VariantConfig  = require(ConfigFolder:WaitForChild("VariantConfig"))
local EconomyConfig  = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local UIKit      = script.Parent.Parent:WaitForChild("UIKit")
local Screen         = require(UIKit:WaitForChild("Screen"))
local GuiResolve     = require(UIKit:WaitForChild("GuiResolve"))

local Components          = script.Parent.Parent:WaitForChild("Components")
local ThumbnailBounds     = require(Components:WaitForChild("ThumbnailBounds"))
local BrainrotVisualFactory = require(UtilFolder:WaitForChild("BrainrotVisualFactory"))

local BRAINROTS_FOLDER = ReplicatedStorage:WaitForChild("Brainrots")
-- Slight 3/4 angle: camera is to the left of the model and above, matching the reference
local THUMB_LOOK  = Vector3.new(-0.32, -0.14, -1).Unit
local THUMB_FOV   = 28
local THUMB_PAD   = 1.18

local IndexController = {}

-- ── Per-variant text gradients ───────────────────────────────────────────────
-- nil = keep the pack's original gradient (Gold and Diamond are already correct).
-- All others replace whatever the pack had with the right colours.
local VARIANT_TEXT_GRADIENT: { [string]: ColorSequence? } = {
	Normal   = ColorSequence.new(Color3.fromRGB(248, 244, 240)),   -- solid off-white
	Gold     = nil,                                                 -- keep pack gradient
	Diamond  = nil,                                                 -- keep pack gradient
	Lava     = ColorSequence.new({
		ColorSequenceKeypoint.new(0,    Color3.fromRGB(255, 210,  60)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255,  90,  20)),
		ColorSequenceKeypoint.new(1,    Color3.fromRGB(200,  30,   5)),
	}),
	Rainbow  = ColorSequence.new({
		ColorSequenceKeypoint.new(0,    Color3.fromRGB(255,  60,  60)),
		ColorSequenceKeypoint.new(0.18, Color3.fromRGB(255, 180,  30)),
		ColorSequenceKeypoint.new(0.36, Color3.fromRGB( 80, 230,  80)),
		ColorSequenceKeypoint.new(0.54, Color3.fromRGB( 40, 200, 255)),
		ColorSequenceKeypoint.new(0.72, Color3.fromRGB(160,  80, 255)),
		ColorSequenceKeypoint.new(1,    Color3.fromRGB(255,  80, 180)),
	}),
	Galaxy   = ColorSequence.new({
		ColorSequenceKeypoint.new(0,    Color3.fromRGB(210, 170, 255)),
		ColorSequenceKeypoint.new(0.5,  Color3.fromRGB(130,  70, 220)),
		ColorSequenceKeypoint.new(1,    Color3.fromRGB( 70,  30, 170)),
	}),
	Bloodrot = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(230,  50,  50)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(170,  10,  10)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(100,   0,   0)),
	}),
	Candy    = ColorSequence.new({
		ColorSequenceKeypoint.new(0,    Color3.fromRGB(255, 140, 210)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255,  90, 170)),
		ColorSequenceKeypoint.new(1,    Color3.fromRGB(255, 190, 235)),
	}),
}

-- ── Variant list (all variants, Normal first then ascending rank) ─────────────

local ALL_VARIANTS: { typeof(VariantConfig.Pool[1]) } = {}
for _, v in VariantConfig.Pool do
	table.insert(ALL_VARIANTS, v)
end
table.sort(ALL_VARIANTS, function(a, b)
	return a.rarityRank < b.rarityRank
end)

-- ── Colour constants ──────────────────────────────────────────────────────────

local CARD_BG       = Color3.fromRGB(22, 26, 44)   -- dark navy behind every model
local LOCKED_STROKE = Color3.fromRGB(55, 58, 80)
local LOCKED_TEXT   = Color3.fromRGB(90, 95, 120)

-- The fraction of ItemButton height taken by the model viewport.
-- Matches the TextLabel Position.Y (0.78) from the original pack template.
local VIEWPORT_HEIGHT = 0.78

-- Grid layout constants.
-- CellSize.X uses scale (1/NUM_COLS) so cards always fill the row.
-- Height is driven by UIAspectRatioConstraint on each card — no manual calculation needed.
local NUM_COLS   = 7
local CARD_AR    = 112 / 136   -- width / height of original template card

-- ── State ─────────────────────────────────────────────────────────────────────

type CardState = {
	frame    : Frame,
	brainrot : typeof(BrainrotConfig.Pool[1]),
}

local cards: { CardState } = {}

-- Active variant filter — changes what "found" means for card display
local activeVariantId = VariantConfig.NORMAL_ID  -- default = "Normal"
local searchText      = ""

-- Cached last sync payload so we can refresh when the variant filter changes
local cachedFoundBrainrots:        { [string]: boolean }              = {}
local cachedFoundBrainrotVariants: { [string]: { [string]: boolean } } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function isFound(brainrotId: string): boolean
	if activeVariantId == VariantConfig.NORMAL_ID then
		return cachedFoundBrainrots[brainrotId] == true
	end
	local bucket = cachedFoundBrainrotVariants[brainrotId]
	return bucket ~= nil and bucket[activeVariantId] == true
end

local function matchesSearch(brainrot: typeof(BrainrotConfig.Pool[1])): boolean
	if searchText == "" then return true end
	return brainrot.id:lower():find(searchText:lower(), 1, true) ~= nil
end

-- Re-express a GuiObject's Position/Size as pure scale relative to parent,
-- preserving its current on-screen rectangle (drops offset components).
local function normalizeGuiScaleFromComputedRect(go: GuiObject)
	local parent = go.Parent
	if not parent or not parent:IsA("GuiObject") then
		return
	end

	local parentSize = parent.AbsoluteSize
	if parentSize.X <= 1 or parentSize.Y <= 1 then
		return
	end

	local gp, pp = go.AbsolutePosition, parent.AbsolutePosition
	local gs = go.AbsoluteSize
	local px = (gp.X - pp.X) / parentSize.X
	local py = (gp.Y - pp.Y) / parentSize.Y
	local sx = gs.X / parentSize.X
	local sy = gs.Y / parentSize.Y

	go.AnchorPoint = Vector2.zero
	go.Position    = UDim2.fromScale(px, py)
	go.Size        = UDim2.fromScale(sx, sy)
end

local function whenParentSizedForLayout(parent: GuiObject, cb: () -> ())
	if parent.AbsoluteSize.X > 1 and parent.AbsoluteSize.Y > 1 then
		cb()
		return
	end
	local conn: RBXScriptConnection?
	conn = parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if parent.AbsoluteSize.X > 1 and parent.AbsoluteSize.Y > 1 then
			conn:Disconnect()
			cb()
		end
	end)
end

local function applyCard(card: CardState)
	local b     = card.brainrot
	local found = isFound(b.id)
	local btn   = card.frame:FindFirstChild("ItemButton") :: ImageButton?
	local lbl   = card.frame:FindFirstChild("TextLabel")  :: TextLabel?

	if btn then
		local stroke = btn:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color     = if found then b.color else LOCKED_STROKE
			stroke.Thickness = if found then 2 else 1
		end
		-- Lighting: full colour when found, pitch-black silhouette when locked.
		local vp = btn:FindFirstChild("Viewport") :: ViewportFrame?
		if vp then
			if found then
				vp.LightColor = Color3.fromRGB(230, 230, 255)
				vp.Ambient    = Color3.fromRGB(80, 80, 110)
			else
				vp.LightColor = Color3.new(0, 0, 0)
				vp.Ambient    = Color3.new(0, 0, 0)
			end
			-- Toggle the point light added by populateViewports (may not exist yet).
			local world = vp:FindFirstChildOfClass("WorldModel")
			if world then
				for _, d in world:GetDescendants() do
					if d:IsA("PointLight") then d.Enabled = found end
				end
			end

			local lockOverlay = btn:FindFirstChild("LockedOverlay") :: Frame?
			if lockOverlay then
				lockOverlay.Visible = not found
			end
		end
		-- Update rarity badge gradient and odds label
		local rarityBadge = btn:FindFirstChild("RarityBadge")
		local rarityLbl   = rarityBadge and rarityBadge:FindFirstChild("RarityLabel") :: TextLabel?
		if rarityLbl then
			local grad = rarityLbl:FindFirstChildOfClass("UIGradient")
			if grad then
				grad.Color = ColorSequence.new(if found then b.color else LOCKED_TEXT)
			end
		end
		local oddsLbl = rarityBadge and rarityBadge:FindFirstChild("OddsLabel") :: TextLabel?
		if oddsLbl then
			local variantDenom = VariantConfig.getOddsDenominator(activeVariantId)
			oddsLbl.Text = BrainrotConfig.formatRngOdds(b.baseValue * variantDenom)
		end
	end

	if lbl then
		lbl.Text       = if found then b.id else "???"
		lbl.TextColor3 = if found then b.color else LOCKED_TEXT
	end
end

local function refreshAllCards()
	for _, card in cards do
		card.frame.Visible = matchesSearch(card.brainrot)
		applyCard(card)
	end
end

-- ── Viewport helpers ─────────────────────────────────────────────────────────

local function sanitize(inst: Instance)
	if inst:IsA("BaseScript") or inst:IsA("ProximityPrompt") or inst:IsA("BillboardGui") then
		inst:Destroy()
		return
	end
	if inst:IsA("BasePart") then
		inst.Anchored    = true
		inst.CanCollide  = false
		inst.CanTouch    = false
	end
end

-- Populates all card ViewportFrames in batches so the game doesn't hitch.
-- Pass the variantId to apply variant effects to each model.
-- Clears any previously-populated WorldModel before rebuilding.
local BATCH_SIZE = 6

local function populateViewports(variantId: string)
	for i, card in cards do
		local btn = card.frame:FindFirstChild("ItemButton") :: ImageButton?
		local vp  = btn and btn:FindFirstChild("Viewport") :: ViewportFrame?
		if not vp then continue end

		-- Clear previous content so variant switches start fresh.
		for _, child in vp:GetChildren() do
			if child:IsA("WorldModel") or child:IsA("Camera") then
				child:Destroy()
			end
		end
		vp.CurrentCamera = nil

		local template = BRAINROTS_FOLDER:FindFirstChild(card.brainrot.id) :: Model?
		if not template then continue end

		local world = Instance.new("WorldModel")
		world.Parent = vp

		local clone = template:Clone()
		for _, d in clone:GetDescendants() do sanitize(d) end
		sanitize(clone)
		clone.Parent = world

		-- Apply variant effects (colour, glow, particles, etc.) before framing.
		local isNormal = (variantId == nil or variantId == VariantConfig.NORMAL_ID)
		if not isNormal then
			BrainrotVisualFactory.applyVariant(clone, variantId)
		end

		local center, size = ThumbnailBounds.getVisibleBounds(clone)
		local vpSize    = vp.AbsoluteSize
		local aspect    = if vpSize.Y > 0 then vpSize.X / vpSize.Y else 1
		local dist = math.max(
			ThumbnailBounds.getFramingDistance(center, size, THUMB_LOOK, THUMB_FOV, aspect, THUMB_PAD),
			4
		)

		local cam           = Instance.new("Camera")
		cam.FieldOfView     = THUMB_FOV
		cam.CFrame          = CFrame.new(center - THUMB_LOOK * dist, center)
		cam.Parent          = vp
		vp.CurrentCamera    = cam

		-- Rarity-tinted point light.
		local lp             = Instance.new("Part")
		lp.Anchored          = true
		lp.CanCollide        = false
		lp.CanTouch          = false
		lp.Transparency      = 1
		lp.Size              = Vector3.one
		lp.CFrame            = CFrame.new(center - THUMB_LOOK * (dist * 0.35), center)
		lp.Parent            = world
		local light          = Instance.new("PointLight")
		light.Brightness     = 4
		light.Range          = math.max(size.Magnitude * 4, 15)
		light.Color          = card.brainrot.color
		-- Start disabled; applyCard enables it only for found brainrots.
		light.Enabled        = false
		light.Parent         = lp

		-- Sync locked/found lighting state now that the WorldModel exists.
		applyCard(card)

		if i % BATCH_SIZE == 0 then
			task.wait()
		end
	end
end

-- ── Grid builder ─────────────────────────────────────────────────────────────

local function buildGrid(scrollFrame: ScrollingFrame, templateCard: Frame)
	for _, child in scrollFrame:GetChildren() do
		if child:IsA("UIListLayout") or child:IsA("UIGridLayout")
			or child:IsA("UIPadding") or child:IsA("UIAspectRatioConstraint") then
			child:Destroy()
		elseif child:IsA("Frame") then
			child:Destroy()
		end
	end

	local CELL_GAP = 4

	local grid               = Instance.new("UIGridLayout")
	grid.CellSize            = UDim2.fromOffset(1, 1)  -- placeholder; syncCellSize sets real values
	grid.CellPadding         = UDim2.fromOffset(CELL_GAP, CELL_GAP)
	grid.FillDirection       = Enum.FillDirection.Horizontal
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.SortOrder           = Enum.SortOrder.LayoutOrder
	grid.Parent              = scrollFrame

	local padding            = Instance.new("UIPadding")
	padding.PaddingLeft      = UDim.new(0, 6)
	padding.PaddingRight     = UDim.new(0, 6)
	padding.PaddingTop       = UDim.new(0, 6)
	padding.PaddingBottom    = UDim.new(0, 6)
	padding.Parent           = scrollFrame

	-- Compute cell dimensions from the scrollFrame's actual pixel width so that
	-- UIGridLayout receives explicit offset-based sizes (UIAspectRatioConstraint
	-- cannot reliably override UIGridLayout's cell height when CellSize.Y = 0).
	local function syncCellSize()
		local w = scrollFrame.AbsoluteSize.X
		if w <= 0 then return end
		local innerW = w - 12  -- 6px left + 6px right padding
		local totalGap = (NUM_COLS - 1) * CELL_GAP
		local cellW = math.max(math.floor((innerW - totalGap) / NUM_COLS), 4)
		local cellH = math.max(math.floor(cellW / CARD_AR), 4)
		grid.CellSize = UDim2.fromOffset(cellW, cellH)
	end

	scrollFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncCellSize)
	task.defer(syncCellSize)

	local sorted: { typeof(BrainrotConfig.Pool[1]) } = {}
	for _, b in BrainrotConfig.Pool do
		table.insert(sorted, b)
	end
	table.sort(sorted, function(a, b)
		if a.rarityRank ~= b.rarityRank then return a.rarityRank < b.rarityRank end
		return a.baseValue < b.baseValue
	end)

	for idx, brainrot in sorted do
		local card        = templateCard:Clone()
		card.Name         = brainrot.id
		card.LayoutOrder  = idx

		-- Strip any constraints / padding the template may have baked in
		for _, c in card:GetChildren() do
			if c:IsA("UIAspectRatioConstraint") or c:IsA("UIPadding") then c:Destroy() end
		end

		-- Cell sizing is driven by syncCellSize → grid.CellSize (explicit offsets),
		-- so no UIAspectRatioConstraint is needed on individual cards.

		-- Small pixel inner gap so the btn doesn't touch cell edges
		local cp             = Instance.new("UIPadding")
		cp.PaddingLeft       = UDim.new(0, 2)
		cp.PaddingRight      = UDim.new(0, 2)
		cp.PaddingTop        = UDim.new(0, 2)
		cp.PaddingBottom     = UDim.new(0, 2)
		cp.Parent            = card

		local btn = card:FindFirstChild("ItemButton") :: ImageButton?
		if btn then
			-- Strip any constraints the template baked onto the button
			for _, c in btn:GetChildren() do
				if c:IsA("UIAspectRatioConstraint") then c:Destroy() end
			end

			-- Force btn to fill the whole padded cell in scale so it resizes with the grid
			btn.Size                    = UDim2.fromScale(1, 1)
			btn.Position                = UDim2.fromScale(0, 0)
			btn.Image                   = ""
			btn.BackgroundColor3        = CARD_BG
			btn.BackgroundTransparency  = 0

			-- Scale-based corner radius so rounding grows with the card
			local btnCorner = btn:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
			btnCorner.CornerRadius = UDim.new(0.06, 0)
			btnCorner.Parent       = btn

			local stroke = btn:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color     = LOCKED_STROKE
				stroke.Thickness = 1
			end

			local existingIcon = btn:FindFirstChild("Icon")
			if existingIcon then existingIcon:Destroy() end

			-- Viewport: top 78% of btn, fully scale-based
			local vp                     = Instance.new("ViewportFrame")
			vp.Name                      = "Viewport"
			vp.Size                      = UDim2.fromScale(1, VIEWPORT_HEIGHT)
			vp.Position                  = UDim2.fromScale(0, 0)
			vp.BackgroundColor3          = CARD_BG
			vp.BackgroundTransparency    = 0
			vp.ZIndex                    = btn.ZIndex + 1
			vp.LightColor                = Color3.new(0, 0, 0)
			vp.Ambient                   = Color3.new(0, 0, 0)
			vp.Visible                   = true

			-- Dark overlay above viewport when card is locked
			local lockOverlay                  = btn:FindFirstChild("LockedOverlay") or Instance.new("Frame")
			lockOverlay.Name                   = "LockedOverlay"
			lockOverlay.Size                   = UDim2.fromScale(1, VIEWPORT_HEIGHT)
			lockOverlay.Position               = UDim2.fromScale(0, 0)
			lockOverlay.BackgroundColor3       = Color3.new(0, 0, 0)
			lockOverlay.BackgroundTransparency = 0.18
			lockOverlay.BorderSizePixel        = 0
			lockOverlay.ZIndex                 = btn.ZIndex + 2
			lockOverlay.Visible                = true
			lockOverlay.Parent                 = btn

			-- Rarity badge: top 24% of btn — split into rarity name (top) and odds (bottom)
			local rarityBadge                    = Instance.new("Frame")
			rarityBadge.Name                     = "RarityBadge"
			rarityBadge.Size                     = UDim2.fromScale(1, 0.24)
			rarityBadge.Position                 = UDim2.fromScale(0, 0)
			rarityBadge.BackgroundColor3         = Color3.fromRGB(10, 12, 24)
			rarityBadge.BackgroundTransparency   = 0.25
			rarityBadge.ZIndex                   = vp.ZIndex + 3
			local rbCorner                       = Instance.new("UICorner")
			rbCorner.CornerRadius                = UDim.new(0.25, 0)
			rbCorner.Parent                      = rarityBadge

			local rarityLbl                      = Instance.new("TextLabel")
			rarityLbl.Name                       = "RarityLabel"
			rarityLbl.Size                       = UDim2.fromScale(1, 0.52)
			rarityLbl.Position                   = UDim2.fromScale(0, 0)
			rarityLbl.BackgroundTransparency     = 1
			rarityLbl.TextScaled                 = true
			rarityLbl.Text                       = brainrot.rarity:upper()
			rarityLbl.TextColor3                 = Color3.fromRGB(255, 255, 255)
			rarityLbl.Font                       = Enum.Font.GothamBlack
			rarityLbl.ZIndex                     = rarityBadge.ZIndex + 1

			local rarityGrad                     = Instance.new("UIGradient")
			rarityGrad.Color                     = ColorSequence.new(LOCKED_TEXT)
			rarityGrad.Rotation                  = 90
			rarityGrad.Parent                    = rarityLbl

			local rarityStroke                   = Instance.new("UIStroke")
			rarityStroke.Color                   = Color3.fromRGB(0, 0, 0)
			rarityStroke.Thickness               = 1.5
			rarityStroke.Parent                  = rarityLbl

			local oddsLbl                        = Instance.new("TextLabel")
			oddsLbl.Name                         = "OddsLabel"
			oddsLbl.Size                         = UDim2.fromScale(1, 0.48)
			oddsLbl.Position                     = UDim2.fromScale(0, 0.52)
			oddsLbl.BackgroundTransparency       = 1
			oddsLbl.TextScaled                   = true
			oddsLbl.Text                         = BrainrotConfig.formatRngOdds(brainrot.baseValue)
			oddsLbl.TextColor3                   = Color3.fromRGB(190, 200, 230)
			oddsLbl.Font                         = Enum.Font.GothamBold
			oddsLbl.ZIndex                       = rarityBadge.ZIndex + 1
			local oddsStroke                     = Instance.new("UIStroke")
			oddsStroke.Color                     = Color3.fromRGB(0, 0, 0)
			oddsStroke.Thickness                 = 1
			oddsStroke.Parent                    = oddsLbl
			oddsLbl.Parent                       = rarityBadge

			rarityLbl.Parent   = rarityBadge
			rarityBadge.Parent = btn

			vp.Parent = btn
		end

		-- Name label: bottom 22% of btn, fully scale-based
		local lbl = card:FindFirstChild("TextLabel") :: TextLabel?
		if lbl then
			lbl.Size                   = UDim2.fromScale(1, 1 - VIEWPORT_HEIGHT)
			lbl.Position               = UDim2.fromScale(0, VIEWPORT_HEIGHT)
			lbl.Text                   = "???"
			lbl.TextColor3             = LOCKED_TEXT
			lbl.TextScaled             = true
			lbl.TextWrapped            = true
			lbl.BackgroundTransparency = 1
			lbl.ZIndex                 = if btn then btn.ZIndex + 4 else lbl.ZIndex
		end

		card.Parent = scrollFrame

		table.insert(cards, {
			frame    = card,
			brainrot = brainrot,
		})
	end

	grid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		scrollFrame.CanvasSize = UDim2.fromOffset(0, grid.AbsoluteContentSize.Y + 16)
	end)
end

-- ── Main ─────────────────────────────────────────────────────────────────────

function IndexController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("Index")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end
	local bg        = GuiResolve.waitChild(container, "Background")
	if not bg then return end

	local sideButtonsHud = playerGui:WaitForChild("HUD"):WaitForChild("SideButtons")
	local openBtn = GuiResolve.sideToggleOpenButton(sideButtonsHud, "IndexBtn")
	if not openBtn then return end
	local navBar   = GuiResolve.waitChild(bg, "NavBar")
	local closeBtn = navBar and navBar:FindFirstChild("CloseBtn") :: GuiButton

	Screen.bind({
		guiName     = "Index",
		screen      = screen,
		container   = container,
		openButton  = openBtn,
		closeButton = closeBtn,
	})

	-- Ensure the NavBar title always shows "INDEX" regardless of pack defaults
	local titleLbl = navBar and navBar:FindFirstChildWhichIsA("TextLabel") :: TextLabel?
	if titleLbl then titleLbl.Text = "INDEX" end

	local content     = GuiResolve.waitChild(bg, "Content")
	if not content then return end
	local topContents = content:FindFirstChild("TopContents")
	local summaryLbl  = topContents and topContents:FindFirstChildWhichIsA("TextLabel") :: TextLabel?
	local searchBox   = topContents and topContents:FindFirstChild("Search") :: Frame?
	local searchInput = searchBox   and searchBox:FindFirstChildWhichIsA("TextBox") :: TextBox?
	local scrollFrame = GuiResolve.waitChild(content, "ScrollingFrame") :: ScrollingFrame

	-- ── Build card grid ───────────────────────────────────────────────────────
	local templateCard: Frame?
	for _, child in scrollFrame:GetChildren() do
		if child:IsA("Frame") then
			templateCard = child:Clone()
			break
		end
	end
	assert(templateCard, "IndexController: no template card in ScrollingFrame")

	buildGrid(scrollFrame, templateCard :: Frame)

	-- ── Wire variant SideButtons ──────────────────────────────────────────────
	-- 8 variants but only 6 pack buttons — clone to reach 8; SideButtons column
	-- and rows use scale-only UDim (no offsets) once Background has measured size.
	local sideButtonsInst = bg:FindFirstChild("SideButtons")
	if sideButtonsInst and sideButtonsInst:IsA("GuiObject") then
		local sideButtons = sideButtonsInst :: GuiObject
		local btnFrames: { Frame } = {}
		for _, child in sideButtons:GetChildren() do
			if child:IsA("Frame") then
				table.insert(btnFrames, child :: Frame)
			end
		end

		while #btnFrames < #ALL_VARIANTS do
			local clone = btnFrames[1]:Clone()
			clone.Parent = sideButtons
			table.insert(btnFrames, clone)
		end
		while #btnFrames > #ALL_VARIANTS do
			table.remove(btnFrames):Destroy()
		end

		local bgGui = bg :: GuiObject
		whenParentSizedForLayout(bgGui, function()
			normalizeGuiScaleFromComputedRect(sideButtons)
			local n = #btnFrames
			if n > 0 then
				local h = 1 / n
				for _, f in btnFrames do
					f.Size = UDim2.fromScale(1, h)
				end
			end
		end)

		local function getLabel(f: Frame): TextLabel?
			local cont     = f:FindFirstChild("Container")
			local contents = cont and (cont :: Instance):FindFirstChild("Contents")
			return contents and (contents :: Instance):FindFirstChildOfClass("TextLabel") :: TextLabel?
		end
		local function getStud(f: Frame): ImageLabel?
			local cont = f:FindFirstChild("Container")
			return cont and (cont :: Instance):FindFirstChild("StudBackground") :: ImageLabel?
		end
		local function getFrameStroke(f: Frame): UIStroke?
			return f:FindFirstChildOfClass("UIStroke") :: UIStroke?
		end

		-- Apply the correct text gradient for a variant, replacing any existing one
		local function applyGradient(lbl: TextLabel, variantId: string)
			-- Remove whatever gradient the pack left on this label
			local existing = lbl:FindFirstChildOfClass("UIGradient")
			if existing then existing:Destroy() end

			local cs = VARIANT_TEXT_GRADIENT[variantId]
			if cs == nil then
				-- nil = keep original (Gold/Diamond) — but we already destroyed it,
				-- so re-create from the pack's known values
				if variantId == "Gold" then
					cs = ColorSequence.new({
						ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 233, 32)),
						ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 175,  0)),
						ColorSequenceKeypoint.new(1,   Color3.fromRGB(255, 233, 32)),
					})
				elseif variantId == "Diamond" then
					cs = ColorSequence.new({
						ColorSequenceKeypoint.new(0,   Color3.fromRGB(247, 247, 247)),
						ColorSequenceKeypoint.new(0.5, Color3.fromRGB(115, 230, 255)),
						ColorSequenceKeypoint.new(1,   Color3.fromRGB(247, 247, 247)),
					})
				end
			end

			if cs then
				local grad          = Instance.new("UIGradient")
				grad.Color          = cs
				grad.Rotation       = 90
				grad.Parent         = lbl
			end
		end

		type BtnEntry = { frame: Frame, variant: typeof(ALL_VARIANTS[1]) }
		local btnEntries: { BtnEntry } = {}

		local function updateButtonVisuals()
			for _, entry in btnEntries do
				local stud        = getStud(entry.frame)
				local frameStroke = getFrameStroke(entry.frame)
				local active      = activeVariantId == entry.variant.id
				-- Active = bright stud, bold frame stroke
				-- Inactive = dimmed stud so the gradient text pops
				if stud then
					stud.ImageColor3       = Color3.fromRGB(255, 255, 255)
					stud.ImageTransparency = if active then 0.55 else 0.75
				end
				if frameStroke then
					frameStroke.Color     = if active
						then Color3.fromRGB(255, 255, 255)
						else Color3.fromRGB(120, 120, 130)
					frameStroke.Thickness = if active then 2 else 1
				end
			end
		end

		for i, btnFrame in btnFrames do
			local variant = ALL_VARIANTS[i]
			if not variant then break end

			local textLbl = getLabel(btnFrame)
			if textLbl then
				textLbl.Text = variant.displayName
				applyGradient(textLbl, variant.id)
			end

			table.insert(btnEntries, { frame = btnFrame, variant = variant })

			local clickBtn = btnFrame:FindFirstChild("Container") :: ImageButton?
			if clickBtn then
				clickBtn.MouseButton1Click:Connect(function()
					activeVariantId = variant.id
					updateButtonVisuals()
					refreshAllCards()
					-- Update summary count for the newly active variant
					if summaryLbl then
						local found = 0
						for _, card in cards do
							if isFound(card.brainrot.id) then found += 1 end
						end
						summaryLbl.Text = ("%d / %d Found"):format(found, #cards)
					end
					-- Re-populate viewports with the newly selected variant's models.
					task.spawn(populateViewports, variant.id)
				end)
			end
		end

		updateButtonVisuals()
	end

	-- ── Wire search box ───────────────────────────────────────────────────────
	if searchInput then
		searchInput:GetPropertyChangedSignal("Text"):Connect(function()
			searchText = searchInput.Text
			refreshAllCards()
		end)
	end

	-- ── Wire index sync remote ────────────────────────────────────────────────
	local indexSyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.INDEX_SYNC_REMOTE
	)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)

	local function onSync(payload: {
		foundBrainrots:        { [string]: boolean },
		foundBrainrotVariants: { [string]: { [string]: boolean } },
	})
		if type(payload) ~= "table" then return end
		cachedFoundBrainrots        = payload.foundBrainrots        or {}
		cachedFoundBrainrotVariants = payload.foundBrainrotVariants or {}

		refreshAllCards()

		if summaryLbl then
			local found = 0
			for _, card in cards do
				if isFound(card.brainrot.id) then found += 1 end
			end
			summaryLbl.Text = ("%d / %d Found"):format(found, #cards)
		end
	end

	indexSyncRemote.OnClientEvent:Connect(onSync)
	economySyncRequestRemote:FireServer()

	-- Populate ViewportFrames in the background after the rest of the UI is ready.
	task.defer(populateViewports, activeVariantId)
end

return IndexController
