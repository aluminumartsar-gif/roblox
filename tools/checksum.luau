-- Run in Studio (Edit datamodel) via the MCP or the command bar.
-- Output format matches tools/checksum.sh; diff the two.
local function checksum(s)
	local sum, weighted = 0, 0
	for i = 1, #s do
		local b = string.byte(s, i)
		sum += b
		weighted = (weighted + i * b) % 4294967296
	end
	return #s, sum, weighted
end

local roots = {
	{ game:GetService("ReplicatedStorage"):FindFirstChild("Shared"), "ReplicatedStorage.Shared" },
	{ game:GetService("ServerScriptService"):FindFirstChild("Server"), "ServerScriptService.Server" },
	{ game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Client"), "StarterPlayer.StarterPlayerScripts.Client" },
}

local lines = {}
for _, root in ipairs(roots) do
	local folder, prefix = root[1], root[2]
	if folder then
		for _, inst in ipairs(folder:GetDescendants()) do
			if inst:IsA("LuaSourceContainer") then
				local rel = inst:GetFullName():sub(#folder:GetFullName() + 2)
				local n, s, w = checksum(inst.Source)
				table.insert(lines, string.format("%s.%s len=%d sum=%d weighted=%d", prefix, rel, n, s, w))
			end
		end
	end
end
table.sort(lines)
return table.concat(lines, "\n")
