-- The ccinternet browser for CraftOS. Runs as a program (browser.lua) or inside the core's admin screen.
--
-- Browser.Run(Options)
--   Options.Url        first page (default: the home page setting, domain://)
--   Options.Transport  object with Send(Method, Url, Headers, Body, Options) -> response | nil, error
--                      (default: rednet to the core named by the "ccinternet.host" setting)
--   Options.Embedded   true when started from another program; Quit returns instead of clearing the screen

local Ccmd = require("lib.ccmd")
local Layout = require("lib.layout")
local Image = require("lib.image")
local Protocol = require("lib.protocol")

local Browser = {}

Browser.MaxHistory = 30
Browser.CachedPages = 10
Browser.MaxRedirects = 5
Browser.MaxUpload = 125000

if (settings and settings.define) then
	settings.define("ccinternet.host", { description = "Hostname of the ccinternet core the browser connects to", default = Protocol.DefaultHost, type = "string" })
	settings.define("ccinternet.home", { description = "Home page of the ccinternet browser", default = "domain://", type = "string" })
end

local function Setting(Name, Default)
	if (settings) then
		local Value = settings.get(Name)
		if (Value ~= nil and Value ~= "") then return Value end
	end
	return Default
end

local function SaveSetting(Name, Value)
	if (settings) then
		settings.set(Name, Value)
		settings.save()
	end
end

-- Builds a small page from text so errors and plain files render like any other page.
local function MessageSource(Title, Message, Colour)
	return table.concat({
		"--", "title: " .. Title:gsub("\n", " "), "location: /", "--",
		"<br/>",
		"<p alignment=\"center\">",
		"{" .. (Colour or "red") .. "}" .. Ccmd.Escape(Title) .. "{/}",
		"</p>",
		"<br/>",
		"<p alignment=\"center\">",
		Ccmd.Escape(Message),
		"</p>"
	}, "\n")
end

local function TextDocument(Title, Text)
	local Lines = {}
	for Line in (tostring(Text):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
		Lines[#Lines + 1] = { { Text = (Line:gsub("[%z\1-\8\11-\31]", "?")) } }
	end
	return { Title = Title, Location = "/", Meta = {}, Blocks = { { Type = "text", Align = "left", Lines = Lines } }, Inputs = {}, Forms = {}, Errors = {}, Background = "f", TextColor = "0", LinkColor = "3" }
end

local function CollectImages(Blocks, Into)
	for _, Block in ipairs(Blocks) do
		if (Block.Type == "image") then Into[#Into + 1] = Block.Src end
		if (Block.Type == "form") then CollectImages(Block.Blocks, Into) end
	end
	return Into
end

-- Reads a local file or folder into { [relative path] = contents } for a file input.
local function ReadLocal(Path)
	local Files = {}
	local Total = 0
	local Count = 0
	local function Add(Full, Name)
		local Handle = fs.open(Full, "rb")
		if (not Handle) then return end
		local Data = Handle.readAll() or ""
		Handle.close()
		Files[Name] = Data
		Total = Total + #Data
		Count = Count + 1
	end
	local function Walk(Dir, Prefix)
		for _, Name in ipairs(fs.list(Dir)) do
			local Full = fs.combine(Dir, Name)
			if (fs.isDir(Full)) then
				if (not Name:match("^%.")) then Walk(Full, Prefix .. Name .. "/") end
			else
				Add(Full, Prefix .. Name)
			end
		end
	end
	if (not fs.exists(Path)) then return nil, "No such file or folder: " .. Path end
	if (fs.isDir(Path)) then
		Walk(Path, "")
	else
		Add(Path, fs.getName(Path))
	end
	if (Count == 0) then return nil, "The folder is empty" end
	return Files, Total, Count
end

function Browser.Run(Options)
	Options = Options or {}
	local Parent = term.current()
	local Width, Height = Parent.getSize()
	local Transport = Options.Transport or Protocol.NetworkTransport(Setting("ccinternet.host", Protocol.DefaultHost))
	local Colour = Parent.isColour and Parent.isColour()

	local PageWindow = window.create(Parent, 1, 3, Width, math.max(1, Height - 2))
	local Running = true

	-- Current page state.
	local Current = {
		Url = nil,       -- absolute URL text
		Parsed = nil,    -- parsed URL
		Response = nil,  -- last response
		Doc = nil,
		Page = nil,
		Scroll = 0,
		State = {},
		Focus = nil,     -- input being edited
		Selected = nil,  -- region index selected with Tab
		Status = "",
		StatusColour = "8"
	}
	local History = {}
	local HistoryIndex = 0
	local AddressHistory = {}
	local ImageCache = {}
	local Ctrl = false

	local CanTitle = multishell ~= nil and multishell.getCurrent ~= nil and not Options.Embedded
	local OldTitle = CanTitle and multishell.getTitle and multishell.getTitle(multishell.getCurrent()) or nil

	local function SetTitle(Text)
		if (CanTitle and Text) then pcall(multishell.setTitle, multishell.getCurrent(), Text) end
	end

	local function Images(Src)
		if (not Current.Parsed) then return nil end
		local Parsed = Protocol.ParseUrl(Src, Current.Parsed)
		if (not Parsed) then return false end
		return ImageCache[Protocol.FormatUrl(Parsed)]
	end

	local function Rebuild()
		if (not Current.Doc) then return end
		local W, H = PageWindow.getSize()
		Current.Page = Layout.Build(Current.Doc, W, H, { Images = Images, State = Current.State, Focus = Current.Focus })
		if (Current.Scroll > Current.Page.MaxScroll) then Current.Scroll = Current.Page.MaxScroll end
	end

	------------------------------------------------------------------
	-- Drawing
	------------------------------------------------------------------

	local function Fit(Text, Size)
		Text = tostring(Text or "")
		if (#Text > Size) then return Text:sub(1, math.max(0, Size - 1)) .. "\187" end
		return Text .. string.rep(" ", Size - #Text)
	end

	local function DrawChrome()
		-- Row 1: page title and status.
		local Title = Current.Doc and Current.Doc.Title or "ccinternet"
		local Status = Current.Status ~= "" and (" " .. Current.Status .. " ") or ""
		local Close = " \215"
		local TitleWidth = Width - #Status - #Close
		Parent.setCursorPos(1, 1)
		Parent.blit(
			Fit(" " .. Title, TitleWidth) .. Status .. Close,
			string.rep("0", TitleWidth) .. string.rep(Current.StatusColour, #Status) .. "0e",
			string.rep("7", Width)
		)
		-- Row 2: back, forward, reload, address, menu.
		local Address = Fit(Current.Url or "", Width - 9)
		Parent.setCursorPos(1, 2)
		Parent.blit(
			" < > @ " .. Address .. " =",
			"f" .. (HistoryIndex > 1 and "f" or "7") .. "f" .. (HistoryIndex < #History and "f" or "7") .. "fff" .. string.rep("f", #Address) .. "ff",
			string.rep("8", 7) .. string.rep("0", #Address) .. "88"
		)
	end

	local function DrawSelection()
		local Region = Current.Selected and Current.Page and Current.Page.Regions[Current.Selected]
		if (not Region) then return end
		local X, Y = Layout.RegionPosition(Current.Page, Region, Current.Scroll)
		if (not X) then return end
		local Row = Current.Page.Rows[Region.Y]
		local Text = Row[1]:sub(Region.X1, Region.X2)
		PageWindow.setCursorPos(X, Y)
		PageWindow.blit(Text, string.rep("f", #Text), string.rep("4", #Text))
	end

	local function Draw()
		Parent.setCursorBlink(false)
		DrawChrome()
		PageWindow.setVisible(false)
		if (Current.Page) then
			Layout.Draw(Current.Page, PageWindow, Current.Scroll)
			DrawSelection()
		else
			PageWindow.setBackgroundColour(colours.black)
			PageWindow.clear()
		end
		PageWindow.setVisible(true)
	end

	local function SetStatus(Text, Colour_)
		Current.Status = Text or ""
		Current.StatusColour = Colour_ or "8"
		DrawChrome()
	end

	------------------------------------------------------------------
	-- Loading pages
	------------------------------------------------------------------

	local function Show(Doc, Response, Url, Keep)
		Current.Doc = Doc
		Current.Response = Response
		Current.Url = Url
		Current.Parsed = Protocol.ParseUrl(Url)
		if (not Keep) then
			Current.Scroll = 0
			Current.State = {}
		end
		Current.Focus = nil
		Current.Selected = nil
		SetTitle(Doc.Title or "ccinternet")
		Rebuild()
	end

	local function LoadImages()
		local Pending = {}
		local Seen = {}
		for _, Src in ipairs(CollectImages(Current.Doc.Blocks, {})) do
			local Parsed = Protocol.ParseUrl(Src, Current.Parsed)
			if (Parsed) then
				local Key = Protocol.FormatUrl(Parsed)
				if (ImageCache[Key] == nil and not Seen[Key]) then
					Seen[Key] = true
					Pending[#Pending + 1] = { Key = Key, Path = Parsed.Path }
				end
			end
		end
		for Index, Item in ipairs(Pending) do
			SetStatus("Image " .. Index .. "/" .. #Pending, "8")
			local Ok, Response = pcall(Transport.Send, "GET", Item.Key, { Accept = "image/*" }, nil, { Timeout = 5 })
			if (not Ok) then
				if (tostring(Response):match("Terminated")) then Running = false end
				return
			end
			local Picture = false
			if (Response and Response.Status == 200 and type(Response.Body) == "string") then
				local Kind = (Response.Headers["Content-Type"] or ""):match("^image/(%w+)") or Item.Path
				Picture = Image.Parse(Response.Body, Kind) or false
			end
			ImageCache[Item.Key] = Picture
			Rebuild()
			Draw()
		end
	end

	-- Turns a response into a document.
	local function Interpret(Response, Parsed)
		local Type = (Response.Headers["Content-Type"] or ""):lower()
		local Name = Parsed.Path:match("[^/]*$")
		if (Name == "") then Name = Parsed.Host end
		if (type(Response.Body) ~= "string") then
			return Ccmd.Parse(MessageSource("Empty response", "The server sent nothing back (status " .. Response.Status .. ")."))
		end
		if (Type == "text/ccmd" or (Type == "" and Parsed.Path:match("%.ccmd$"))) then
			return Ccmd.Parse(Response.Body)
		end
		local Kind = Type:match("^image/(%w+)")
		if (Kind and Image.Extensions[Kind]) then
			ImageCache[Protocol.FormatUrl(Parsed)] = Image.Parse(Response.Body, Kind) or false
			local Doc = TextDocument(Name, "")
			Doc.Blocks = { { Type = "image", Src = Protocol.FormatUrl(Parsed), Align = "center" } }
			return Doc
		end
		if (Type:match("^text/")) then return TextDocument(Name, Response.Body) end
		return Ccmd.Parse(MessageSource(Name, "This is a " .. #Response.Body .. " byte file (" .. (Type ~= "" and Type or "unknown type") .. ").\nOpen the menu (=) and choose Save to keep it.", "yellow"))
	end

	local function PushHistory(Url, Response)
		for Index = #History, HistoryIndex + 1, -1 do History[Index] = nil end
		History[#History + 1] = { Url = Url, Response = Response, Scroll = 0 }
		while (#History > Browser.MaxHistory) do table.remove(History, 1) end
		HistoryIndex = #History
		for Index = 1, #History - Browser.CachedPages do History[Index].Response = nil end
	end

	-- Requests a URL and shows the result. Method defaults to GET.
	local function Navigate(Target, Method, Body, FromHistory)
		local Parsed = Protocol.ParseUrl(Target, Current.Parsed)
		if (not Parsed) then
			SetStatus("Bad address", "e")
			return
		end
		if (Parsed.Scheme ~= "ccmd" and Parsed.Scheme ~= "domain") then
			SetStatus(Parsed.Scheme .. ":// is not supported", "e")
			return
		end
		Method = Method or "GET"
		local Url = Protocol.FormatUrl(Parsed)
		if (History[HistoryIndex] and not FromHistory) then History[HistoryIndex].Scroll = Current.Scroll end
		SetStatus("Loading...", "4")
		local Response, Problem
		for _ = 1, Browser.MaxRedirects + 1 do
			local Ok
			Ok, Response, Problem = pcall(Transport.Send, Method, Url, { Accept = "text/ccmd" }, Body, {
				OnProgress = function(Received, Total) SetStatus("Loading " .. Received .. "/" .. Total, "4") end
			})
			if (not Ok) then
				if (tostring(Response):match("Terminated")) then
					Running = false
					return
				end
				Response, Problem = nil, Response
			end
			if (not Response) then break end
			local Location = Response.Headers.Location
			if (Response.Status < 300 or Response.Status >= 400 or type(Location) ~= "string") then break end
			Parsed = Protocol.ParseUrl(Location, Parsed)
			if (not Parsed) then break end
			Url = Protocol.FormatUrl(Parsed)
			Method, Body = "GET", nil
		end
		local Doc
		if (not Response) then
			Doc = Ccmd.Parse(MessageSource("Cannot connect", tostring(Problem) .. "\n\nCheck that this computer has a wireless or ender modem and that the core is running.", "red"))
			Response = { Status = 0, Headers = {}, Body = nil }
		else
			Doc = Interpret(Response, Parsed)
		end
		if (not FromHistory) then PushHistory(Url, Response) end
		Show(Doc, Response, Url)
		if (Response.Status >= 400) then
			SetStatus(tostring(Response.Status), "e")
		elseif (#Doc.Errors > 0) then
			SetStatus(#Doc.Errors .. (#Doc.Errors == 1 and " problem" or " problems"), "1")
		else
			SetStatus("")
		end
		Draw()
		LoadImages()
		if (Current.Status:match("^Image")) then SetStatus("") end
	end

	local function GoHistory(Index)
		local Entry = History[Index]
		if (not Entry) then return end
		if (History[HistoryIndex]) then History[HistoryIndex].Scroll = Current.Scroll end
		HistoryIndex = Index
		if (Entry.Response) then
			local Parsed = Protocol.ParseUrl(Entry.Url)
			Show(Interpret(Entry.Response, Parsed), Entry.Response, Entry.Url)
			Current.Scroll = math.min(Entry.Scroll or 0, Current.Page and Current.Page.MaxScroll or 0)
			SetStatus("")
			Draw()
			LoadImages()
			SetStatus("")
		else
			Navigate(Entry.Url, "GET", nil, true)
			Entry.Response = Current.Response
		end
	end

	local function Reload()
		if (not Current.Url) then return end
		local Scroll = Current.Scroll
		Navigate(Current.Url, "GET", nil, true)
		if (History[HistoryIndex]) then History[HistoryIndex].Response = Current.Response end
		Current.Scroll = math.min(Scroll, Current.Page and Current.Page.MaxScroll or 0)
		Draw()
	end

	------------------------------------------------------------------
	-- Prompts and editing
	------------------------------------------------------------------

	-- Reads a line of text in a box on the given row. Returns the text, or nil when left empty.
	local function ReadAt(X, Y, W, Default, Replace, Fg, Bg, HistoryList, Complete)
		local Box = window.create(Parent, X, Y, math.max(1, W), 1)
		Box.setBackgroundColour(Bg or colours.white)
		Box.setTextColour(Fg or colours.black)
		Box.clear()
		Box.setCursorPos(1, 1)
		local Previous = term.redirect(Box)
		local Ok, Result = pcall(read, Replace, HistoryList, Complete, Default)
		term.redirect(Previous)
		if (not Ok) then
			if (tostring(Result):match("Terminated")) then Running = false end
			return nil
		end
		return Result
	end

	local function Prompt(Label, Default, Replace, Complete)
		Parent.setCursorPos(1, 2)
		Parent.blit(Fit(" " .. Label, #Label + 2), string.rep("f", #Label + 2), string.rep("4", #Label + 2))
		local Value = ReadAt(#Label + 3, 2, Width - #Label - 2, Default, Replace, colours.black, colours.white, nil, Complete)
		DrawChrome()
		return Value
	end

	local function EditAddress()
		local Value = ReadAt(8, 2, Width - 9, Current.Url or "", nil, colours.black, colours.white, AddressHistory)
		if (Value and Value ~= "" and Value ~= Current.Url) then
			AddressHistory[#AddressHistory + 1] = Value
			-- Typed addresses are absolute: "example.com" means ccmd://example.com.
			local Parsed = Protocol.ParseUrl(Value)
			if (Parsed) then Navigate(Protocol.FormatUrl(Parsed)) end
		else
			Draw()
		end
	end

	local Submit

	local function NextInput(Input)
		local Found = false
		for _, Other in ipairs(Current.Doc.Inputs) do
			if (Found and Other.Form == Input.Form and (Other.Kind == "text" or Other.Kind == "password")) then return Other end
			if (Other == Input) then Found = true end
		end
		return nil
	end

	local function EditInput(Input)
		if (Input.Kind == "file") then
			local Complete = fs.complete and function(Text) return fs.complete(Text, shell and shell.dir() or "", true, true) end or nil
			local Path = Prompt("Upload:", "", nil, Complete)
			if (Path and Path ~= "") then
				if (shell and shell.resolve) then Path = shell.resolve(Path) end
				local Files, Total, Count = ReadLocal(Path)
				if (not Files) then
					SetStatus(Total, "e")
				elseif (Total > Browser.MaxUpload) then
					SetStatus("Too big: " .. math.ceil(Total / 1000) .. " KB", "e")
				else
					Current.State[Input.Id] = Files
					SetStatus(Count .. " file(s) ready", "5")
				end
			end
			Rebuild()
			Draw()
			return
		end
		local Region = Layout.InputRegion(Current.Page, Input.Id)
		if (not Region) then return end
		Current.Scroll = Layout.ScrollTo(Current.Page, Region.Y, Current.Scroll)
		Current.Focus = Input.Id
		Rebuild()
		Draw()
		Region = Layout.InputRegion(Current.Page, Input.Id)
		local X, Y = Layout.RegionPosition(Current.Page, Region, Current.Scroll)
		local Value = Current.State[Input.Id]
		if (Value == nil) then Value = Input.Value or "" end
		local Result = ReadAt(X, Y + 2, Region.X2 - Region.X1 + 1, Value, Input.Kind == "password" and "*" or nil, colours.black, colours.white)
		Current.Focus = nil
		if (Result ~= nil) then Current.State[Input.Id] = Result end
		Rebuild()
		Draw()
		if (not Running or Result == nil) then return end
		local Next = NextInput(Input)
		if (Next) then
			EditInput(Next)
		elseif (Input.Form) then
			Submit(Input.Form, nil)
		end
	end

	Submit = function(FormIndex, Button)
		local Form = Current.Doc.Forms[FormIndex]
		if (not Form) then return end
		local Fields = Ccmd.FormFields(Current.Doc, FormIndex, Current.State, Button)
		local Action = Form.Action or Current.Url
		if (Form.Method == "GET") then
			local Parsed = Protocol.ParseUrl(Action, Current.Parsed)
			if (not Parsed) then return end
			Parsed.Query = Protocol.EncodeQuery(Fields)
			Navigate(Protocol.FormatUrl(Parsed))
		else
			Navigate(Action, "POST", Fields)
		end
	end

	local function Activate(Region)
		if (Region.Kind == "link") then
			Navigate(Region.Href)
		elseif (Region.Kind == "button") then
			if (Region.Button.Href) then
				Navigate(Region.Button.Href)
			elseif (Region.Button.Form) then
				Submit(Region.Button.Form, Region.Button)
			end
		elseif (Region.Kind == "input") then
			EditInput(Region.Input)
		end
	end

	local function SaveCurrent()
		local Body = Current.Response and Current.Response.Body
		if (type(Body) ~= "string") then
			SetStatus("Nothing to save", "e")
			return
		end
		local Default = Current.Parsed and Current.Parsed.Path:match("[^/]+$") or "page.ccmd"
		local Path = Prompt("Save as:", Default)
		if (not Path or Path == "") then return Draw() end
		if (shell and shell.resolve) then Path = shell.resolve(Path) end
		local Handle = fs.open(Path, "wb")
		if (not Handle) then
			SetStatus("Cannot write " .. Path, "e")
			return
		end
		Handle.write(Body)
		Handle.close()
		SetStatus("Saved", "5")
	end

	local function Quit()
		Running = false
	end

	------------------------------------------------------------------
	-- Menu
	------------------------------------------------------------------

	local function Menu()
		local Items = {
			{ "Home", function() Navigate(Setting("ccinternet.home", "domain://")) end },
			{ "Set as home", function()
				if (Current.Url) then SaveSetting("ccinternet.home", Current.Url) SetStatus("Home set", "5") end
			end },
			{ "Save to file", SaveCurrent },
			{ "Quit", Quit }
		}
		if (not Transport.Local) then
			table.insert(Items, 3, { "Server: " .. (Transport.Hostname or "?"), function()
				local Name = Prompt("Server:", Transport.Hostname)
				if (Name and Name ~= "") then
					SaveSetting("ccinternet.host", Name)
					Transport = Protocol.NetworkTransport(Name)
					SetStatus("Server set", "5")
				end
				Draw()
			end })
		end
		local MenuWidth = 2
		for _, Item in ipairs(Items) do MenuWidth = math.max(MenuWidth, #Item[1] + 2) end
		local X = Width - MenuWidth + 1
		for Index, Item in ipairs(Items) do
			Parent.setCursorPos(X, 2 + Index)
			Parent.blit(Fit(" " .. Item[1], MenuWidth), string.rep("f", MenuWidth), string.rep("8", MenuWidth))
		end
		while (true) do
			local Event, A, B, C = os.pullEventRaw()
			if (Event == "terminate") then return Quit() end
			if (Event == "mouse_click") then
				local Index = C - 2
				if (B >= X and Items[Index]) then
					Draw()
					return Items[Index][2]()
				end
				return Draw()
			elseif (Event == "key") then
				if (A == keys.enter or A == keys.backspace or A == keys.tab) then return Draw() end
			end
		end
	end

	------------------------------------------------------------------
	-- Main loop
	------------------------------------------------------------------

	local function Scroll(By)
		if (not Current.Page) then return end
		local Value = math.max(0, math.min(Current.Page.MaxScroll, Current.Scroll + By))
		if (Value ~= Current.Scroll) then
			Current.Scroll = Value
			Draw()
		end
	end

	local function Select(Step)
		local Regions = Current.Page and Current.Page.Regions
		if (not Regions or #Regions == 0) then return end
		local Index = (Current.Selected or (Step > 0 and 0 or 1)) + Step
		if (Index < 1) then Index = #Regions end
		if (Index > #Regions) then Index = 1 end
		Current.Selected = Index
		Current.Scroll = Layout.ScrollTo(Current.Page, Regions[Index].Y, Current.Scroll)
		Draw()
	end

	local function Resize()
		Width, Height = Parent.getSize()
		PageWindow.reposition(1, 3, Width, math.max(1, Height - 2))
		Rebuild()
		Draw()
	end

	Parent.setBackgroundColour(colours.black)
	Parent.clear()
	if (not Colour) then
		Current.Status = "Use an Advanced Computer for colour"
	end
	Navigate(Options.Url or Setting("ccinternet.home", "domain://"))

	while (Running) do
		local Event, A, B, C = os.pullEventRaw()
		if (Event == "terminate") then
			Quit()
		elseif (Event == "mouse_click") then
			local X, Y = B, C
			if (Y == 1 and X >= Width - 1) then
				Quit()
			elseif (Y == 2) then
				if (X == 2) then GoHistory(HistoryIndex - 1)
				elseif (X == 4) then GoHistory(HistoryIndex + 1)
				elseif (X == 6) then Reload()
				elseif (X >= Width - 1) then Menu()
				elseif (X >= 8) then EditAddress() end
			elseif (Y >= 3 and Current.Page) then
				local Region = Layout.Hit(Current.Page, X, Y - 2, Current.Scroll)
				if (Region) then Activate(Region) end
			end
		elseif (Event == "mouse_scroll") then
			Scroll(A * 2)
		elseif (Event == "key") then
			if (A == keys.leftCtrl or A == keys.rightCtrl) then
				Ctrl = true
			elseif (Ctrl and A == keys.l) then
				Ctrl = false
				EditAddress()
			elseif (Ctrl and A == keys.r) then
				Reload()
			elseif (Ctrl and A == keys.s) then
				Ctrl = false
				SaveCurrent()
			elseif (Ctrl and A == keys.q) then
				Quit()
			elseif (A == keys.up) then Scroll(-1)
			elseif (A == keys.down) then Scroll(1)
			elseif (A == keys.pageUp) then Scroll(1 - select(2, PageWindow.getSize()))
			elseif (A == keys.pageDown) then Scroll(select(2, PageWindow.getSize()) - 1)
			elseif (A == keys.home) then Scroll(-math.huge)
			elseif (A == keys["end"]) then Scroll(math.huge)
			elseif (A == keys.tab) then Select(1)
			elseif (A == keys.enter and Current.Selected and Current.Page) then
				local Region = Current.Page.Regions[Current.Selected]
				if (Region) then Activate(Region) end
			elseif (A == keys.backspace) then GoHistory(HistoryIndex - 1)
			end
		elseif (Event == "key_up") then
			if (A == keys.leftCtrl or A == keys.rightCtrl) then Ctrl = false end
		elseif (Event == "term_resize") then
			Resize()
		end
	end

	SetTitle(OldTitle)
	Parent.setBackgroundColour(colours.black)
	Parent.setTextColour(colours.white)
	Parent.setCursorBlink(false)
	if (not Options.Embedded) then
		Parent.clear()
		Parent.setCursorPos(1, 1)
	end
end

return Browser
