local CameraEffects = {}

function CameraEffects.shake(localPlayer: Player, duration: number, intensity: number)
	if localPlayer.Character == nil then
		return
	end

	local humanoid = localPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local originalOffset = humanoid.CameraOffset
	local elapsed = 0

	while elapsed < duration and humanoid.Parent do
		elapsed += task.wait()
		local fade = 1 - elapsed / duration
		local x = math.sin(elapsed * 61) * intensity * fade
		local y = math.cos(elapsed * 47) * intensity * fade
		humanoid.CameraOffset = originalOffset + Vector3.new(x, y, 0)
	end

	humanoid.CameraOffset = originalOffset
end

function CameraEffects.playDigMotion(localPlayer: Player, duration: number)
	if localPlayer.Character == nil then
		return
	end

	local humanoid = localPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local originalOffset = humanoid.CameraOffset
	local elapsed = 0

	while elapsed < duration and humanoid.Parent do
		elapsed += 0.1
		local impact = math.abs(math.sin(elapsed * 15))
		local sway = math.sin(elapsed * 7) * 0.06
		humanoid.CameraOffset = Vector3.new(sway, -impact * 0.18, 0)
		task.wait(0.1)
	end

	humanoid.CameraOffset = originalOffset
end

function CameraEffects.getRevealShakeIntensity(rarityRank: number)
	return math.clamp(0.08 + rarityRank * 0.035, 0.1, 0.38)
end

return CameraEffects
