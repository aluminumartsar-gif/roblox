local Services = script.Parent:WaitForChild("Services")
local BackgroundMusicService = require(Services:WaitForChild("BackgroundMusicService"))

BackgroundMusicService.start()
