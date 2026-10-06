--!nocheck
-- Behaviour for specific classes on top of the generic Instance (inst.luau):
-- part/model pivots, attachments, computed GUI sizes, sounds, tools,
-- humanoids, remotes, the camera, ... Anything the API dump lists but isn't
-- here answers with a stub (reported as "unimplemented").

local roblox = require("@lune/roblox")
local Inst = require("./inst")
local Report = require("./report")
local Sched = require("./sched")
local Signal = require("./signal")
local Typeof = require("./typeof")
local Util = require("./util")

local S = Inst.S
local B = Inst.Behaviors
local raise = Inst.raise
local selfState = Inst.selfState
local typeOf = Typeof.typeof

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local UDim2 = roblox.UDim2
local Enum = roblox.Enum

local Classes = {}

-- Set by services.luau
Classes.viewport = Vector2.new(1920, 1080)
Classes.guiInset = 58
Classes.remoteHooks = nil -- { fireServer = fn(remote, args), invokeServer = fn(remote, args) -> ...}
Classes.localPlayer = nil
Classes.playerFromCharacter = nil -- fn(model) -> Player?

local function get(proxy, key)
	return Inst.get(proxy, key)
end

local function checkType(v, expected: string, argIndex: number, method: string)
	if typeOf(v) ~= expected then
		raise(
			string.format("invalid argument #%d to '%s' (%s expected, got %s)", argIndex, method, expected, typeOf(v)),
			"Invalid API arguments"
		)
	end
end

--------------------------------------------------------------------------
-- Parts, models, attachments (positions are kept consistent; no physics)
--------------------------------------------------------------------------

local function setPartCFrame(proxy, st, cf)
	local old = get(proxy, "CFrame")
	if old == cf then
		return
	end
	st.props.CFrame = cf
	Inst.changed(proxy, st, "CFrame", cf)
	if old.Position ~= cf.Position then
		Inst.changed(proxy, st, "Position", cf.Position)
	end
	if old.Rotation ~= cf.Rotation then
		Inst.changed(proxy, st, "Orientation", nil)
		Inst.changed(proxy, st, "Rotation", nil)
	end
end
Classes.setPartCFrame = setPartCFrame

local function orientationOf(cf)
	local rx, ry, rz = cf:ToOrientation()
	return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
end

B.BasePart = {
	getters = {
		Position = function(proxy)
			return get(proxy, "CFrame").Position
		end,
		Orientation = function(proxy)
			return orientationOf(get(proxy, "CFrame"))
		end,
		Rotation = function(proxy)
			local rx, ry, rz = get(proxy, "CFrame"):ToEulerAnglesXYZ()
			return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
		end,
		AssemblyRootPart = function(proxy)
			return proxy
		end,
		Mass = function(proxy)
			local s = get(proxy, "Size")
			return s.X * s.Y * s.Z * 0.7
		end,
		AssemblyMass = function(proxy)
			local s = get(proxy, "Size")
			return s.X * s.Y * s.Z * 0.7
		end,
	},
	setters = {
		CFrame = setPartCFrame,
		Position = function(proxy, st, v)
			local cf = get(proxy, "CFrame")
			setPartCFrame(proxy, st, CFrame.new(v) * cf.Rotation)
		end,
		Orientation = function(proxy, st, v)
			local cf = get(proxy, "CFrame")
			setPartCFrame(proxy, st, CFrame.new(cf.Position) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z)))
		end,
		Rotation = function(proxy, st, v)
			local cf = get(proxy, "CFrame")
			setPartCFrame(proxy, st, CFrame.new(cf.Position) * CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z)))
		end,
	},
	methods = {
		GetPivot = function(self)
			selfState(self, "GetPivot")
			return get(self, "CFrame") * get(self, "PivotOffset")
		end,
		PivotTo = function(self, cf)
			local st = selfState(self, "PivotTo")
			checkType(cf, "CFrame", 1, "PivotTo")
			setPartCFrame(self, st, cf * get(self, "PivotOffset"):Inverse())
		end,
		GetMass = function(self)
			selfState(self, "GetMass")
			local s = get(self, "Size")
			return s.X * s.Y * s.Z * 0.7
		end,
		GetConnectedParts = function(self)
			selfState(self, "GetConnectedParts")
			return {}
		end,
		GetTouchingParts = function(self)
			selfState(self, "GetTouchingParts")
			return {}
		end,
		GetJoints = function(self)
			selfState(self, "GetJoints")
			return {}
		end,
		GetRootPart = function(self)
			selfState(self, "GetRootPart")
			return self
		end,
		CanCollideWith = function(self)
			selfState(self, "CanCollideWith")
			return true
		end,
		ApplyImpulse = function(self)
			selfState(self, "ApplyImpulse")
		end,
		ApplyAngularImpulse = function(self)
			selfState(self, "ApplyAngularImpulse")
		end,
		GetVelocityAtPosition = function(self)
			selfState(self, "GetVelocityAtPosition")
			return Vector3.zero
		end,
		SetNetworkOwner = function(self)
			selfState(self, "SetNetworkOwner")
			raise("Network Ownership API can only be called from the server", "Invalid API use")
		end,
		GetNetworkOwner = function(self)
			selfState(self, "GetNetworkOwner")
			return nil
		end,
		BreakJoints = function(self)
			selfState(self, "BreakJoints")
		end,
	},
}

B.BasePart.getters.BrickColor = function(proxy)
	local ok, bc = pcall(roblox.BrickColor.new, get(proxy, "Color"))
	return if ok then bc else roblox.BrickColor.new("Medium stone grey")
end
B.BasePart.setters.BrickColor = function(proxy, st, v)
	Inst.setRaw(proxy, st, "Color", v.Color)
	Inst.changed(proxy, st, "BrickColor", v)
end

local function partsOf(proxy)
	local out = {}
	for _, d in Inst.descendants(proxy) do
		if S[d].info.rec.isA.BasePart then
			table.insert(out, d)
		end
	end
	return out
end

local function boundingBox(proxy, orientation)
	local rot = orientation or CFrame.new()
	local inv = rot:Inverse()
	local minV, maxV
	for _, part in partsOf(proxy) do
		local cf = get(part, "CFrame")
		local half = get(part, "Size") / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local corner = inv * (cf * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
					if not minV then
						minV, maxV = corner, corner
					else
						minV = minV:Min(corner)
						maxV = maxV:Max(corner)
					end
				end
			end
		end
	end
	if not minV then
		return rot, Vector3.zero
	end
	local centre = rot * ((minV + maxV) / 2)
	return CFrame.new(centre) * rot.Rotation, maxV - minV
end

local function modelPrimary(proxy, st)
	local primary = st.props.PrimaryPart
	if primary and Inst.isDescendantOf(primary, proxy) then
		return primary
	end
	return nil
end

local function modelPivot(proxy, st)
	local primary = modelPrimary(proxy, st)
	if primary then
		return get(primary, "CFrame") * get(primary, "PivotOffset")
	end
	if st.props.WorldPivot then
		return st.props.WorldPivot
	end
	local cf = boundingBox(proxy, nil)
	return cf
end

local function modelPivotTo(proxy, st, cf)
	local current = modelPivot(proxy, st)
	local delta = cf * current:Inverse()
	for _, part in partsOf(proxy) do
		setPartCFrame(part, S[part], delta * get(part, "CFrame"))
	end
	if not modelPrimary(proxy, st) then
		st.props.WorldPivot = cf
	end
end

B.Model = {
	getters = {
		WorldPivot = function(proxy, st)
			return modelPivot(proxy, st)
		end,
		PrimaryPart = function(proxy, st)
			return modelPrimary(proxy, st)
		end,
	},
	setters = {
		WorldPivot = function(proxy, st, v)
			st.props.WorldPivot = v
			Inst.changed(proxy, st, "WorldPivot", v)
		end,
		PrimaryPart = function(proxy, st, v)
			if v ~= nil and not Inst.isDescendantOf(v, proxy) then
				Report.add(
					"WARN",
					"Suspicious property values",
					"Model.PrimaryPart set to a part that is not inside the model (Roblox ignores it)",
					Report.callerLocation()
				)
			end
			Inst.setRaw(proxy, st, "PrimaryPart", v)
		end,
	},
	methods = {
		GetPivot = function(self)
			local st = selfState(self, "GetPivot")
			return modelPivot(self, st)
		end,
		PivotTo = function(self, cf)
			local st = selfState(self, "PivotTo")
			checkType(cf, "CFrame", 1, "PivotTo")
			modelPivotTo(self, st, cf)
		end,
		GetBoundingBox = function(self)
			local st = selfState(self, "GetBoundingBox")
			return boundingBox(self, modelPivot(self, st).Rotation)
		end,
		GetExtentsSize = function(self)
			local st = selfState(self, "GetExtentsSize")
			local _, size = boundingBox(self, modelPivot(self, st).Rotation)
			return size
		end,
		MoveTo = function(self, position)
			local st = selfState(self, "MoveTo")
			checkType(position, "Vector3", 1, "MoveTo")
			local pivot = modelPivot(self, st)
			modelPivotTo(self, st, CFrame.new(position) * pivot.Rotation)
		end,
		TranslateBy = function(self, offset)
			local st = selfState(self, "TranslateBy")
			checkType(offset, "Vector3", 1, "TranslateBy")
			modelPivotTo(self, st, modelPivot(self, st) + offset)
		end,
		SetPrimaryPartCFrame = function(self, cf)
			local st = selfState(self, "SetPrimaryPartCFrame")
			checkType(cf, "CFrame", 1, "SetPrimaryPartCFrame")
			local primary = modelPrimary(self, st)
			if not primary then
				raise("Model:SetPrimaryPartCFrame() failed because no PrimaryPart has been set, or the PrimaryPart no longer exists. Please set Model.PrimaryPart before using this.", "Invalid API use")
			end
			modelPivotTo(self, st, cf * get(primary, "PivotOffset"))
		end,
		GetPrimaryPartCFrame = function(self)
			local st = selfState(self, "GetPrimaryPartCFrame")
			local primary = modelPrimary(self, st)
			return if primary then get(primary, "CFrame") else nil
		end,
		GetScale = function(self)
			selfState(self, "GetScale")
			return 1
		end,
		ScaleTo = function(self, scale)
			selfState(self, "ScaleTo")
			checkType(scale, "number", 1, "ScaleTo")
		end,
		GetModelCFrame = function(self)
			local st = selfState(self, "GetModelCFrame")
			return modelPivot(self, st)
		end,
		GetModelSize = function(self)
			local st = selfState(self, "GetModelSize")
			local _, size = boundingBox(self, nil)
			return size
		end,
	},
}

local function attachmentParentCFrame(st)
	local parent = st.parent
	if parent and S[parent].info.rec.isA.BasePart then
		return get(parent, "CFrame")
	elseif parent and S[parent].info.rec.isA.Attachment then
		return get(parent, "WorldCFrame")
	end
	return CFrame.new()
end

B.Attachment = {
	getters = {
		Position = function(proxy)
			return get(proxy, "CFrame").Position
		end,
		WorldPosition = function(proxy, st)
			return attachmentParentCFrame(st) * get(proxy, "CFrame").Position
		end,
		WorldCFrame = function(proxy, st)
			return attachmentParentCFrame(st) * get(proxy, "CFrame")
		end,
		Orientation = function(proxy)
			return orientationOf(get(proxy, "CFrame"))
		end,
		WorldOrientation = function(proxy, st)
			return orientationOf(attachmentParentCFrame(st) * get(proxy, "CFrame"))
		end,
	},
	setters = {
		Position = function(proxy, st, v)
			local cf = get(proxy, "CFrame")
			Inst.setRaw(proxy, st, "CFrame", CFrame.new(v) * cf.Rotation)
			Inst.changed(proxy, st, "Position", v)
		end,
		WorldPosition = function(proxy, st, v)
			local local_ = attachmentParentCFrame(st):PointToObjectSpace(v)
			local cf = get(proxy, "CFrame")
			Inst.setRaw(proxy, st, "CFrame", CFrame.new(local_) * cf.Rotation)
			Inst.changed(proxy, st, "WorldPosition", v)
		end,
		WorldCFrame = function(proxy, st, v)
			Inst.setRaw(proxy, st, "CFrame", attachmentParentCFrame(st):ToObjectSpace(v))
		end,
		Orientation = function(proxy, st, v)
			local cf = get(proxy, "CFrame")
			Inst.setRaw(
				proxy,
				st,
				"CFrame",
				CFrame.new(cf.Position) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
			)
		end,
	},
	methods = {
		GetConstraints = function(self)
			selfState(self, "GetConstraints")
			return {}
		end,
	},
}

--------------------------------------------------------------------------
-- GUI: rough absolute rects (no layouts/constraints/UIScale), text bounds
--------------------------------------------------------------------------

local function absRect(proxy, depth: number?): (number, number, number, number)
	depth = (depth or 0) + 1
	if depth > 60 then
		return 0, 0, 0, 0
	end
	local st = S[proxy]
	local rec = st.info.rec
	if rec.isA.ScreenGui then
		local vp = Classes.viewport
		local inset = if get(proxy, "IgnoreGuiInset") then 0 else Classes.guiInset
		return 0, inset, vp.X, vp.Y - inset
	elseif rec.isA.LayerCollector then
		local size = get(proxy, "Size")
		return 0, 0, size.X.Offset + size.X.Scale * 50, size.Y.Offset + size.Y.Scale * 50
	elseif rec.isA.GuiObject then
		local px, py, pw, ph = 0, 0, 0, 0
		local parent = st.parent
		if parent and S[parent].info.rec.isA.GuiBase2d then
			px, py, pw, ph = absRect(parent, depth)
		end
		local size = get(proxy, "Size")
		local pos = get(proxy, "Position")
		local anchor = get(proxy, "AnchorPoint")
		local w = pw * size.X.Scale + size.X.Offset
		local h = ph * size.Y.Scale + size.Y.Offset
		local x = px + pw * pos.X.Scale + pos.X.Offset - w * anchor.X
		local y = py + ph * pos.Y.Scale + pos.Y.Offset - h * anchor.Y
		return x, y, math.max(0, w), math.max(0, h)
	end
	return 0, 0, 0, 0
end
Classes.absRect = absRect

B.GuiBase2d = {
	getters = {
		AbsoluteSize = function(proxy)
			local _, _, w, h = absRect(proxy)
			return Vector2.new(w, h)
		end,
		AbsolutePosition = function(proxy)
			local x, y = absRect(proxy)
			return Vector2.new(x, y)
		end,
		AbsoluteRotation = function(proxy)
			local st = S[proxy]
			if st.info.rec.props.Rotation then
				return get(proxy, "Rotation")
			end
			return 0
		end,
	},
}

local function stripRichText(text: string): string
	return (string.gsub(text, "<[^>]->", ""))
end

local function textBounds(proxy)
	local text = tostring(get(proxy, "Text"))
	if get(proxy, "RichText") then
		text = stripRichText(text)
	end
	local size = get(proxy, "TextSize")
	if get(proxy, "TextScaled") then
		local _, _, _, h = absRect(proxy)
		size = math.min(100, math.max(1, h))
	end
	local maxLen, lines = 0, 0
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		lines += 1
		maxLen = math.max(maxLen, utf8.len(line) or #line)
	end
	local w = maxLen * size * 0.5
	local lineHeight = size * (get(proxy, "LineHeight") or 1)
	if get(proxy, "TextWrapped") then
		local _, _, boxW = absRect(proxy)
		if boxW > 0 and w > boxW then
			lines += math.ceil(w / boxW) - 1
			w = boxW
		end
	end
	return Vector2.new(w, lines * lineHeight)
end

local textGetters = {
	TextBounds = function(proxy)
		return textBounds(proxy)
	end,
	TextFits = function(proxy)
		local b = textBounds(proxy)
		local _, _, w, h = absRect(proxy)
		return b.X <= w + 0.5 and b.Y <= h + 0.5
	end,
	ContentText = function(proxy)
		local text = tostring(get(proxy, "Text"))
		if get(proxy, "RichText") then
			text = stripRichText(text)
		end
		return text
	end,
}
-- Linked properties: setting one updates the other, like Roblox.
local fontByKey = nil
local function enumForFont(font)
	if not fontByKey then
		fontByKey = {}
		for _, item in Enum.Font:GetEnumItems() do
			local ok, f = pcall(roblox.Font.fromEnum, item)
			if ok and f then
				local key = f.Family .. "|" .. f.Weight.Name .. "|" .. f.Style.Name
				if not fontByKey[key] then
					fontByKey[key] = item
				end
			end
		end
	end
	return fontByKey[font.Family .. "|" .. font.Weight.Name .. "|" .. font.Style.Name] or Enum.Font.Unknown
end

local textLinks = {
	getters = {
		Font = function(proxy)
			return enumForFont(get(proxy, "FontFace"))
		end,
		TextWrap = function(proxy)
			return get(proxy, "TextWrapped")
		end,
		TextColor = function(proxy)
			return roblox.BrickColor.new(get(proxy, "TextColor3"))
		end,
	},
	setters = {
		Font = function(proxy, st, v)
			local ok, face = pcall(roblox.Font.fromEnum, v)
			if ok and face then
				Inst.setRaw(proxy, st, "FontFace", face)
			end
			Inst.changed(proxy, st, "Font", v)
		end,
		TextWrap = function(proxy, st, v)
			Inst.setRaw(proxy, st, "TextWrapped", v)
		end,
		TextColor = function(proxy, st, v)
			Inst.setRaw(proxy, st, "TextColor3", v.Color)
		end,
	},
}
for k, v in textGetters do
	textLinks.getters[k] = v
end
B.TextLabel = textLinks
B.TextButton = textLinks

local focusedBox = nil
Classes.focusedBox = function()
	return focusedBox
end

B.TextBox = {
	getters = textLinks.getters,
	setters = textLinks.setters,
	methods = {
		CaptureFocus = function(self)
			selfState(self, "CaptureFocus")
			if focusedBox == self then
				return
			end
			focusedBox = self
			Inst.fire(self, "Focused")
		end,
		ReleaseFocus = function(self, submitted)
			selfState(self, "ReleaseFocus")
			if focusedBox == self then
				focusedBox = nil
				Inst.fire(self, "FocusLost", submitted == true, nil)
			end
		end,
		IsFocused = function(self)
			selfState(self, "IsFocused")
			return focusedBox == self
		end,
	},
}

B.UIGridStyleLayout = {
	getters = {
		AbsoluteContentSize = function(proxy, st)
			local parent = st.parent
			if not parent then
				return Vector2.zero
			end
			local horizontal = get(proxy, "FillDirection") == Enum.FillDirection.Horizontal
			local padding = 0
			if st.info.rec.props.Padding then
				local _, _, pw, ph = absRect(parent)
				local pad = get(proxy, "Padding")
				padding = pad.Offset + pad.Scale * (if horizontal then pw else ph)
			end
			local main, cross, n = 0, 0, 0
			for _, c in S[parent].children do
				local cs = S[c]
				if cs.info.rec.isA.GuiObject and get(c, "Visible") then
					local _, _, w, h = absRect(c)
					n += 1
					if horizontal then
						main += w
						cross = math.max(cross, h)
					else
						main += h
						cross = math.max(cross, w)
					end
				end
			end
			main += math.max(0, n - 1) * padding
			return if horizontal then Vector2.new(main, cross) else Vector2.new(cross, main)
		end,
	},
	methods = {
		ApplyLayout = function(self)
			selfState(self, "ApplyLayout")
		end,
	},
}

B.ScrollingFrame = {
	getters = {
		AbsoluteCanvasSize = function(proxy)
			local _, _, w, h = absRect(proxy)
			local canvas = get(proxy, "CanvasSize")
			return Vector2.new(math.max(w, canvas.X.Offset + canvas.X.Scale * w), math.max(h, canvas.Y.Offset + canvas.Y.Scale * h))
		end,
		AbsoluteWindowSize = function(proxy)
			local _, _, w, h = absRect(proxy)
			return Vector2.new(w, h)
		end,
	},
}

-- GuiObject:TweenPosition / TweenSize / TweenSizeAndPosition (legacy)
local function legacyTween(self, method: string, props: { [string]: any }, time: any, override: any, callback: any)
	local st = selfState(self, method)
	local duration = tonumber(time) or 1
	if st.legacyTweening and not override then
		return false
	end
	st.legacyTweening = true
	Sched.after(duration, function()
		st.legacyTweening = false
		for k, v in props do
			if v ~= nil then
				Inst.setRaw(self, st, k, v)
			end
		end
		if type(callback) == "function" then
			Sched.spawn(callback, Enum.TweenStatus.Completed)
		end
	end)
	return true
end

B.GuiObject = {
	getters = {
		Transparency = function(proxy) -- deprecated alias
			return get(proxy, "BackgroundTransparency")
		end,
		BackgroundColor = function(proxy)
			return roblox.BrickColor.new(get(proxy, "BackgroundColor3"))
		end,
		BorderColor = function(proxy)
			return roblox.BrickColor.new(get(proxy, "BorderColor3"))
		end,
	},
	setters = {
		Transparency = function(proxy, st, v)
			Inst.setRaw(proxy, st, "BackgroundTransparency", v)
			Inst.changed(proxy, st, "Transparency", v)
		end,
		BackgroundColor = function(proxy, st, v)
			Inst.setRaw(proxy, st, "BackgroundColor3", v.Color)
		end,
		BorderColor = function(proxy, st, v)
			Inst.setRaw(proxy, st, "BorderColor3", v.Color)
		end,
	},
	methods = {
		TweenPosition = function(self, endPosition, _dir, _style, time, override, callback)
			checkType(endPosition, "UDim2", 1, "TweenPosition")
			return legacyTween(self, "TweenPosition", { Position = endPosition }, time, override, callback)
		end,
		TweenSize = function(self, endSize, _dir, _style, time, override, callback)
			checkType(endSize, "UDim2", 1, "TweenSize")
			return legacyTween(self, "TweenSize", { Size = endSize }, time, override, callback)
		end,
		TweenSizeAndPosition = function(self, endSize, endPosition, _dir, _style, time, override, callback)
			checkType(endSize, "UDim2", 1, "TweenSizeAndPosition")
			checkType(endPosition, "UDim2", 2, "TweenSizeAndPosition")
			return legacyTween(self, "TweenSizeAndPosition", { Size = endSize, Position = endPosition }, time, override, callback)
		end,
	},
}

--------------------------------------------------------------------------
-- Sounds and effects
--------------------------------------------------------------------------

local SOUND_LENGTH = 2

local function soundEnd(proxy, st)
	st.playing = false
	Inst.changed(proxy, st, "IsPlaying", false)
	Inst.fire(proxy, "Ended", get(proxy, "SoundId"))
end

local function soundPlay(proxy, st)
	if st.destroyed then
		return
	end
	st.playing = true
	st.paused = false
	st.playToken = (st.playToken or 0) + 1
	local token = st.playToken
	Inst.fire(proxy, "Played", get(proxy, "SoundId"))
	if not get(proxy, "Looped") then
		local speed = math.max(0.05, tonumber(get(proxy, "PlaybackSpeed")) or 1)
		Sched.after(SOUND_LENGTH / speed, function()
			if st.playToken == token and st.playing and not st.destroyed then
				soundEnd(proxy, st)
			end
		end)
	end
end

B.Sound = {
	getters = {
		IsPlaying = function(_, st)
			return st.playing == true
		end,
		Playing = function(_, st)
			return st.playing == true
		end,
		IsPaused = function(_, st)
			return st.paused == true
		end,
		IsLoaded = function(proxy)
			return get(proxy, "SoundId") ~= ""
		end,
		TimeLength = function(proxy)
			return if get(proxy, "SoundId") ~= "" then SOUND_LENGTH else 0
		end,
		PlaybackLoudness = function(_, st)
			return if st.playing then 100 else 0
		end,
	},
	setters = {
		Playing = function(proxy, st, v)
			if v and not st.playing then
				soundPlay(proxy, st)
			elseif not v and st.playing then
				st.playing = false
				st.paused = true
			end
		end,
	},
	methods = {
		Play = function(self)
			local st = selfState(self, "Play")
			soundPlay(self, st)
		end,
		Stop = function(self)
			local st = selfState(self, "Stop")
			if st.playing or st.paused then
				st.playing = false
				st.paused = false
				Inst.fire(self, "Stopped", get(self, "SoundId"))
			end
		end,
		Pause = function(self)
			local st = selfState(self, "Pause")
			if st.playing then
				st.playing = false
				st.paused = true
				Inst.fire(self, "Paused", get(self, "SoundId"))
			end
		end,
		Resume = function(self)
			local st = selfState(self, "Resume")
			if st.paused then
				st.paused = false
				st.playing = true
				Inst.fire(self, "Resumed", get(self, "SoundId"))
			end
		end,
	},
}

B.ParticleEmitter = {
	methods = {
		Emit = function(self, count)
			selfState(self, "Emit")
			if count ~= nil and type(count) ~= "number" then
				raise("invalid argument #1 to 'Emit' (number expected, got " .. typeOf(count) .. ")", "Invalid API arguments")
			end
		end,
		Clear = function(self)
			selfState(self, "Clear")
		end,
	},
}

--------------------------------------------------------------------------
-- Tools, humanoids, animation
--------------------------------------------------------------------------

local function isCharacter(model)
	if not model then
		return false
	end
	return Classes.playerFromCharacter and Classes.playerFromCharacter(model) ~= nil
end

B.Tool = {
	parentChanged = function(proxy, st, old, new)
		local wasEquipped = isCharacter(old)
		local nowEquipped = isCharacter(new)
		if nowEquipped and not wasEquipped then
			local player = Classes.playerFromCharacter(new)
			local mouse = player and Classes.getMouse and Classes.getMouse(player) or nil
			Inst.fire(proxy, "Equipped", mouse)
		elseif wasEquipped and not nowEquipped then
			Inst.fire(proxy, "Unequipped")
		end
	end,
	methods = {
		Activate = function(self)
			local st = selfState(self, "Activate")
			if isCharacter(st.parent) then
				Inst.fire(self, "Activated")
			end
		end,
		Deactivate = function(self)
			local st = selfState(self, "Deactivate")
			if isCharacter(st.parent) then
				Inst.fire(self, "Deactivated")
			end
		end,
	},
}

local function newTrack(animation)
	local track = Inst.create("AnimationTrack")
	local ts = S[track]
	ts.props.Animation = animation
	return track
end

local function loadAnimation(self, animation, method)
	selfState(self, method)
	if not Inst.is(animation) or not Inst.isA(animation, "Animation") then
		raise("invalid argument #1 to '" .. method .. "' (Animation expected, got " .. typeOf(animation) .. ")", "Invalid API arguments")
	end
	return newTrack(animation)
end

B.Humanoid = {
	getters = {
		RootPart = function(proxy, st)
			local parent = st.parent
			if not parent then
				return nil
			end
			return Inst.findChild(S[parent], "HumanoidRootPart")
		end,
		MoveDirection = function()
			return Vector3.zero
		end,
		FloorMaterial = function()
			return Enum.Material.Grass
		end,
	},
	setters = {
		Health = function(proxy, st, v)
			local max = get(proxy, "MaxHealth")
			v = math.clamp(v, 0, max)
			local old = get(proxy, "Health")
			if old == v then
				return
			end
			st.props.Health = v
			Inst.changed(proxy, st, "Health", v)
			Inst.fire(proxy, "HealthChanged", v)
			if v <= 0 and old > 0 then
				Inst.fire(proxy, "Died")
			end
		end,
	},
	methods = {
		EquipTool = function(self, tool)
			local st = selfState(self, "EquipTool")
			if not Inst.is(tool) or not Inst.isA(tool, "Tool") then
				raise("invalid argument #1 to 'EquipTool' (Tool expected, got " .. typeOf(tool) .. ")", "Invalid API arguments")
			end
			local character = st.parent
			if not character then
				return
			end
			for _, c in table.clone(S[character].children) do
				if c ~= tool and S[c].info.rec.isA.Tool then
					local player = Classes.playerFromCharacter and Classes.playerFromCharacter(character)
					local backpack = player and Inst.findChild(S[player], "Backpack")
					Inst.setParent(c, S[c], backpack)
				end
			end
			Inst.setParent(tool, S[tool], character)
		end,
		UnequipTools = function(self)
			local st = selfState(self, "UnequipTools")
			local character = st.parent
			if not character then
				return
			end
			local player = Classes.playerFromCharacter and Classes.playerFromCharacter(character)
			local backpack = player and Inst.findChild(S[player], "Backpack")
			for _, c in table.clone(S[character].children) do
				if S[c].info.rec.isA.Tool then
					Inst.setParent(c, S[c], backpack)
				end
			end
		end,
		GetState = function(self)
			local st = selfState(self, "GetState")
			return st.humanoidState or Enum.HumanoidStateType.Running
		end,
		ChangeState = function(self, state)
			local st = selfState(self, "ChangeState")
			if typeOf(state) ~= "EnumItem" then
				raise("invalid argument #1 to 'ChangeState' (EnumItem expected, got " .. typeOf(state) .. ")", "Invalid API arguments")
			end
			local old = st.humanoidState or Enum.HumanoidStateType.Running
			st.humanoidState = state
			Inst.fire(self, "StateChanged", old, state)
		end,
		SetStateEnabled = function(self)
			selfState(self, "SetStateEnabled")
		end,
		GetStateEnabled = function(self)
			selfState(self, "GetStateEnabled")
			return true
		end,
		MoveTo = function(self, position)
			selfState(self, "MoveTo")
			checkType(position, "Vector3", 1, "MoveTo")
			Sched.after(1, function()
				Inst.fire(self, "MoveToFinished", true)
			end)
		end,
		Move = function(self)
			selfState(self, "Move")
		end,
		TakeDamage = function(self, amount)
			selfState(self, "TakeDamage")
			checkType(amount, "number", 1, "TakeDamage")
			self.Health = get(self, "Health") - amount
		end,
		LoadAnimation = function(self, animation)
			return loadAnimation(self, animation, "LoadAnimation")
		end,
		GetPlayingAnimationTracks = function(self)
			selfState(self, "GetPlayingAnimationTracks")
			return {}
		end,
		GetAppliedDescription = function(self)
			selfState(self, "GetAppliedDescription")
			return Inst.create("HumanoidDescription")
		end,
	},
}

B.Animator = {
	methods = {
		LoadAnimation = function(self, animation)
			return loadAnimation(self, animation, "LoadAnimation")
		end,
		GetPlayingAnimationTracks = function(self)
			selfState(self, "GetPlayingAnimationTracks")
			return {}
		end,
	},
}

B.AnimationTrack = {
	getters = {
		IsPlaying = function(_, st)
			return st.playing == true
		end,
		Length = function()
			return 1
		end,
	},
	methods = {
		Play = function(self)
			local st = selfState(self, "Play")
			st.playing = true
		end,
		Stop = function(self)
			local st = selfState(self, "Stop")
			if st.playing then
				st.playing = false
				Inst.fire(self, "Stopped")
			end
		end,
		AdjustSpeed = function(self)
			selfState(self, "AdjustSpeed")
		end,
		AdjustWeight = function(self)
			selfState(self, "AdjustWeight")
		end,
		GetMarkerReachedSignal = function(self, name)
			local st = selfState(self, "GetMarkerReachedSignal")
			st.markerSignals = st.markerSignals or {}
			local sig = st.markerSignals[name]
			if not sig then
				sig = Signal.new("AnimationTrack marker " .. tostring(name))
				st.markerSignals[name] = sig
			end
			return sig
		end,
		GetTimeOfKeyframe = function(self)
			selfState(self, "GetTimeOfKeyframe")
			return 0
		end,
	},
}

--------------------------------------------------------------------------
-- Prompts
--------------------------------------------------------------------------

B.ProximityPrompt = {
	methods = {
		InputHoldBegin = function(self)
			selfState(self, "InputHoldBegin")
			local player = Classes.localPlayer
			Inst.fire(self, "PromptButtonHoldBegan", player)
			if Classes.promptService then
				Inst.fire(Classes.promptService, "PromptButtonHoldBegan", self, player)
			end
		end,
		InputHoldEnd = function(self)
			selfState(self, "InputHoldEnd")
			local player = Classes.localPlayer
			Inst.fire(self, "PromptButtonHoldEnded", player)
			if Classes.promptService then
				Inst.fire(Classes.promptService, "PromptButtonHoldEnded", self, player)
			end
		end,
	},
}

--------------------------------------------------------------------------
-- Remotes and bindables
--------------------------------------------------------------------------

local function serverOnly(method: string)
	return function(self)
		selfState(self, method)
		raise(method .. " can only be called from the server", "Invalid API use")
	end
end

B.RemoteEvent = {
	methods = {
		FireServer = function(self, ...)
			selfState(self, "FireServer")
			local args = table.pack(...)
			for i = 1, args.n do
				local t = typeOf(args[i])
				if t == "function" or t == "thread" then
					Report.add("WARN", "Suspicious API arguments", "FireServer argument #" .. i .. " is a " .. t .. " (it arrives as nil)", Report.callerLocation())
				end
			end
			if Classes.remoteHooks then
				Classes.remoteHooks.fireServer(self, args)
			end
		end,
		FireClient = serverOnly("FireClient"),
		FireAllClients = serverOnly("FireAllClients"),
	},
}
B.UnreliableRemoteEvent = B.RemoteEvent

B.RemoteFunction = {
	methods = {
		InvokeServer = function(self, ...)
			selfState(self, "InvokeServer")
			local args = table.pack(...)
			if not Classes.remoteHooks then
				Sched.sleep(1e9)
				return nil
			end
			return Classes.remoteHooks.invokeServer(self, args)
		end,
		InvokeClient = serverOnly("InvokeClient"),
	},
}

B.BindableEvent = {
	methods = {
		Fire = function(self, ...)
			selfState(self, "Fire")
			local args = table.pack(...)
			for i = 1, args.n do
				args[i] = Util.deepCopy(args[i])
			end
			Inst.fire(self, "Event", table.unpack(args, 1, args.n))
		end,
	},
}

B.BindableFunction = {
	methods = {
		Invoke = function(self, ...)
			local st = selfState(self, "Invoke")
			local cb = st.callbacks and st.callbacks.OnInvoke
			if not cb then
				raise("BindableFunction:Invoke() called with no OnInvoke callback set", "Invalid API use")
			end
			return cb(...)
		end,
	},
}

--------------------------------------------------------------------------
-- Camera
--------------------------------------------------------------------------

local function project(camera, position)
	local cf = get(camera, "CFrame")
	local rel = cf:PointToObjectSpace(position)
	local depth = -rel.Z
	local vp = Classes.viewport
	local scale = (vp.Y / 2) / math.tan(math.rad(get(camera, "FieldOfView")) / 2)
	local d = if math.abs(depth) < 1e-4 then 1e-4 else depth
	local x = vp.X / 2 + rel.X / d * scale
	local y = vp.Y / 2 - rel.Y / d * scale
	local onScreen = depth > 0 and x >= 0 and x <= vp.X and y >= 0 and y <= vp.Y
	return Vector3.new(x, y, depth), onScreen
end

local function viewportRay(camera, x, y, depth)
	local cf = get(camera, "CFrame")
	local vp = Classes.viewport
	local scale = (vp.Y / 2) / math.tan(math.rad(get(camera, "FieldOfView")) / 2)
	local dir = Vector3.new((x - vp.X / 2) / scale, -(y - vp.Y / 2) / scale, -1).Unit
	local worldDir = cf:VectorToWorldSpace(dir)
	return roblox.Ray.new(cf.Position + worldDir * (depth or 0), worldDir)
end

B.Camera = {
	getters = {
		ViewportSize = function()
			return Classes.viewport
		end,
		NearPlaneZ = function()
			return -0.1
		end,
	},
	methods = {
		WorldToViewportPoint = function(self, position)
			selfState(self, "WorldToViewportPoint")
			checkType(position, "Vector3", 1, "WorldToViewportPoint")
			return project(self, position)
		end,
		WorldToScreenPoint = function(self, position)
			selfState(self, "WorldToScreenPoint")
			checkType(position, "Vector3", 1, "WorldToScreenPoint")
			local v, on = project(self, position)
			return Vector3.new(v.X, v.Y - Classes.guiInset, v.Z), on
		end,
		ViewportPointToRay = function(self, x, y, depth)
			selfState(self, "ViewportPointToRay")
			checkType(x, "number", 1, "ViewportPointToRay")
			checkType(y, "number", 2, "ViewportPointToRay")
			return viewportRay(self, x, y, depth)
		end,
		ScreenPointToRay = function(self, x, y, depth)
			selfState(self, "ScreenPointToRay")
			checkType(x, "number", 1, "ScreenPointToRay")
			checkType(y, "number", 2, "ScreenPointToRay")
			return viewportRay(self, x, y + Classes.guiInset, depth)
		end,
		GetPartsObscuringTarget = function(self)
			selfState(self, "GetPartsObscuringTarget")
			return {}
		end,
		ZoomToExtents = function(self)
			selfState(self, "ZoomToExtents")
		end,
		GetRenderCFrame = function(self)
			selfState(self, "GetRenderCFrame")
			return get(self, "CFrame")
		end,
		GetRoll = function(self)
			selfState(self, "GetRoll")
			return 0
		end,
	},
}

--------------------------------------------------------------------------
-- Tweens (created by TweenService:Create in services.luau)
--------------------------------------------------------------------------

B.TweenBase = {
	methods = {
		Play = function(self)
			local st = selfState(self, "Play")
			if Classes.tweenPlay then
				Classes.tweenPlay(self, st)
			end
		end,
		Pause = function(self)
			local st = selfState(self, "Pause")
			if Classes.tweenPause then
				Classes.tweenPause(self, st)
			end
		end,
		Cancel = function(self)
			local st = selfState(self, "Cancel")
			if Classes.tweenCancel then
				Classes.tweenCancel(self, st)
			end
		end,
	},
}

return Classes
