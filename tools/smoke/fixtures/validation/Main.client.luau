--!strict
-- Fixture entry point (stands in for src/client/Main.client.luau when the
-- harness runs with --fixture validation).

require(script.Parent:WaitForChild("Mistakes"))

-- A require cycle: CycleA -> CycleB -> CycleA.
pcall(require, script.Parent:WaitForChild("CycleA"))

-- A module that errors while loading, required without a pcall.
task.spawn(function()
	require(script.Parent:WaitForChild("BrokenModule"))
end)

print("fixture: Main finished")
