-- The admin screen of the core: onboarding, lock screen and the tabs to look after the cluster.

local Protocol = require("lib.protocol")
local UI = require("server.ui")
local Config = require("server.config")
local Auth = require("server.auth")
local Storage = require("server.storage")
local Transfer = require("server.transfer")
local Network = require("server.network")
local Router = require("server.router")
local Log = require("server.log")

local Admin = {}

local State = {
	Tab = "domains",
	Detail = nil,
	Scroll = { domains = 0, drives = 0, log = 0, detail = 0 },
	Filter = "",
	LastInput = os.clock(),
	Stop = false,
	Started = os.clock()
}

local Shell = nil

local Tabs = {
	{ Id = "domains", Label = "Domains" },
	{ Id = "drives", Label = "Drives" },
	{ Id = "transfer", Label = "Transfer" },
	{ Id = "log", Label = "Log" },
	{ Id = "settings", Label = "Settings" }
}

local StateColours = { domain = "5", blank = "0", empty = "7", nodata = "7", foreign = "1", duplicate = "e" }
local StateNames = { domain = "domain", blank = "blank", empty = "no disk", nodata = "no data", foreign = "other files", duplicate = "duplicate" }

function Admin.Init(Options)
	Shell = Options and Options.Shell
end

------------------------------------------------------------------------
-- Shared pieces
------------------------------------------------------------------------

function Admin.Browse(Url)
	local Browser = require("lib.browser")
	Browser.Run({ Url = Url, Transport = Router.LocalTransport(), Embedded = true })
	State.LastInput = os.clock()
end

local function Edit(Path)
	if (Shell) then
		Shell.run("edit", Path)
	elseif (shell) then
		shell.run("edit", Path)
	else
		UI.Alert("Edit", "The edit program is not available here.")
	end
	State.LastInput = os.clock()
end

local function DrawBar(X, Y, Width, Used, Capacity)
	local Filled = Capacity > 0 and math.floor(Used / Capacity * Width + 0.5) or 0
	Filled = math.max(0, math.min(Width, Filled))
	local Ratio = Used / math.max(1, Capacity)
	local Colour = Ratio > 0.9 and "e" or (Ratio > 0.7 and "4" or "5")
	term.setCursorPos(X, Y)
	term.blit(string.rep(" ", Width), string.rep("0", Width), string.rep(Colour, Filled) .. string.rep("7", Width - Filled))
end

local function Header()
	local W = UI.Size()
	UI.Fill(1, 1, W, 1, "b")
	local Clock = textutils.formatTime(os.time(), true)
	local Status = Network.Hosted and "\7 online" or ("\7 " .. (Network.Problem or "offline"))
	local Right = Status .. "  " .. Clock .. " "
	local Name = UI.Fit(Config.Values.Hostname, math.max(4, W - #Right - 20))
	Name = Name:gsub("%s+$", "")
	UI.Text(2, 1, Name, "4", "b")
	UI.Text(3 + #Name, 1, "ccinternet core", "3", "b")
	UI.Text(W - #Right + 1, 1, Status, Network.Hosted and "5" or "e", "b")
	UI.Text(W - #Clock, 1, Clock, "0", "b")

	UI.Fill(1, 2, W, 1, "7")
	local X = 1
	for _, Tab in ipairs(Tabs) do
		local Label = " " .. Tab.Label .. (Tab == Tabs[#Tabs] and " " or "")
		local Active = State.Tab == Tab.Id
		UI.Text(X, 2, Label, Active and "4" or "0", Active and "f" or "7")
		UI.Region(X, 2, X + #Label - 1, function()
			State.Tab = Tab.Id
			State.Detail = nil
		end)
		X = X + #Label
	end
	local Lock = " Lock "
	local Web = " Web "
	UI.Button(W - #Lock + 1, 2, "Lock", "0", "e", function() Admin.Lock() end)
	UI.Button(W - #Lock - #Web, 2, "Web", "0", "d", function() Admin.Browse("domain://") end)
end

local function Footer(Text, Fg)
	local W, H = UI.Size()
	UI.Fill(1, H, W, 1, "7")
	UI.Text(2, H, UI.Fit(Text, W - 2), Fg or "0", "7")
end

local function ListScroll(Key, Count, Visible)
	State.Scroll[Key] = math.max(0, math.min(math.max(0, Count - Visible), State.Scroll[Key] or 0))
	return State.Scroll[Key]
end

------------------------------------------------------------------------
-- Domains
------------------------------------------------------------------------

local function FilteredDomains()
	local List = {}
	for _, Name in ipairs(Storage.DomainList()) do
		if (State.Filter == "" or Name:find(State.Filter, 1, true)) then List[#List + 1] = Name end
	end
	return List
end

local function DomainsView(W, H)
	local List = FilteredDomains()
	local Top, Visible = 4, H - 4
	local Scroll = ListScroll("domains", #List, Visible)
	local NameW = W - 31
	UI.Fill(1, 3, W, 1, "8")
	UI.Text(2, 3, UI.Fit("Domain", NameW) .. " " .. UI.Fit("Drive", 10) .. " " .. UI.Fit("Used", 9) .. " Status", "f", "8")
	UI.Fill(1, Top, W, Visible, "f")
	for Row = 1, Visible do
		local Name = List[Scroll + Row]
		if (not Name) then break end
		local Entry = Storage.Domains[Name]
		local Used = Storage.Usage(Entry)
		local Y = Top + Row - 1
		local Suspended = Entry.Meta.Suspended
		UI.Text(2, Y, UI.Fit(Name, NameW), Suspended and "7" or "0", "f")
		UI.Text(3 + NameW, Y, UI.Fit(Entry.Name, 10), "8", "f")
		UI.Text(14 + NameW, Y, UI.Fit(Storage.FormatSize(Used), 9), "8", "f")
		UI.Text(24 + NameW, Y, Suspended and "suspended" or "active", Suspended and "e" or "5", "f")
		UI.Region(1, Y, W, function()
			State.Detail = Name
			State.Scroll.detail = 0
		end, function() Admin.Browse("ccmd://" .. Name .. "/") end)
	end
	if (#List == 0) then
		UI.Text(2, Top + 1, State.Filter ~= "" and "No domain matches \"" .. State.Filter .. "\"" or "No domains yet. People register at domain://", "7", "f")
	end
	local Counts = Storage.Counts()
	local Text = #List .. " domains, " .. Counts.Blank .. " blank floppies"
	if (State.Filter ~= "") then
		Text = "Filter: " .. State.Filter .. "_   (" .. #List .. " shown)"
	else
		Text = Text .. "   type to filter, right-click to open"
	end
	Footer(Text)
end

local function DomainDetail(W, H)
	local Entry = Storage.Get(State.Detail)
	if (not Entry) then
		State.Detail = nil
		return DomainsView(W, H)
	end
	local Domain = Entry.Domain
	local Meta = Entry.Meta
	UI.Fill(1, 3, W, 5, "f")
	UI.Button(1, 3, "< Back", "0", "7", function() State.Detail = nil end)
	UI.Text(10, 3, UI.Fit(Domain, W - 10), "4", "f")
	UI.Text(2, 4, UI.Fit("Drive " .. Entry.Name .. "  disk #" .. tostring(Entry.DiskId) .. "  " .. Entry.Mount, W - 2), "8", "f")
	local Used, Capacity = Storage.Usage(Entry)
	UI.Text(2, 5, "Storage", "8", "f")
	DrawBar(10, 5, 16, Used, Capacity)
	UI.Text(27, 5, Storage.FormatSize(Used) .. " / " .. Storage.FormatSize(Capacity), "0", "f")
	local Created = Meta.Created and Meta.Created > 0 and os.date("%Y-%m-%d", math.floor(Meta.Created / 1000)) or "?"
	UI.Text(2, 6, "Created " .. Created .. "   ", "8", "f")
	UI.Text(22, 6, Meta.Suspended and "suspended" or "active", Meta.Suspended and "e" or "5", "f")

	local X = 2
	X = X + UI.Button(X, 7, "Open", "0", "d", function() Admin.Browse("ccmd://" .. Domain .. "/") end) + 1
	X = X + UI.Button(X, 7, Meta.Suspended and "Resume" or "Suspend", "0", "1", function()
		Storage.SetSuspended(Entry, not Meta.Suspended)
		Log.Event((Meta.Suspended and "Suspended " or "Resumed ") .. Domain)
	end) + 1
	X = X + UI.Button(X, 7, "Password", "0", "b", function()
		local New = UI.Prompt("New password", "Set a new owner password for " .. Domain .. ".", nil, "*")
		if (not New) then return end
		if (#New < 4) then return UI.Alert("Password", "Passwords need at least 4 characters.", "e") end
		local Again = UI.Prompt("New password", "Type it again.", nil, "*")
		if (Again ~= New) then return UI.Alert("Password", "The passwords do not match.", "e") end
		local Salt = Auth.Salt()
		Storage.SetPassword(Entry, Salt, Auth.Hash(New, Salt))
		Auth.EndDomainSessions(Domain)
		Log.Event("Reset the password of " .. Domain)
		UI.Alert("Password", "The password of " .. Domain .. " was changed.")
	end) + 1
	X = X + UI.Button(X, 7, "Export", "0", "9", function() Admin.Export(Domain) end) + 1
	UI.Button(X, 7, "Delete", "0", "e", function()
		if (UI.Confirm("Delete " .. Domain, "Delete " .. Domain .. " and every file on its floppy? The floppy becomes blank and the name becomes free.", "Delete", true)) then
			Auth.EndDomainSessions(Domain)
			Storage.Release(Entry)
			Log.Event("Deleted " .. Domain)
			State.Detail = nil
		end
	end)

	local Files = Storage.Files(Entry)
	local _, PageList = Storage.Routes(Entry)
	local Locations = {}
	for _, Info in ipairs(PageList) do Locations[Info.Path] = Info.Location or (Info.Error and "!" .. Info.Error) end
	local Top, Visible = 9, H - 9
	local Scroll = ListScroll("detail", #Files, Visible)
	local PathW = W - 24
	UI.Fill(1, 8, W, 1, "8")
	UI.Text(2, 8, UI.Fit("File", PathW) .. " " .. UI.Fit("Size", 9) .. " Location", "f", "8")
	UI.Fill(1, Top, W, Visible, "f")
	for Row = 1, Visible do
		local File = Files[Scroll + Row]
		if (not File) then break end
		local Y = Top + Row - 1
		local Location = Locations[File.Path] or ""
		UI.Text(2, Y, UI.Fit(File.Path, PathW), "0", "f")
		UI.Text(3 + PathW, Y, UI.Fit(Storage.FormatSize(File.Size), 9), "8", "f")
		UI.Text(13 + PathW, Y, UI.Fit(Location, W - 13 - PathW), Location:sub(1, 1) == "!" and "e" or "3", "f")
		UI.Region(1, Y, W, function() Admin.Browse("ccmd://" .. Domain .. File.Path) end, function()
			Edit(Storage.SitePath(Entry, File.Path))
			Storage.Invalidate(Entry)
		end)
	end
	if (#Files == 0) then UI.Text(2, Top, "This site has no files.", "7", "f") end
	Footer(#Files .. " files   click: view in browser   right-click: edit")
end

------------------------------------------------------------------------
-- Drives
------------------------------------------------------------------------

local function DrivesView(W, H)
	local Drives = Storage.Drives
	local Top, Visible = 4, H - 4
	local Scroll = ListScroll("drives", #Drives, Visible)
	UI.Fill(1, 3, W, 1, "8")
	UI.Text(2, 3, UI.Fit("Drive", 12) .. " " .. UI.Fit("Disk", 6) .. " " .. UI.Fit("State", 12) .. " Contents", "f", "8")
	UI.Fill(1, Top, W, Visible, "f")
	for Row = 1, Visible do
		local Entry = Drives[Scroll + Row]
		if (not Entry) then break end
		local Y = Top + Row - 1
		UI.Text(2, Y, UI.Fit(Entry.Name, 12), "0", "f")
		UI.Text(15, Y, UI.Fit(Entry.DiskId and ("#" .. Entry.DiskId) or "", 6), "8", "f")
		UI.Text(22, Y, UI.Fit(StateNames[Entry.State] or Entry.State, 12), StateColours[Entry.State] or "0", "f")
		UI.Text(35, Y, UI.Fit(Entry.Domain or Entry.Label or "", W - 35), "8", "f")
		UI.Region(1, Y, W, function()
			if (Entry.State == "domain") then
				State.Tab = "domains"
				State.Detail = Entry.Domain
			elseif (Entry.State == "foreign" or Entry.State == "duplicate") then
				if (UI.Confirm("Wipe floppy", "Erase every file on the floppy in " .. Entry.Name .. " so it can hold a new domain?", "Wipe", true)) then
					Storage.Wipe(Entry.Mount)
					pcall(disk.setLabel, Entry.Name, nil)
					Log.Event("Wiped the floppy in " .. Entry.Name)
					Storage.Scan()
				end
			elseif (Entry.State == "blank") then
				UI.Alert(Entry.Name, "This blank floppy is ready for the next domain registered at domain://.")
			else
				UI.Alert(Entry.Name, "Insert a blank floppy disk into this drive so it can hold a domain.")
			end
		end)
	end
	if (#Drives == 0) then
		UI.Text(2, Top + 1, "No disk drives found. Connect drives to the core", "7", "f")
		UI.Text(2, Top + 2, "with wired modems and cables (right-click a modem", "7", "f")
		UI.Text(2, Top + 3, "to attach its drive).", "7", "f")
	end
	local Counts = Storage.Counts()
	Footer(Counts.Drives .. " drives: " .. Counts.Domains .. " used, " .. Counts.Blank .. " blank, " .. Counts.Empty .. " empty")
	UI.Button(W - 8, H, "Rescan", "0", "b", function() Storage.Scan() end)
end

------------------------------------------------------------------------
-- Transfer
------------------------------------------------------------------------

function Admin.Export(Domain)
	local Ok, Problem, Need = Transfer.Export(Domain, false)
	if (not Ok and Need == "confirm") then
		if (not UI.Confirm("Overwrite floppy", "The transfer floppy is not empty. Erase it and copy " .. Domain .. " onto it?", "Overwrite", true)) then return end
		Ok, Problem = Transfer.Export(Domain, true)
	end
	if (Ok) then
		Log.Event("Exported " .. Domain .. " to the transfer floppy")
		UI.Alert("Exported", Domain .. " and all its files were copied to the floppy in the " .. Transfer.Side() .. " drive.")
	else
		UI.Alert("Export failed", Problem, "e")
	end
end

local function ImportDomain()
	local Ok, Result, Need = Transfer.Import(false)
	if (not Ok and Need == "confirm") then
		if (not UI.Confirm("Replace domain", Result .. ". Replace it with the copy on the floppy?", "Replace", true)) then return end
		Ok, Result = Transfer.Import(true)
	end
	if (Ok) then
		Log.Event("Imported " .. Result .. " from the transfer floppy")
		UI.Alert("Imported", Result .. " is now served by this cluster.")
	else
		UI.Alert("Import failed", Result, "e")
	end
end

local function ImportSite()
	local Domain = UI.Prompt("New domain", "Domain name for the website files on the floppy:")
	if (not Domain) then return end
	Domain = Domain:lower()
	local Valid, Problem = Storage.ValidDomain(Domain)
	if (not Valid) then return UI.Alert("Import", Problem, "e") end
	if (Storage.Get(Domain)) then return UI.Alert("Import", Domain .. " is already taken.", "e") end
	local Password = UI.Prompt("Owner password", "Password the owner will use at domain:// (at least 4 characters):", nil, "*")
	if (not Password or #Password < 4) then return UI.Alert("Import", "Passwords need at least 4 characters.", "e") end
	local Salt = Auth.Salt()
	local Ok, Result = Transfer.ImportSite(Domain, Salt, Auth.Hash(Password, Salt))
	if (Ok) then
		Log.Event("Imported website files as " .. Domain)
		UI.Alert("Imported", "The files are now served at ccmd://" .. Domain .. "/")
	else
		UI.Alert("Import failed", Result, "e")
	end
end

local function TransferView(W, H)
	local Status = Transfer.Status()
	UI.Fill(1, 3, W, H - 3, "f")
	UI.Text(2, 4, "Transfer drive (" .. Status.Side .. " side)", "4", "f")
	local Lines = {}
	local Colour = "0"
	if (Status.State == "missing") then
		Lines = { "No disk drive is placed on the " .. Status.Side .. " side of the core.", "Place one there to copy domains to and from floppies." }
		Colour = "e"
	elseif (Status.State == "none") then
		Lines = { "Insert a floppy disk into the transfer drive." }
		Colour = "8"
	elseif (Status.State == "nodata") then
		Lines = { "This disk cannot hold files (is it a music disc?)." }
		Colour = "e"
	elseif (Status.State == "blank") then
		Lines = { "A blank floppy: export a domain onto it." }
	elseif (Status.State == "domain") then
		Lines = { "Holds the exported domain " .. Status.Domain .. " (" .. Storage.FormatSize(Status.Used or 0) .. ").",
			Storage.Get(Status.Domain) and "The cluster already has a domain with this name." or "This domain is not in the cluster yet." }
	elseif (Status.State == "site") then
		Lines = { "Holds website files (" .. Storage.FormatSize(Status.Used or 0) .. ") but no domain.", "Import them as a new domain." }
	else
		Lines = { "Holds other files (" .. Storage.FormatSize(Status.Used or 0) .. ")." }
		Colour = "1"
	end
	for Index, Line in ipairs(Lines) do UI.Text(2, 5 + Index, UI.Fit(Line, W - 2), Colour, "f") end
	if (Status.Label) then UI.Text(2, 6 + #Lines + 1, "Label: " .. Status.Label, "8", "f") end

	local Y = 11
	local X = 2
	local function Add(Label, Bg, Action)
		local Width = #Label + 2
		if (X + Width > W) then
			X = 2
			Y = Y + 2
		end
		UI.Button(X, Y, Label, "0", Bg, Action)
		X = X + Width + 1
	end
	if (Status.Mount) then
		Add("Export a domain", "9", function()
			local Domain = UI.Pick("Export which domain?", Storage.DomainList())
			if (Domain) then Admin.Export(Domain) end
		end)
	end
	if (Status.State == "domain") then Add("Import " .. Status.Domain, "d", ImportDomain) end
	if (Status.State == "site" or Status.State == "foreign") then Add("Import as new domain", "d", ImportSite) end
	if (Status.Mount and Status.State ~= "blank") then
		Add("Wipe", "e", function()
			if (UI.Confirm("Wipe floppy", "Erase every file on the transfer floppy?", "Wipe", true)) then
				Transfer.Wipe()
				Log.Event("Wiped the transfer floppy")
			end
		end)
	end
	if (Status.State ~= "missing" and Status.State ~= "none") then
		Add("Eject", "7", function() pcall(disk.eject, Status.Side) end)
	end
	Footer("Exports copy the whole domain; imports bring it back")
end

------------------------------------------------------------------------
-- Log
------------------------------------------------------------------------

local function LogView(W, H)
	local Entries = Log.Entries
	local Top, Visible = 3, H - 3
	local Scroll = ListScroll("log", #Entries, Visible)
	UI.Fill(1, Top, W, Visible, "f")
	for Row = 1, Visible do
		local Entry = Entries[Scroll + Row]
		if (not Entry) then break end
		local Y = Top + Row - 1
		UI.Text(1, Y, Entry.Time, "7", "f")
		if (Entry.Event) then
			UI.Text(10, Y, UI.Fit("* " .. Entry.Event, W - 9), "4", "f")
		else
			local Status = tostring(Entry.Status)
			local Colour = Entry.Status >= 500 and "e" or (Entry.Status >= 400 and "1" or (Entry.Status >= 300 and "3" or "5"))
			UI.Text(10, Y, UI.Fit("#" .. tostring(Entry.Sender), 6), "8", "f")
			UI.Text(17, Y, UI.Fit(Entry.Method, 4), "0", "f")
			UI.Text(22, Y, UI.Fit(Entry.Url, W - 26), "0", "f")
			UI.Text(W - 3, Y, Status, Colour, "f")
		end
	end
	if (#Entries == 0) then UI.Text(2, Top + 1, "No requests yet.", "7", "f") end
	Footer(Log.Stats.Requests .. " requests, " .. Log.Stats.Errors .. " errors since start")
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

local function ChangeAdminPassword()
	local Old = UI.Prompt("Admin password", "Current admin password:", nil, "*")
	if (not Old) then return end
	if (not Auth.Check(Old, Config.Values.AdminSalt, Config.Values.AdminHash)) then return UI.Alert("Admin password", "That is not the current password.", "e") end
	local New = UI.Prompt("Admin password", "New admin password (at least 4 characters):", nil, "*")
	if (not New or #New < 4) then return UI.Alert("Admin password", "Passwords need at least 4 characters.", "e") end
	if (UI.Prompt("Admin password", "Type it again:", nil, "*") ~= New) then return UI.Alert("Admin password", "The passwords do not match.", "e") end
	local Salt = Auth.Salt()
	Config.Values.AdminSalt = Salt
	Config.Values.AdminHash = Auth.Hash(New, Salt)
	Config.Save()
	Log.Event("Changed the admin password")
	UI.Alert("Admin password", "Changed.")
end

local function Rename()
	local Name = UI.Prompt("Rename server", "Browsers find this core by its name. They look for \"" .. Protocol.DefaultHost .. "\" unless set otherwise in their menu.", Config.Values.Hostname)
	if (not Name) then return end
	Name = Name:gsub("^%s+", ""):gsub("%s+$", "")
	if (Name == "" or Name == Config.Values.Hostname) then return end
	local Ok, Problem = Network.Rename(Name)
	if (not Ok and Problem and Problem:match("Another")) then
		Network.Start(Config.Values.Hostname)
		return UI.Alert("Rename", Problem, "e")
	end
	local Old = Config.Values.Hostname
	Config.Set("Hostname", Name)
	Log.Event("Renamed the server from " .. Old .. " to " .. Name)
	if (not Ok) then UI.Alert("Rename", "Saved, but the server is offline: " .. tostring(Problem), "1") end
end

local function SettingsView(W, H)
	UI.Fill(1, 3, W, H - 3, "f")
	local Rows = {
		{ "Server name", Config.Values.Hostname, "Rename", Rename },
		{ "Admin password", "********", "Change", ChangeAdminPassword },
		{ "Auto-lock", Config.Values.AutoLock == 0 and "never" or (Config.Values.AutoLock .. " min"), "Change", function()
			local Value = tonumber(UI.Prompt("Auto-lock", "Minutes without input before the screen locks (0 = never):", tostring(Config.Values.AutoLock)) or "")
			if (Value and Value >= 0) then Config.Set("AutoLock", math.floor(Value)) end
		end },
		{ "Registration", Config.Values.Registration and "open" or "closed", "Toggle", function()
			Config.Set("Registration", not Config.Values.Registration)
			Log.Event("Registration " .. (Config.Values.Registration and "opened" or "closed"))
		end },
		{ "Public directory", Config.Values.PublicDirectory and "on" or "off", "Toggle", function()
			Config.Set("PublicDirectory", not Config.Values.PublicDirectory)
		end },
		{ "Transfer drive", Config.Values.TransferSide, "Change", function()
			local Side = UI.Pick("Transfer drive side", { "left", "right", "top", "bottom", "front", "back" })
			if (Side) then
				Config.Set("TransferSide", Side)
				Storage.TransferSide = Side
				Storage.Scan()
			end
		end },
		{ "Network", Network.Hosted and (Network.Modems .. " modem(s), hosted") or (Network.Problem or "offline"), "Reconnect", function()
			Network.Start(Config.Values.Hostname)
		end }
	}
	for Index, Row in ipairs(Rows) do
		local Y = 3 + Index * 2 - 1
		UI.Text(2, Y, UI.Fit(Row[1], 18), "8", "f")
		UI.Text(20, Y, UI.Fit(Row[2], W - 33), "0", "f")
		UI.Button(W - #Row[3] - 2, Y, Row[3], "0", "7", Row[4])
	end
	local Uptime = math.floor((os.clock() - State.Started) / 60)
	Footer("Computer #" .. os.getComputerID() .. "   up " .. Uptime .. " min   " .. Log.Stats.Requests .. " requests")
	UI.Button(W - 13, H, "Stop server", "0", "e", function()
		if (UI.Confirm("Stop server", "Stop serving websites and return to the shell?", "Stop", true)) then State.Stop = true end
	end)
end

------------------------------------------------------------------------
-- Onboarding and lock screen
------------------------------------------------------------------------

local function Backdrop(Subtitle)
	local W, H = UI.Size()
	UI.Fill(1, 1, W, H, "f")
	UI.Text(math.floor((W - 10) / 2) + 1, 2, "ccinternet", "4", "f")
	if (Subtitle) then UI.Text(math.floor((W - #Subtitle) / 2) + 1, 3, Subtitle, "8", "f") end
end

function Admin.Onboard()
	Backdrop("Core setup")
	UI.Alert("Welcome", "This computer will become an internet core. It serves websites stored on floppy disks in the drives connected to it, and browsers on other computers find it by its name.")

	local Name
	while (not Name) do
		Backdrop("Core setup  1/2")
		Name = UI.Prompt("Server name", "Browsers look for \"" .. Protocol.DefaultHost .. "\" by default. Keep it unless you are starting a separate internet.", Protocol.DefaultHost)
		if (Name) then
			Name = Name:gsub("^%s+", ""):gsub("%s+$", "")
			if (Name == "") then
				Name = nil
			elseif (Network.InUse(Name)) then
				Backdrop("Core setup  1/2")
				UI.Alert("Name taken", "Another computer already answers to \"" .. Name .. "\". Pick a different name.", "e")
				Name = nil
			end
		end
	end

	local Password
	while (not Password) do
		Backdrop("Core setup  2/2")
		local First = UI.Prompt("Admin password", "This password unlocks this screen. Use at least 4 characters.", nil, "*")
		if (First and #First >= 4) then
			Backdrop("Core setup  2/2")
			local Second = UI.Prompt("Admin password", "Type it again.", nil, "*")
			if (Second == First) then
				Password = First
			else
				Backdrop("Core setup  2/2")
				UI.Alert("Admin password", "The passwords do not match.", "e")
			end
		elseif (First) then
			Backdrop("Core setup  2/2")
			UI.Alert("Admin password", "Use at least 4 characters.", "e")
		end
	end

	local Salt = Auth.Salt()
	Config.Values.Hostname = Name
	Config.Values.AdminSalt = Salt
	Config.Values.AdminHash = Auth.Hash(Password, Salt)
	Config.Save()
	-- A floppy in a drive next to the core must never be able to replace the server at boot.
	if (settings) then
		settings.set("shell.allow_disk_startup", false)
		settings.save()
	end
	if (not os.getComputerLabel()) then os.setComputerLabel(Name) end

	Storage.Scan()
	local Counts = Storage.Counts()
	local Transferring = Storage.IsDrive(Storage.TransferSide) and "found" or "missing (place a disk drive on the left)"
	local Modems = Protocol.OpenModems()
	Backdrop("Ready")
	UI.Alert("All set", "Server name: " .. Name .. "\nDisk drives: " .. Counts.Drives .. " (" .. Counts.Blank .. " blank floppies)\nTransfer drive: " .. Transferring .. "\nModems: " .. Modems .. (Modems == 0 and " (attach a wireless or ender modem)" or ""))
	Log.Event("Set up as " .. Name)
	State.LastInput = os.clock()
end

function Admin.Lock()
	local Message, Colour = "Locked", "8"
	while (true) do
		local W, H = UI.Size()
		Backdrop(Config.Values.Hostname)
		local Counts = Storage.Counts()
		local Info = Counts.Domains .. " domains, " .. Log.Stats.Requests .. " requests served"
		UI.Text(math.floor((W - #Info) / 2) + 1, 5, Info, "7", "f")
		local BoxW = 30
		local X = math.floor((W - BoxW) / 2) + 1
		local Y = math.floor(H / 2)
		UI.Fill(X, Y, BoxW, 4, "7")
		UI.Text(X + 2, Y, UI.Fit(Message, BoxW - 4), Colour, "7")
		UI.Text(X + 2, Y + 1, "Admin password:", "0", "7")
		local Password = UI.Read(X + 2, Y + 2, BoxW - 4, nil, "*")
		if (Password and Auth.Check(Password, Config.Values.AdminSalt, Config.Values.AdminHash)) then
			State.LastInput = os.clock()
			return
		end
		if (Password and Password ~= "") then
			Message, Colour = "Wrong password", "e"
			Log.Event("Wrong admin password entered")
		end
	end
end

------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------

local function Draw()
	local W, H = UI.Size()
	UI.Begin()
	term.setCursorBlink(false)
	Header()
	if (State.Tab == "domains") then
		if (State.Detail) then DomainDetail(W, H) else DomainsView(W, H) end
	elseif (State.Tab == "drives") then DrivesView(W, H)
	elseif (State.Tab == "transfer") then TransferView(W, H)
	elseif (State.Tab == "log") then LogView(W, H)
	elseif (State.Tab == "settings") then SettingsView(W, H)
	end
end

local function ScrollKey()
	if (State.Tab == "domains") then return State.Detail and "detail" or "domains" end
	if (State.Tab == "drives" or State.Tab == "log") then return State.Tab end
	return nil
end

local function ScrollBy(Amount)
	local Key = ScrollKey()
	if (Key) then State.Scroll[Key] = math.max(0, (State.Scroll[Key] or 0) + Amount) end
end

-- Runs the admin screen. Locked tells it to start on the lock screen. Returns when the server is stopped.
function Admin.Run(Locked)
	if (Locked) then Admin.Lock() end
	local Timer = os.startTimer(1)
	while (not State.Stop) do
		Draw()
		local Event, A, B, C = os.pullEventRaw()
		if (Event == "mouse_click") then
			State.LastInput = os.clock()
			UI.Click(A, B, C)
		elseif (Event == "mouse_scroll") then
			State.LastInput = os.clock()
			ScrollBy(A * 2)
		elseif (Event == "key") then
			State.LastInput = os.clock()
			local _, H = UI.Size()
			if (A == keys.up) then ScrollBy(-1)
			elseif (A == keys.down) then ScrollBy(1)
			elseif (A == keys.pageUp) then ScrollBy(-(H - 5))
			elseif (A == keys.pageDown) then ScrollBy(H - 5)
			elseif (A == keys.backspace) then
				if (State.Tab == "domains" and not State.Detail and #State.Filter > 0) then
					State.Filter = State.Filter:sub(1, -2)
					State.Scroll.domains = 0
				elseif (State.Detail) then
					State.Detail = nil
				end
			elseif (A == keys.tab) then
				for Index, Tab in ipairs(Tabs) do
					if (Tab.Id == State.Tab) then
						State.Tab = Tabs[Index % #Tabs + 1].Id
						State.Detail = nil
						break
					end
				end
			end
		elseif (Event == "char") then
			State.LastInput = os.clock()
			if (State.Tab == "domains" and not State.Detail) then
				State.Filter = State.Filter .. A:lower()
				State.Scroll.domains = 0
			end
		elseif (Event == "timer" and A == Timer) then
			Timer = os.startTimer(1)
			local Minutes = Config.Values.AutoLock or 0
			if (Minutes > 0 and os.clock() - State.LastInput > Minutes * 60) then Admin.Lock() end
		end
	end
end

return Admin
