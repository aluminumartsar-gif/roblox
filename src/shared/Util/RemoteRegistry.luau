local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteRegistry = {}

function RemoteRegistry.getFolder(folderName: string)
	return ReplicatedStorage:WaitForChild(folderName)
end

function RemoteRegistry.ensureFolder(folderName: string)
	local folder = ReplicatedStorage:FindFirstChild(folderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = ReplicatedStorage
	end

	return folder
end

function RemoteRegistry.ensureRemote(folderName: string, remoteName: string)
	local folder = RemoteRegistry.ensureFolder(folderName)
	local remote = folder:FindFirstChild(remoteName)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = remoteName
		remote.Parent = folder
	end

	return remote
end

function RemoteRegistry.ensureRemotes(folderName: string, remoteNames: { string })
	local remotes = {}

	for _, remoteName in remoteNames do
		remotes[remoteName] = RemoteRegistry.ensureRemote(folderName, remoteName)
	end

	return remotes
end

function RemoteRegistry.getRemote(folderName: string, remoteName: string)
	local folder = RemoteRegistry.getFolder(folderName)
	return folder:WaitForChild(remoteName)
end

return RemoteRegistry
