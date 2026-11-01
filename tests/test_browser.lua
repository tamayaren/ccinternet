local Mock = require("mock")
Mock.Install({ Width = 51, Height = 19 })
local Config = require("server.config")
local Storage = require("server.storage")
local Router = require("server.router")
local Browser = require("lib.browser")

Config.Init("/ccinternet/data")
Mock.AddDrive("left", true)
Mock.AddDrive("drive_0", true)
Storage.Scan()

local Screen = Mock.Screen

local function Find(Text)
	for Y, Row in ipairs(Screen.State.Text) do
		local X = Row:find(Text, 1, true)
		if (X) then return X, Y end
	end
	return nil
end

local Shots = {}
local function Shot(Name)
	return function()
		Shots[Name] = Screen.Dump()
		return "noop"
	end
end

-- Click on the first place Text appears, plus an offset.
local function ClickText(Text, Offset)
	return function()
		local X, Y = Find(Text)
		assert(X, "text not on screen: " .. Text .. "\n" .. Screen.Dump())
		return "mouse_click", 1, X + (Offset or 0), Y
	end
end

Mock.Events = {
	Shot("home"),
	ClickText("Register"),
	Shot("register"),
	ClickText("Domain:", 11),
	{ "mouse_click", 1, 51, 1 },
}
Mock.ReadQueue = { "test.org", "pass1", "pass1" }

local Ok, Problem = pcall(Browser.Run, { Url = "domain://", Transport = Router.LocalTransport(), Embedded = true })
Check(Ok, "browser ran: " .. tostring(Problem))
print(Shots.home)
print(("-"):rep(51))
print(Shots.register)
print(("-"):rep(51))
print(Screen.Dump())
Check(Shots.home and Shots.home:find("Welcome to", 1, true), "home page rendered")
Check(Shots.register and Shots.register:find("Confirm:", 1, true), "register form rendered")
Check(Storage.Get("test.org") ~= nil, "domain registered through the browser")
Check(Screen.Dump():find("Manage test.org", 1, true), "manage page shown")
