local Mock = require("mock")
Mock.Install()
local Ccmd = require("lib.ccmd")
local Layout = require("lib.layout")
local Config = require("server.config")
local Storage = require("server.storage")
local Router = require("server.router")
local Search = require("server.search")
local Auth = require("server.auth")

Config.Init("/ccinternet/data")
Mock.AddDrive("left", true)
Mock.AddDrive("drive_0", true)
Mock.AddDrive("drive_1", true)
Mock.AddDrive("drive_2", true)
Mock.AddDrive("drive_3", true)
Mock.AddDrive("drive_4", true)
Mock.AddDrive("drive_5", true)
Storage.Scan()

local function Request(Method, Url, Body)
	local Response = Router.SafeHandle({ Head = { Method = Method, Url = Url, Headers = {} }, Body = Body }, 7)
	return Response, type(Response.Body) == "string" and Response.Body:sub(1, 1) == "-" and Ccmd.Parse(Response.Body) or nil
end

local function Contains(Response, Text)
	return type(Response.Body) == "string" and Response.Body:find(Text, 1, true) ~= nil
end

local function Site(Domain, Files)
	local Salt = Auth.Salt()
	local Entry = assert(Storage.Create(Domain, Salt, Auth.Hash("secret", Salt), { Empty = true }))
	assert(Storage.Upload(Entry, Files, "/"))
	return Entry
end

-- Without a search drive cc.net is optional: the home page falls back to domain://.
Equal(Storage.SearchDrive, nil, "no search drive yet")
local Fallback = Request("GET", "ccmd://cc.net/")
Equal(Fallback.Status, 302, "cc.net redirects without its disk")
Equal(Fallback.Headers.Location, "domain://", "redirects to domain://")
Equal(Request("GET", "ccmd://cc.net/search?q=x").Status, 503, "search offline without its disk")
Check(not Storage.ValidDomain("cc.net"), "cc.net cannot be registered")

-- A blank floppy on the right becomes the cc.net disk and leaves the cluster.
local Right = Mock.AddDrive("right", true)
Storage.Scan()
Check(Storage.SearchReady(), "search disk set up")
Equal(Storage.SearchDrive.Name, "right", "search drive side")
Equal(disk.getLabel("right"), "cc.net", "search floppy labelled")
Check(fs.exists("/" .. Right.Disk.Mount .. "/" .. Storage.SearchFile), "search marker written")
Equal(Storage.Counts().Drives, 6, "search drive is not a cluster drive")
Equal(Storage.Counts().Blank, 6, "search floppy is not offered for registration")

Site("blocks.com", {
	["index.ccmd"] = "--\ntitle: Blocks Inc\nlocation: /\n--\n<topbar>\n[Home](/)\n</topbar>\n<p>\nWe sell cobblestone and fine stone bricks.\n</p>\n",
	["mining.ccmd"] = "--\ntitle: Mining guide\nlocation: /mining\n--\nHow to find diamonds with a pickaxe.\n<table>\n| Ore | Depth |\n|---|---|\n| diamond | -58 |\n</table>\n",
	["missing.ccmd"] = "--\ntitle: Lost\nlocation: /404\n--\nNothing about diamonds here.\n"
})
Site("redstone.net", {
	["index.ccmd"] = "--\ntitle: Redstone Weekly\nlocation: /\n--\nNews about redstone, pistons and the occasional diamond farm.\n"
})
local Hidden = Site("hidden.org", {
	["index.ccmd"] = "--\ntitle: Hidden diamonds\nlocation: /\n--\ndiamond diamond diamond\n"
})
Storage.SetSuspended(Hidden, true)

-- Home page.
local Home, HomeDoc = Request("GET", "ccmd://cc.net/")
Equal(Home.Status, 200, "home status")
Equal(#HomeDoc.Errors, 0, "home parses: " .. table.concat(HomeDoc.Errors, ";"))
Equal(HomeDoc.Title, "cc.net", "home title")
Equal(HomeDoc.VerticalAlign, "center", "home is centred")
Equal(HomeDoc.Inputs[1].Name, "q", "search bar")
Check(Contains(Home, "2 websites{/} hosted"), "footer counts visible websites")
Check(Contains(Home, "Connected to {black}ccinternet"), "footer names the server")
local Buttons = {}
for _, Block in ipairs(HomeDoc.Blocks[#HomeDoc.Blocks].Blocks) do
	if (Block.Type == "button") then Buttons[#Buttons + 1] = Block end
end
Equal(#Buttons, 2, "two buttons")
Equal(Buttons[1].Text, "Search", "search button")
Equal(Buttons[2].Text, "I'm Feeling Blocky", "blocky button")
Check(Buttons[2].Inline, "blocky button shares the row")

-- Laid out, everything is centred and the footer sits on the bottom row.
local Page = Layout.Build(HomeDoc, 51, 17)
Equal(Page.Footer.Size, 1, "one footer row")
Equal(Page.FooterY, 17, "footer on the last row")
local Field = Layout.InputRegion(Page, 1)
Equal(Field.X1, 11, "search bar centred")
local Row = Page.Rows[Field.Y + 2][1]
Check(Row:find(" Search    I'm Feeling Blocky ", 1, true) ~= nil, "buttons side by side: " .. Row)
Check(Page.Rows[1][1]:match("^%s+$") ~= nil, "content pushed down to the middle")
local Screen = Mock.NewTerm(51, 17)
Layout.Draw(Page, Screen, 0)
print(Screen.Dump())
-- The logo is made of background colours.
for Y = 1, 9 do print(Screen.State.BgRows[Y]) end

-- Results.
local Results, ResultsDoc = Request("GET", "ccmd://cc.net/search?q=diamond")
Equal(Results.Status, 200, "results status")
Equal(#ResultsDoc.Errors, 0, "results parse: " .. table.concat(ResultsDoc.Errors, ";"))
Check(Contains(Results, "2 results"), "two pages mention diamonds")
Check(Contains(Results, "[Mining guide](ccmd://blocks.com/mining)"), "result link")
Check(Contains(Results, "{green}blocks.com/mining{/}"), "result address")
Check(Contains(Results, "{black}diamond{/}"), "matches highlighted")
Check(not Contains(Results, "hidden.org"), "suspended sites are left out")
Check(not Contains(Results, "Lost"), "404 pages are not indexed")
Equal(ResultsDoc.Inputs[1].Value, "diamond", "query kept in the search bar")
local Ranked = Search.Query("blocks.com")
Equal(Ranked[1].Url, "ccmd://blocks.com/", "domain name ranks its home page first")
Equal(#Search.Query("cobblestone pistons"), 2, "any word matches")
Equal(Search.Query("diamond pickaxe")[1].Url, "ccmd://blocks.com/mining", "pages matching more words first")
Equal(#Search.Query("topbar home"), 0, "topbar text is not indexed")
local None = Request("GET", "ccmd://cc.net/search?q=zzzz")
Check(Contains(None, "No pages match"), "no results message")
Equal(Request("GET", "ccmd://cc.net/search?q=").Status, 302, "empty search goes home")

-- I'm Feeling Blocky.
local Lucky = Request("GET", "ccmd://cc.net/search?blocky=1&q=redstone")
Equal(Lucky.Status, 302, "blocky redirects")
Equal(Lucky.Headers.Location, "ccmd://redstone.net/", "to the best result")
local Random = Request("GET", "ccmd://cc.net/search?blocky=1&q=")
Equal(Random.Status, 302, "blocky without words")
Check(Random.Headers.Location == "ccmd://blocks.com/" or Random.Headers.Location == "ccmd://redstone.net/", "goes to a random visible site")

-- Paging.
local Many = {}
for Number = 1, 8 do
	Many["p" .. Number .. ".ccmd"] = "--\ntitle: Page " .. Number .. "\nlocation: /p" .. Number .. "\n--\nemerald trading\n"
end
local Shop = Site("emerald.shop", Many)
local First = Request("GET", "ccmd://cc.net/search?q=emerald")
Check(Contains(First, "8 results"), "eight results")
Check(Contains(First, "[Next >](ccmd://cc.net/search?page=2&q=emerald)"), "next page link")
local Second = Request("GET", "ccmd://cc.net/search?q=emerald&page=2")
Check(Contains(Second, "Page 2 of 8 results"), "second page")
Check(Contains(Second, "Previous](ccmd://cc.net/search?q=emerald)"), "previous link")

-- The index follows uploads and deletes, and is saved on the cc.net disk.
assert(Storage.Upload(Shop, { ["p9.ccmd"] = "--\ntitle: Diamond deals\nlocation: /p9\n--\nCheap diamonds.\n" }, "/"))
Equal(#Search.Query("diamond"), 3, "new upload indexed")
Storage.Delete(Shop, "/p9.ccmd")
Equal(#Search.Query("diamond"), 2, "deleted page dropped")
local IndexFile = "/" .. Right.Disk.Mount .. "/" .. Search.IndexFile
Check(fs.exists(IndexFile), "index saved on the disk")
Equal(Search.SaveProblem, nil, "index fits")

-- Pages of other paths.
Equal(Request("GET", "ccmd://cc.net/nothing").Status, 404, "unknown cc.net page")
Equal(Request("POST", "ccmd://cc.net/search", {}).Status, 405, "cc.net is GET only")

-- A domain floppy in the search drive keeps serving its domain.
disk.eject("right")
local Mount = Mock.InsertFloppy("right")
fs.open("/" .. Mount .. "/" .. Storage.MetaFile, "w").write(textutils.serialise({ Domain = "moved.com", Salt = "x", Hash = "y" }))
Storage.Scan()
Check(Storage.Get("moved.com") and Storage.Get("moved.com").Name == "right", "domain floppy in the search drive stays online")
Equal(Storage.SearchDrive.State, "domain", "search drive reports the domain")
Equal(Storage.SearchDrive.Domain, "moved.com", "search drive names the domain")
Check(not Storage.SearchReady(), "cc.net has no disk then")
disk.eject("right")
Storage.Scan()
Equal(Storage.SearchDrive.State, "empty", "search drive is empty")
Equal(Request("GET", "ccmd://cc.net/").Status, 302, "home falls back again")
