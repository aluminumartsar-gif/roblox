--!strict
--[[
	Signal
	ReplicatedStorage/Shared/Util/Signal

	A tiny pure-Luau event. Used so services can announce things
	("profile loaded", "cash changed") without requiring each other.

	  local s = Signal.new()
	  local conn = s:Connect(function(a, b) ... end)
	  s:Fire(1, 2)
	  conn:Disconnect()

	Handlers run in their own thread, so one erroring handler cannot stop
	the others or the code that fired the signal.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

function Signal.new()
	return setmetatable({ _handlers = {} :: { [any]: (...any) -> () } }, Signal)
end

function Signal:Connect(handler: (...any) -> ()): Connection
	local key = {}
	self._handlers[key] = handler

	local connection = { Connected = true }
	function connection.Disconnect(conn: any)
		conn.Connected = false
		self._handlers[key] = nil
	end
	return connection :: any
end

function Signal:Fire(...: any)
	for _, handler in pairs(self._handlers) do
		task.spawn(handler, ...)
	end
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	table.clear(self._handlers)
end

return Signal
