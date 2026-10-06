-- Find a Model anywhere under `root` named `modelName`.
--
-- Studio map prefabs often sit under Workspace folders (Workspace.Map.Shop)
-- while some published builds keep booth models as direct Workspace children.
-- Proximity booths and teleport use this so both hierarchies behave the same.

local function findNamedModel(root: Instance, modelName: string): Model?
	local direct = root:FindFirstChild(modelName)
	if direct and direct:IsA("Model") then
		return direct
	end

	local queue = { root }
	local head = 1
	while head <= #queue do
		local node = queue[head]
		head += 1
		for _, child in node:GetChildren() do
			if child:IsA("Model") and child.Name == modelName then
				return child
			end
			table.insert(queue, child)
		end
	end

	return nil
end

return {
	findNamedModel = findNamedModel,
}
