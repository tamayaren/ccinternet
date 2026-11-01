local Mock = require("mock")
Mock.Install({ Width = 51, Height = 19 })
local Config = require("server.config")
local Storage = require("server.storage")
local Admin = require("server.admin")
local Auth = require("server.auth")
local Transfer = require("server.transfer")

Config.Init("/ccinternet/data")
Mock.AddDrive("left", true)
Mock.AddDrive("drive_0", true)
Mock.AddDrive("drive_1", true)
Mock.AddDrive("drive_2", false)
Storage.Scan()
local Salt = Auth.Salt()
Storage.Create("alpha.com", Salt, Auth.Hash("pass", Salt))
Storage.Upload(Storage.Get("alpha.com"), { ["img/logo.nft"] = "\30e AB" }, "/")

local Screen = Mock.Screen
local function Find(Text)
	for Y, Row in ipairs(Screen.State.Text) do
		local X = Row:find(Text, 1, true)
		if (X) then return X, Y end
	end
end
local Shots = {}
local function Shot(Name) return function() Shots[#Shots + 1] = Name .. "\n" .. Screen.Dump() return "noop" end end
local function ClickText(Text, Button)
	return function()
		local X, Y = Find(Text)
		assert(X, "not on screen: " .. Text .. "\n" .. Screen.Dump())
		return "mouse_click", Button or 1, X, Y
	end
end

-- Onboarding: welcome OK, name, password twice, summary OK.
Mock.ReadQueue = { "ccinternet", "secret", "secret" }
Mock.Events = { { "key", keys.enter }, { "key", keys.enter } }
Admin.Onboard()
Check(Config.IsOnboarded(), "onboarded")
Equal(Config.Values.Hostname, "ccinternet", "hostname saved")
Equal(settings.get("shell.allow_disk_startup"), false, "disk startup disabled")

-- Lock screen: a wrong then a right password.
Mock.ReadQueue = { "wrong", "secret" }
Admin.Lock()
Check(true, "unlocked")

Mock.Events = {
	Shot("domains"),
	ClickText("alpha.com"),
	Shot("detail"),
	ClickText("Suspend"),
	Shot("suspended"),
	ClickText("< Back"),
	ClickText("Drives"),
	Shot("drives"),
	ClickText("Transfer"),
	Shot("transfer"),
	ClickText("Export a domain"),
	ClickText(" alpha.com"),
	{ "key", keys.enter },
	Shot("exported"),
	ClickText("Log"),
	Shot("log"),
	ClickText("Settings"),
	Shot("settings"),
	ClickText("Stop server"),
	{ "key", keys.y }
}
local Ok, Problem = pcall(Admin.Run, false)
Check(Ok, "admin ran: " .. tostring(Problem))
for _, Text in ipairs(Shots) do print(Text) print(("-"):rep(51)) end
Check(Storage.Get("alpha.com").Meta.Suspended, "suspended from the admin screen")
Equal(Transfer.Status().Domain, "alpha.com", "exported from the admin screen")
