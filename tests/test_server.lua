local Mock = require("mock")
Mock.Install()
local Protocol = require("lib.protocol")
local Ccmd = require("lib.ccmd")
local Config = require("server.config")
local Storage = require("server.storage")
local Router = require("server.router")
local Transfer = require("server.transfer")
local Network = require("server.network")
local Auth = require("server.auth")

Config.Init("/ccinternet/data")
Config.Values.AdminSalt = "x"
Mock.AddDrive("left", true)
Mock.AddDrive("drive_0", true)
Mock.AddDrive("drive_1", true)
Mock.AddDrive("drive_2", false)
Mock.AddDrive("drive_10", true)
local Foreign = Mock.AddDrive("drive_3", true)
fs.open("/" .. Foreign.Disk.Mount .. "/notes.txt", "w").write("hello")
Mock.AddPeripheral("back", "modem")
Storage.Scan()

local Counts = Storage.Counts()
Equal(Counts.Drives, 5, "transfer drive is not a cluster drive")
Equal(Counts.Blank, 3, "blank floppies")
Equal(Counts.Empty, 1, "empty drive")
Equal(Counts.Other, 1, "foreign floppy")
Equal(Storage.Drives[4].Name, "drive_3", "drives sorted by number")
Equal(Storage.Drives[5].Name, "drive_10", "drive_10 after drive_3")

local function Request(Method, Url, Body, Sender)
	local Response = Router.SafeHandle({ Head = { Method = Method, Url = Url, Headers = {} }, Body = Body }, Sender or 42)
	return Response, type(Response.Body) == "string" and Response.Body:sub(1, 1) == "-" and Ccmd.Parse(Response.Body) or nil
end

local function Hidden(Doc, Name)
	for _, Input in ipairs(Doc.Inputs) do
		if (Input.Name == Name) then return Input.Value end
	end
end

local function Contains(Response, Text)
	return type(Response.Body) == "string" and Response.Body:find(Text, 1, true) ~= nil
end

-- Home page
local Home, HomeDoc = Request("GET", "domain://")
Equal(Home.Status, 200, "home status")
Equal(#HomeDoc.Errors, 0, "home page parses")
Check(Contains(Home, "Free floppies | 3"), "home shows free floppies")

-- Registration
local Bad = Request("POST", "domain://register", { domain = "bad name", password = "pass", confirm = "pass" })
Equal(Bad.Status, 400, "invalid domain rejected")
local Short = Request("POST", "domain://register", { domain = "site.com", password = "p", confirm = "p" })
Equal(Short.Status, 400, "short password rejected")
local Reg, RegDoc = Request("POST", "domain://register", { domain = "Site.com", password = "hunter2", confirm = "hunter2" })
Equal(Reg.Status, 200, "registered")
Equal(#RegDoc.Errors, 0, "manage page parses: " .. table.concat(RegDoc.Errors, ";"))
local Token = Hidden(RegDoc, "token")
Check(Token and #Token == 32, "session token")
Check(Storage.Get("site.com") ~= nil, "domain stored")
Equal(Storage.Get("site.com").Name, "drive_0", "first blank drive used")
Equal(disk.getLabel("drive_0"), "site.com", "floppy labelled")
local Taken = Request("POST", "domain://register", { domain = "site.com", password = "hunter2", confirm = "hunter2" })
Equal(Taken.Status, 409, "taken domain")

-- Default page
local Index, IndexDoc = Request("GET", "ccmd://site.com/")
Equal(Index.Status, 200, "default page")
Equal(IndexDoc.Title, "site.com", "default title")

-- Upload
local Page1 = "--\ntitle: About\nlocation: /about\n--\nAbout us\n<form action=\"/thanks\">\n<input name=\"msg\"/>\n<button text=\"Send\"/>\n</form>\n"
local Thanks = "--\ntitle: Thanks\nlocation: /thanks\n--\nThanks!\n"
local Nft = "\30e\31f AB\n"
local Up = Request("POST", "domain://upload", { domain = "site.com", token = Token, folder = "/", files = { ["about.ccmd"] = Page1, ["pages/thanks.ccmd"] = Thanks, ["img/logo.nft"] = Nft } })
Equal(Up.Status, 200, "upload ok")
Check(Contains(Up, "Uploaded 3 files"), "upload message")
local About, AboutDoc = Request("GET", "ccmd://site.com/about")
Equal(About.Status, 200, "page by location")
Equal(AboutDoc.Title, "About", "page title")
local ByPath = Request("GET", "ccmd://site.com/about.ccmd")
Equal(ByPath.Status, 200, "page by file path")
local Img = Request("GET", "ccmd://site.com/img/logo.nft")
Equal(Img.Body, Nft, "image served")
Equal(Img.Headers["Content-Type"], "image/nft", "image content type")
local Missing = Request("GET", "ccmd://site.com/nope")
Equal(Missing.Status, 404, "missing page")
local Escape = Request("GET", "ccmd://site.com/../ccinternet.meta")
Check(Escape.Status ~= 200, "meta file cannot be read")
local NoFront = Request("POST", "domain://upload", { domain = "site.com", token = Token, files = { ["x.ccmd"] = "hello" } })
Check(Contains(NoFront, "front matter"), "page without front matter rejected")
Check(not fs.exists("/disk2/site/x.ccmd"), "rejected file not written")
local BadName = Request("POST", "domain://upload", { domain = "site.com", token = Token, files = { ["../evil"] = "x" } })
Check(Contains(BadName, "Bad file name"), "path escape rejected")
local Huge = Request("POST", "domain://upload", { domain = "site.com", token = Token, files = { ["big.txt"] = string.rep("x", 130000) } })
Check(Contains(Huge, "Not enough space"), "quota enforced")
local NoAuth = Request("POST", "domain://upload", { domain = "site.com", token = "wrong", files = { ["a.txt"] = "x" } })
Equal(NoAuth.Status, 403, "bad token rejected")
local WithPassword = Request("POST", "domain://upload", { domain = "site.com", password = "hunter2", files = { ["a.txt"] = "x" } })
Equal(WithPassword.Status, 200, "password works for API uploads")

-- Form submission
local Sent = Request("POST", "ccmd://site.com/thanks", { msg = "hi there" }, 9)
Equal(Sent.Status, 200, "form posted")
Check(Contains(Sent, "Thanks!"), "action page served after posting")
local Subs = Storage.Submissions(Storage.Get("site.com"))
Equal(#Subs, 1, "one form log")
Equal(Subs[1].Entries[1].Fields.msg, "hi there", "submission stored")
local SubPage, SubDoc = Request("GET", Protocol.Url("domain", "submissions", "/", { domain = "site.com", token = Token }))
Check(Contains(SubPage, "hi there"), "owner sees submissions")
Equal(#SubDoc.Errors, 0, "submissions page parses")

-- Login and throttling
local Login, LoginDoc = Request("POST", "domain://login", { domain = "site.com", password = "hunter2" }, 50)
Equal(Login.Status, 200, "login")
local Wrong
for _ = 1, 5 do Wrong = Request("POST", "domain://login", { domain = "site.com", password = "nope" }, 77) end
Equal(Wrong.Status, 403, "wrong password")
local Locked = Request("POST", "domain://login", { domain = "site.com", password = "hunter2" }, 77)
Equal(Locked.Status, 429, "throttled after failures")
Mock.Advance(61)
local Unlocked = Request("POST", "domain://login", { domain = "site.com", password = "hunter2" }, 77)
Equal(Unlocked.Status, 200, "throttle expires")

-- Delete
local Confirm, ConfirmDoc = Request("GET", Protocol.Url("domain", "delete", "/", { domain = "site.com", token = Token, path = "/a.txt" }))
Equal(#ConfirmDoc.Errors, 0, "delete confirm parses")
local Deleted = Request("POST", "domain://delete", { domain = "site.com", token = Token, path = "/a.txt" })
Check(Contains(Deleted, "Deleted /a.txt"), "file deleted")
Request("POST", "domain://delete", { domain = "site.com", token = Token, path = "/pages/thanks.ccmd" })
Check(not fs.exists("/disk2/site/pages"), "empty folder removed")

-- Suspension
Storage.SetSuspended(Storage.Get("site.com"), true)
Equal(Request("GET", "ccmd://site.com/").Status, 403, "suspended site")
Equal(Request("GET", "ccmd://site.com/", nil, Router.Local).Status, 200, "admin can still view")
Storage.SetSuspended(Storage.Get("site.com"), false)

-- Directory
local Dir = Request("GET", "domain://directory")
Check(Contains(Dir, "site.com"), "directory lists the domain")

-- Password change ends sessions
local Changed = Request("POST", "domain://password", { domain = "site.com", token = Token, old = "hunter2", new = "newpass", confirm = "newpass" })
Check(Contains(Changed, "Password changed"), "password changed")
Equal(Request("GET", Protocol.Url("domain", "manage", "/", { domain = "site.com", token = Token })).Status, 403, "old session ended")

-- Export and import through the transfer drive
local Ok, Problem = Transfer.Export("site.com")
Check(Ok, "export: " .. tostring(Problem))
Equal(Transfer.Status().State, "domain", "transfer floppy holds the domain")
Equal(Transfer.Status().Domain, "site.com", "transfer floppy domain")
local Again, _, Need = Transfer.Import(false)
Check(not Again and Need == "confirm", "import asks before replacing")
Storage.Release(Storage.Get("site.com"))
Check(Storage.Get("site.com") == nil, "released")
local Imported, Name = Transfer.Import(false)
Check(Imported, "import: " .. tostring(Name))
Equal(Request("GET", "ccmd://site.com/about").Status, 200, "imported site serves pages")
Check(Auth.Check("newpass", Storage.Get("site.com").Meta.Salt, Storage.Get("site.com").Meta.Hash), "password travels with the domain")

-- A floppy with a startup file only brings the domain parts.
local Side = Transfer.Status().Mount
fs.open(Side .. "/startup.lua", "w").write("print('pwned')")
Storage.Release(Storage.Get("site.com"))
Check(Transfer.Import(false), "import again")
Check(not fs.exists(Storage.Get("site.com").Mount .. "/startup.lua"), "startup.lua not copied")

-- Loose site files become a new domain.
Transfer.Wipe()
fs.open(Side .. "/index.ccmd", "w").write("--\ntitle: Loose\nlocation: /\n--\nHi")
Equal(Transfer.Status().State, "site", "loose files detected")
local Salt = Auth.Salt()
local SiteOk, SiteName = Transfer.ImportSite("loose.net", Salt, Auth.Hash("pass", Salt))
Check(SiteOk, "import site: " .. tostring(SiteName))
local Loose, LooseDoc = Request("GET", "ccmd://loose.net/")
Equal(LooseDoc and LooseDoc.Title, "Loose", "loose site served")

-- Cluster full
local Full
for Index = 1, 3 do Full = Request("POST", "domain://register", { domain = "x" .. Index .. ".com", password = "pass", confirm = "pass" }) end
Equal(Full.Status, 507, "no blank floppy left")
Check(Contains(Full, "No blank floppy"), "full message")

-- Unknown pages and schemes
Equal(Request("GET", "domain://nothing").Status, 404, "unknown domain page")
Equal(Request("GET", "http://x").Status, 400, "unknown scheme")
Equal(Request("GET", "ccmd://nobody.com/").Status, 404, "unknown site")

-- Network answer sends chunked responses over rednet.
rednet.Sent = {}
local Messages = Protocol.Pack("request", 99, { Method = "GET", Url = "ccmd://loose.net/" }, nil)
local Collector = Protocol.Assembler()
Network.Answer(Collector:Feed(12, Messages[1]))
Equal(#rednet.Sent, 1, "one response message")
Equal(rednet.Sent[1].Id, 12, "sent back to the requester")
Equal(rednet.Sent[1].Message.Head.Status, 200, "status in head")
Equal(rednet.Sent[1].Protocol, "ccinternet", "protocol name")

-- Local transport for the core's own browser.
local Local = Router.LocalTransport().Send("GET", "domain://", {}, nil)
Equal(Local.Status, 200, "local transport")
