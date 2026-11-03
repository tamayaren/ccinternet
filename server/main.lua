-- ccinternet core: serves websites from the floppies in the connected disk drives.
-- Run on an Advanced Computer with a wireless or ender modem and wired modems to the drives.

local Program = shell.getRunningProgram()
local Root = "/" .. fs.getDir(fs.getDir(Program))
package.path = Root .. "/?.lua;" .. package.path

if (not term.isColour()) then
	printError("The ccinternet core needs an Advanced Computer.")
	return
end

local Config = require("server.config")
local Log = require("server.log")
local Storage = require("server.storage")
local Network = require("server.network")
local Router = require("server.router")
local Admin = require("server.admin")

local DataDir = fs.combine(Root, "data")
if (not fs.exists(DataDir)) then fs.makeDir(DataDir) end
math.randomseed(os.epoch and os.epoch("utc") or os.time())

Config.Init(DataDir)
Log.Init(DataDir)
Admin.Init({ Shell = shell })
Storage.TransferSide = Config.Values.TransferSide or "left"
Storage.SearchSide = Config.Values.SearchSide or "right"
Storage.Scan()

-- Ctrl+T must not stop the server or skip the lock screen.
local PullEvent = os.pullEvent
os.pullEvent = os.pullEventRaw

local JustOnboarded = false
if (not Config.IsOnboarded()) then
	Admin.Onboard()
	JustOnboarded = true
end

Network.Start(Config.Values.Hostname)
Router.OnRequest = Log.Request
Log.Event("Started as " .. Config.Values.Hostname .. (Network.Hosted and "" or (" (" .. tostring(Network.Problem) .. ")")))

-- Rescans the drives whenever a disk or peripheral comes or goes.
local function Watch()
	while (true) do
		local Event, Side = os.pullEventRaw()
		if (Event == "disk" or Event == "disk_eject" or Event == "peripheral" or Event == "peripheral_detach") then
			if (Side ~= Storage.TransferSide) then Storage.Scan() end
			if (Event == "peripheral" or Event == "peripheral_detach") then
				-- A modem may have been added or removed.
				if (not Network.Hosted) then Network.Start(Config.Values.Hostname) end
			end
			os.queueEvent("ccinternet_update")
		end
	end
end

local Ok, Problem = pcall(parallel.waitForAny, Network.Loop, Watch, function() Admin.Run(not JustOnboarded) end)

os.pullEvent = PullEvent
pcall(rednet.unhost, "ccinternet")
term.setBackgroundColour(colours.black)
term.setTextColour(colours.white)
term.clear()
term.setCursorPos(1, 1)
if (not Ok) then
	printError("ccinternet stopped: " .. tostring(Problem))
	Log.Event("Crashed: " .. tostring(Problem))
else
	print("ccinternet stopped.")
	Log.Event("Stopped")
end
