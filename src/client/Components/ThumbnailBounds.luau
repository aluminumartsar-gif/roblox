local ThumbnailBounds = {}

local ROOT_PART_NAMES = {
	RootPart = true,
	FakeRootPart = true,
	HumanoidRootPart = true,
}

local function getBoundsCorners(center: Vector3, size: Vector3)
	local halfSize = size * 0.5
	local corners = {}

	for _, xSign in { -1, 1 } do
		for _, ySign in { -1, 1 } do
			for _, zSign in { -1, 1 } do
				table.insert(corners, center + Vector3.new(
					halfSize.X * xSign,
					halfSize.Y * ySign,
					halfSize.Z * zSign
				))
			end
		end
	end

	return corners
end

local function shouldIncludePart(part: BasePart)
	if part.Transparency >= 0.95 then
		return false
	end

	if ROOT_PART_NAMES[part.Name] then
		return false
	end

	return true
end

local function includePartBounds(part: BasePart, bounds)
	local halfSize = part.Size * 0.5

	for _, xSign in { -1, 1 } do
		for _, ySign in { -1, 1 } do
			for _, zSign in { -1, 1 } do
				local point = part.CFrame:PointToWorldSpace(Vector3.new(
					halfSize.X * xSign,
					halfSize.Y * ySign,
					halfSize.Z * zSign
				))

				bounds.minX = math.min(bounds.minX, point.X)
				bounds.minY = math.min(bounds.minY, point.Y)
				bounds.minZ = math.min(bounds.minZ, point.Z)
				bounds.maxX = math.max(bounds.maxX, point.X)
				bounds.maxY = math.max(bounds.maxY, point.Y)
				bounds.maxZ = math.max(bounds.maxZ, point.Z)
				bounds.count += 1
			end
		end
	end
end

function ThumbnailBounds.getVisibleBounds(instance: Instance): (Vector3, Vector3)
	local bounds = {
		minX = math.huge,
		minY = math.huge,
		minZ = math.huge,
		maxX = -math.huge,
		maxY = -math.huge,
		maxZ = -math.huge,
		count = 0,
	}

	if instance:IsA("BasePart") and shouldIncludePart(instance) then
		includePartBounds(instance, bounds)
	end

	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") and shouldIncludePart(descendant) then
			includePartBounds(descendant, bounds)
		end
	end

	if bounds.count == 0 then
		if instance:IsA("Model") then
			local fallbackCFrame, fallbackSize = instance:GetBoundingBox()
			return fallbackCFrame.Position, fallbackSize
		end

		if instance:IsA("BasePart") then
			return instance.Position, instance.Size
		end

		return Vector3.zero, Vector3.one
	end

	local min = Vector3.new(bounds.minX, bounds.minY, bounds.minZ)
	local max = Vector3.new(bounds.maxX, bounds.maxY, bounds.maxZ)
	return (min + max) * 0.5, max - min
end

function ThumbnailBounds.getFramingDistance(
	center: Vector3,
	size: Vector3,
	lookVector: Vector3,
	fieldOfView: number,
	aspectRatio: number,
	padding: number?
): number
	local safeLookVector = if lookVector.Magnitude > 0 then lookVector.Unit else Vector3.new(0, 0, -1)
	local safeFieldOfView = math.clamp(fieldOfView, 1, 120)
	local safeAspectRatio = math.max(aspectRatio, 0.1)
	local safePadding = padding or 1

	local cameraFrame = CFrame.lookAt(Vector3.zero, safeLookVector)
	local tanVertical = math.tan(math.rad(safeFieldOfView) * 0.5)
	local tanHorizontal = tanVertical * safeAspectRatio
	local paddedSize = size * safePadding
	local distance = 0

	for _, corner in getBoundsCorners(center, paddedSize) do
		local offset = corner - center
		local depthOffset = offset:Dot(safeLookVector)
		local verticalDistance = math.abs(offset:Dot(cameraFrame.UpVector)) / tanVertical - depthOffset
		local horizontalDistance = math.abs(offset:Dot(cameraFrame.RightVector)) / tanHorizontal - depthOffset
		distance = math.max(distance, verticalDistance, horizontalDistance)
	end

	return math.max(distance, 1)
end

return ThumbnailBounds
