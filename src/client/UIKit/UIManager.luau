local UIManager = {}

local registry   = {}
local openStates = {}

function UIManager.register(name: string, closeFn: () -> ())
	registry[name] = closeFn
end

function UIManager.setOpen(name: string, isOpen: boolean)
	openStates[name] = isOpen
end

function UIManager.isAnyOpen(): boolean
	for _, open in openStates do
		if open then return true end
	end
	return false
end

function UIManager.closeAllExcept(except: string)
	for name, closeFn in registry do
		if name ~= except then
			closeFn()
		end
	end
end

function UIManager.closeAll()
	for _, closeFn in registry do
		closeFn()
	end
end

return UIManager
