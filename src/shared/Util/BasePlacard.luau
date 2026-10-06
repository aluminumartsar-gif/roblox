local Players = game:GetService("Players")

local FormatUtil = require(script.Parent:WaitForChild("FormatUtil"))
local IconAssets = require(script.Parent.Parent:WaitForChild("Config"):WaitForChild("IconAssets"))

local BasePlacard = {}

-- Visual constants. The placard is a small wooden post with a flat signboard
-- mounted on top. Player info sits on the front face of the board via a
-- SurfaceGui so it reads like a real in-world sign instead of a screen-space
-- card. Sized to tuck against an entrance rail without dominating the base.
local POST_HEIGHT = 3.5
local POST_SIZE = Vector3.new(0.3, POST_HEIGHT, 0.3)
local POST_COLOR = Color3.fromRGB(82, 53, 30)

local BOARD_WIDTH = 4.5
local BOARD_HEIGHT_STUDS = 2.5
local BOARD_THICKNESS = 0.2
local BOARD_SIZE = Vector3.new(BOARD_WIDTH, BOARD_HEIGHT_STUDS, BOARD_THICKNESS)
local BOARD_COLOR = Color3.fromRGB(120, 78, 40)
local BOARD_TOP_OVERHANG = 0.8 -- studs the board rises above the top of the post

-- The post sits behind the board so it never crosses the SurfaceGui face.
-- Pull it back by half the board thickness plus half its own depth, then let
-- the front of the post bury slightly into the back of the board so the joint
-- reads as connected instead of floating.
local POST_BACK_BURY = 0.05
local POST_BACK_OFFSET = BOARD_THICKNESS / 2 + POST_SIZE.Z / 2 - POST_BACK_BURY

-- SurfaceGui pixel grid. PixelsPerStud at 60 keeps the small surface crisp:
-- 4.5 x 2.5 studs => 270 x 150 logical px.
local PIXELS_PER_STUD = 60
local CANVAS_WIDTH = BOARD_WIDTH * PIXELS_PER_STUD
local CANVAS_HEIGHT = BOARD_HEIGHT_STUDS * PIXELS_PER_STUD

local TITLE_OWNER_TEXT = "BASE OWNER"
local TITLE_EMPTY_TEXT = "VACANT"
local NAME_EMPTY_TEXT = "Empty Base"
local RATE_EMPTY_TEXT = "$0/s"

local TITLE_OWNER_COLOR = Color3.fromRGB(255, 220, 130)
local TITLE_EMPTY_COLOR = Color3.fromRGB(190, 190, 200)
local OWNER_NAME_COLOR = Color3.fromRGB(255, 255, 255)
local EMPTY_NAME_COLOR = Color3.fromRGB(170, 170, 180)
local RATE_OWNER_COLOR = Color3.fromRGB(140, 255, 160)
local RATE_EMPTY_COLOR = Color3.fromRGB(170, 170, 180)
local STROKE_COLOR = Color3.new(0, 0, 0)
local STROKE_TRANSPARENCY = 0.2
local CARD_BG_COLOR = Color3.fromRGB(28, 22, 18)
local CARD_BG_TRANSPARENCY = 0.18
local AVATAR_BG_COLOR = Color3.fromRGB(70, 50, 32)
local ACCENT_COLOR = Color3.fromRGB(255, 220, 130)

local THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local THUMBNAIL_SIZE = Enum.ThumbnailSize.Size150x150

export type Config = {
	parent: Instance,
	name: string?,
	-- Ground anchor (XYZ in world space). The post stands up from here and
	-- the signboard sits on top.
	position: Vector3,
	-- Outward direction the front face of the sign should look toward (XZ
	-- plane, magnitude is ignored). Typically points away from the base.
	facingDirection: Vector3,
	-- Optional cap on how far away the SurfaceGui still renders.
	maxDistance: number?,
}

export type Placard = {
	instance: Model,
	setOwner: (player: Player, earningsRate: number) -> (),
	setEmpty: () -> (),
	setEarningsRate: (rate: number) -> (),
	destroy: () -> (),
}

type Parts = {
	titleLabel: TextLabel,
	avatarImage: ImageLabel,
	nameLabel: TextLabel,
	earningsLabel: TextLabel,
}

local function buildPost(parent: Instance, anchor: Vector3, facing: Vector3): BasePart
	local post = Instance.new("Part")
	post.Name = "Post"
	post.Size = POST_SIZE
	post.Anchored = true
	post.CanCollide = false
	post.CanQuery = false
	post.CanTouch = false
	post.CastShadow = true
	post.Material = Enum.Material.WoodPlanks
	post.Color = POST_COLOR
	-- Offset along -facing so the post lives behind the signboard. Without
	-- this the 0.3-wide post pokes 0.05 studs in front of the 0.2-thick board
	-- and the SurfaceGui readout ends up obscured by a strip of wood.
	post.Position = anchor + Vector3.new(0, POST_HEIGHT / 2, 0) - facing * POST_BACK_OFFSET
	post.Parent = parent

	return post
end

local function buildBoard(parent: Instance, anchor: Vector3, facing: Vector3): BasePart
	local board = Instance.new("Part")
	board.Name = "Board"
	board.Size = BOARD_SIZE
	board.Anchored = true
	board.CanCollide = false
	board.CanQuery = false
	board.CanTouch = false
	board.CastShadow = true
	board.Material = Enum.Material.WoodPlanks
	board.Color = BOARD_COLOR
	-- Board mounts on the front of the post with the post acting as a back
	-- support. BOARD_TOP_OVERHANG controls how far the board rises above the
	-- top of the post, giving the silhouette a sign-on-a-stick feel.
	local boardCenterY = POST_HEIGHT - BOARD_HEIGHT_STUDS / 2 + BOARD_TOP_OVERHANG
	local boardPos = anchor + Vector3.new(0, boardCenterY, 0)
	-- CFrame.lookAt(eye, target) makes the part's local -Z (Front face) point
	-- toward the target. Pointing the front face along `facing` means the
	-- SurfaceGui (Face = Front) is visible from outside the base.
	board.CFrame = CFrame.lookAt(boardPos, boardPos + facing)
	board.Parent = parent

	return board
end

local function buildSurface(parent: BasePart, maxDistance: number?): (SurfaceGui, Parts)
	local surface = Instance.new("SurfaceGui")
	surface.Name = "OwnerSurface"
	surface.Face = Enum.NormalId.Front
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = PIXELS_PER_STUD
	surface.LightInfluence = 0
	surface.AlwaysOnTop = false
	surface.CanvasSize = Vector2.new(CANVAS_WIDTH, CANVAS_HEIGHT)
	surface.ClipsDescendants = true
	if maxDistance then
		surface.MaxDistance = maxDistance
	end
	surface.Parent = parent

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.BackgroundColor3 = CARD_BG_COLOR
	card.BackgroundTransparency = CARD_BG_TRANSPARENCY
	card.BorderSizePixel = 0
	card.Size = UDim2.fromScale(1, 1)
	card.Parent = surface

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0.05, 0)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = ACCENT_COLOR
	cardStroke.Thickness = 2
	cardStroke.Transparency = 0.35
	cardStroke.Parent = card

	-- Padding so content doesn't crowd the rounded corners.
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.053, 0)
	padding.PaddingBottom = UDim.new(0.053, 0)
	padding.PaddingLeft = UDim.new(0.037, 0)
	padding.PaddingRight = UDim.new(0.037, 0)
	padding.Parent = card

	-- Layout uses scale-based positioning so it adapts cleanly to the small
	-- canvas. The right column (name + earnings) sits beside a circular
	-- avatar that takes up the full content height of the card.
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.fromScale(0, 0)
	titleLabel.Size = UDim2.new(1, 0, 0.22, 0)
	titleLabel.Font = Enum.Font.FredokaOne
	titleLabel.Text = TITLE_OWNER_TEXT
	titleLabel.TextColor3 = TITLE_OWNER_COLOR
	titleLabel.TextScaled = true
	titleLabel.TextStrokeColor3 = STROKE_COLOR
	titleLabel.TextStrokeTransparency = STROKE_TRANSPARENCY
	titleLabel.Parent = card

	local avatarHolder = Instance.new("Frame")
	avatarHolder.Name = "Avatar"
	avatarHolder.AnchorPoint = Vector2.new(0, 1)
	avatarHolder.Position = UDim2.fromScale(0, 1)
	avatarHolder.Size = UDim2.new(0, 0, 0.78, 0)
	avatarHolder.BackgroundColor3 = AVATAR_BG_COLOR
	avatarHolder.BorderSizePixel = 0
	avatarHolder.Parent = card

	-- Force the avatar holder to a 1:1 aspect ratio so it stays circular.
	local avatarRatio = Instance.new("UIAspectRatioConstraint")
	avatarRatio.AspectRatio = 1
	avatarRatio.AspectType = Enum.AspectType.ScaleWithParentSize
	avatarRatio.DominantAxis = Enum.DominantAxis.Height
	avatarRatio.Parent = avatarHolder

	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatarHolder

	local avatarStroke = Instance.new("UIStroke")
	avatarStroke.Color = ACCENT_COLOR
	avatarStroke.Thickness = 1.5
	avatarStroke.Transparency = 0.25
	avatarStroke.Parent = avatarHolder

	local avatarImage = Instance.new("ImageLabel")
	avatarImage.Name = "Image"
	avatarImage.BackgroundTransparency = 1
	avatarImage.Size = UDim2.fromScale(1, 1)
	avatarImage.ScaleType = Enum.ScaleType.Crop
	avatarImage.Parent = avatarHolder

	local avatarImageCorner = Instance.new("UICorner")
	avatarImageCorner.CornerRadius = UDim.new(1, 0)
	avatarImageCorner.Parent = avatarImage

	-- Right column container so name + earnings layout flows automatically
	-- regardless of the avatar's actual rendered width.
	local rightColumn = Instance.new("Frame")
	rightColumn.Name = "RightColumn"
	rightColumn.BackgroundTransparency = 1
	rightColumn.AnchorPoint = Vector2.new(1, 1)
	rightColumn.Position = UDim2.fromScale(1, 1)
	-- Avatar is 0.78 tall and equals that in width (1:1 aspect). Reserve the
	-- avatar width plus a small gutter on the left side of the right column.
	rightColumn.Size = UDim2.fromScale(1 - 0.78 * 0.78, 0.78)
	rightColumn.Parent = card

	local rightLayout = Instance.new("UIListLayout")
	rightLayout.FillDirection = Enum.FillDirection.Vertical
	rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rightLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	rightLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rightLayout.Padding = UDim.new(0.02, 0)
	rightLayout.Parent = rightColumn

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Name"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0.45, 0)
	nameLabel.LayoutOrder = 1
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.Text = NAME_EMPTY_TEXT
	nameLabel.TextColor3 = EMPTY_NAME_COLOR
	nameLabel.TextScaled = true
	nameLabel.TextStrokeColor3 = STROKE_COLOR
	nameLabel.TextStrokeTransparency = STROKE_TRANSPARENCY
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = rightColumn

	-- Earnings sits inside a horizontal row alongside a cash icon so the rate
	-- reads as currency at a glance (matching the brainrot placard treatment).
	-- The icon is sized via SizeConstraint.RelativeYY so its width tracks the
	-- row's height regardless of canvas scaling.
	local earningsRow = Instance.new("Frame")
	earningsRow.Name = "EarningsRow"
	earningsRow.BackgroundTransparency = 1
	earningsRow.Size = UDim2.new(1, 0, 0.5, 0)
	earningsRow.LayoutOrder = 2
	earningsRow.Parent = rightColumn

	local earningsLayout = Instance.new("UIListLayout")
	earningsLayout.FillDirection = Enum.FillDirection.Horizontal
	earningsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	earningsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	earningsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	earningsLayout.Padding = UDim.new(0.04, 0)
	earningsLayout.Parent = earningsRow

	local earningsIcon = Instance.new("ImageLabel")
	earningsIcon.Name = "CashIcon"
	earningsIcon.BackgroundTransparency = 1
	earningsIcon.Image = IconAssets.Cash
	earningsIcon.ScaleType = Enum.ScaleType.Fit
	earningsIcon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	earningsIcon.Size = UDim2.fromScale(1, 1)
	earningsIcon.LayoutOrder = 1
	earningsIcon.Parent = earningsRow

	local earningsLabel = Instance.new("TextLabel")
	earningsLabel.Name = "Earnings"
	earningsLabel.BackgroundTransparency = 1
	earningsLabel.Size = UDim2.new(0.78, 0, 1, 0)
	earningsLabel.LayoutOrder = 2
	earningsLabel.Font = Enum.Font.GothamBold
	earningsLabel.Text = RATE_EMPTY_TEXT
	earningsLabel.TextColor3 = RATE_EMPTY_COLOR
	earningsLabel.TextScaled = true
	earningsLabel.TextStrokeColor3 = STROKE_COLOR
	earningsLabel.TextStrokeTransparency = STROKE_TRANSPARENCY
	earningsLabel.TextXAlignment = Enum.TextXAlignment.Left
	earningsLabel.Parent = earningsRow

	return surface,
		{
			titleLabel = titleLabel,
			avatarImage = avatarImage,
			nameLabel = nameLabel,
			earningsLabel = earningsLabel,
		}
end

local function normalizeFacing(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end

	return flat.Unit
end

local function formatEarnings(rate: number): string
	return ("%s/s"):format(FormatUtil.money(math.max(0, rate)))
end

local function applyHeadshot(image: ImageLabel, userId: number, generationToken: { value: number }, expectedToken: number)
	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(userId, THUMBNAIL_TYPE, THUMBNAIL_SIZE)
		end)
		-- Drop the result if the placard has been reassigned to another owner
		-- while the thumbnail request was in flight.
		if not ok or type(url) ~= "string" or not image.Parent then
			return
		end
		if generationToken.value ~= expectedToken then
			return
		end

		image.Image = url
	end)
end

function BasePlacard.create(config: Config): Placard
	assert(config.parent, "BasePlacard.create requires `parent`")
	assert(typeof(config.position) == "Vector3", "BasePlacard.create requires `position` as Vector3")
	assert(typeof(config.facingDirection) == "Vector3", "BasePlacard.create requires `facingDirection` as Vector3")

	local model = Instance.new("Model")
	model.Name = config.name or "BasePlacard"

	local facing = normalizeFacing(config.facingDirection)
	local anchor = config.position

	buildPost(model, anchor, facing)
	local board = buildBoard(model, anchor, facing)
	model.PrimaryPart = board

	local _surface, parts = buildSurface(board, config.maxDistance)

	model.Parent = config.parent

	-- Token used to ignore stale thumbnail responses when the placard owner
	-- changes mid-flight. Each owner change increments `value` and the inflight
	-- task only writes its result when its captured token still matches.
	local thumbnailToken = { value = 0 }

	local placard
	placard = {
		instance = model,
		setOwner = function(player: Player, earningsRate: number)
			thumbnailToken.value += 1
			parts.titleLabel.Text = TITLE_OWNER_TEXT
			parts.titleLabel.TextColor3 = TITLE_OWNER_COLOR
			parts.nameLabel.Text = player.DisplayName
			parts.nameLabel.TextColor3 = OWNER_NAME_COLOR
			parts.earningsLabel.Text = formatEarnings(earningsRate)
			parts.earningsLabel.TextColor3 = RATE_OWNER_COLOR
			parts.avatarImage.Image = ""
			applyHeadshot(parts.avatarImage, player.UserId, thumbnailToken, thumbnailToken.value)
		end,
		setEmpty = function()
			thumbnailToken.value += 1
			parts.titleLabel.Text = TITLE_EMPTY_TEXT
			parts.titleLabel.TextColor3 = TITLE_EMPTY_COLOR
			parts.nameLabel.Text = NAME_EMPTY_TEXT
			parts.nameLabel.TextColor3 = EMPTY_NAME_COLOR
			parts.earningsLabel.Text = RATE_EMPTY_TEXT
			parts.earningsLabel.TextColor3 = RATE_EMPTY_COLOR
			parts.avatarImage.Image = ""
		end,
		setEarningsRate = function(rate: number)
			parts.earningsLabel.Text = formatEarnings(rate)
		end,
		destroy = function()
			thumbnailToken.value += 1
			if model.Parent then
				model:Destroy()
			end
		end,
	}

	placard.setEmpty()

	return placard
end

return BasePlacard
