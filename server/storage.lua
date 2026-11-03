-- Cluster storage: one domain per floppy disk, spread over every disk drive on the wired network.
--
-- A domain floppy holds:
--   /ccinternet.meta   owner data (domain name, password hash, created time, suspended flag)
--   /site/...          the public files of the website
--   /forms/...         form submissions sent to the website
--
-- The drive on the search side (right of the core by default) is not part of the cluster. Its
-- floppy is the cc.net disk: it holds /ccinternet.search and the search index (see server/search.lua).

local Ccmd = require("lib.ccmd")
local Protocol = require("lib.protocol")

local Storage = {}

Storage.MetaFile = "ccinternet.meta"
Storage.SearchFile = "ccinternet.search"
Storage.SiteDir = "site"
Storage.FormsDir = "forms"
Storage.FileOverhead = 500      -- CC: Tweaked charges at least this much per file and folder
Storage.DefaultCapacity = 125000
Storage.MaxUploadFiles = 200
Storage.MaxPathLength = 128
Storage.Reserved = { domain = true, localhost = true, ["cc.net"] = true }

Storage.TransferSide = "left"
Storage.SearchSide = "right"
Storage.Drives = {}      -- every cluster drive, in order
Storage.Domains = {}     -- domain name -> drive entry
Storage.SearchDrive = nil -- the drive on the search side (nil when there is none), see Storage.Scan
Storage.Version = 0      -- bumps on every rescan or change, so views can refresh
Storage.Generation = 0   -- bumps on every rescan

local RouteCache = {}
local SiteVersions = {}  -- domain -> number of times its files changed since the last rescan

-- Drops cached routes of a domain and marks its files as changed.
local function Forget(Domain)
	if (not Domain) then return end
	RouteCache[Domain] = nil
	SiteVersions[Domain] = (SiteVersions[Domain] or 0) + 1
end

-- A value that changes whenever the files of a domain may have changed (uploads, deletes, rescans).
function Storage.SiteStamp(Domain)
	return Storage.Generation .. ":" .. (SiteVersions[Domain] or 0)
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function ReadFile(Path)
	if (not fs.exists(Path) or fs.isDir(Path)) then return nil end
	local Handle = fs.open(Path, "rb")
	if (not Handle) then return nil end
	local Data = Handle.readAll() or ""
	Handle.close()
	return Data
end

local function WriteFile(Path, Data)
	local Dir = fs.getDir(Path)
	if (Dir ~= "" and not fs.exists(Dir)) then fs.makeDir(Dir) end
	local Handle, Problem = fs.open(Path, "wb")
	if (not Handle) then return false, Problem or "Cannot write " .. Path end
	local Ok, Error = pcall(Handle.write, Data)
	Handle.close()
	if (not Ok) then return false, Error end
	return true
end

Storage.ReadFile = ReadFile
Storage.WriteFile = WriteFile

local function Cost(Size)
	return math.max(Size or 0, Storage.FileOverhead)
end

local function IsDrive(Name)
	if (peripheral.hasType) then return peripheral.hasType(Name, "drive") == true end
	return peripheral.getType(Name) == "drive"
end

Storage.IsDrive = IsDrive

-- Orders sides first, then network drives by number (drive_2 before drive_10).
local function DriveLess(A, B)
	local AName, ANumber = A:match("^(.-)_(%d+)$")
	local BName, BNumber = B:match("^(.-)_(%d+)$")
	if (not AName and BName) then return true end
	if (AName and not BName) then return false end
	if (AName and BName) then
		if (AName ~= BName) then return AName < BName end
		return tonumber(ANumber) < tonumber(BNumber)
	end
	return A < B
end

function Storage.ValidDomain(Name)
	if (type(Name) ~= "string") then return false, "Enter a domain name" end
	Name = Name:lower()
	if (#Name < 1 or #Name > 32) then return false, "Domains are 1 to 32 characters long" end
	if (Storage.Reserved[Name]) then return false, "That name is reserved" end
	for Label in (Name .. "."):gmatch("(.-)%.") do
		if (Label == "") then return false, "Domains cannot have empty parts (like a..b)" end
		if (not Label:match("^[a-z0-9][a-z0-9%-]*$") or Label:sub(-1) == "-") then
			return false, "Use letters, numbers and dashes, separated by dots"
		end
	end
	return true
end

function Storage.ReadMeta(Mount)
	local Data = ReadFile(fs.combine(Mount, Storage.MetaFile))
	if (not Data) then return nil end
	local Meta = textutils.unserialise(Data)
	if (type(Meta) ~= "table" or not Storage.ValidDomain(Meta.Domain)) then return nil end
	return Meta
end

function Storage.WriteMeta(Entry, Meta)
	Entry.Meta = Meta
	return WriteFile(fs.combine(Entry.Mount, Storage.MetaFile), textutils.serialise(Meta))
end

local function Wipe(Mount)
	for _, Name in ipairs(fs.list(Mount)) do
		fs.delete(fs.combine(Mount, Name))
	end
end

Storage.Wipe = Wipe

local function Changed()
	Storage.Version = Storage.Version + 1
	if (os.queueEvent) then os.queueEvent("ccinternet_update") end
end

Storage.Changed = Changed

------------------------------------------------------------------------
-- Drives
------------------------------------------------------------------------

-- Looks at one drive. State is one of:
--   "empty"   no disk inserted          "nodata"  a disk without files (music disc)
--   "blank"   an empty floppy, ready     "domain"  holds a domain
--   "foreign" a floppy with other files  "duplicate" a second floppy for a domain already loaded
--   "search"  a cc.net disk
function Storage.Inspect(Name)
	local Entry = { Name = Name, State = "empty" }
	if (not disk.isPresent(Name)) then return Entry end
	if (not disk.hasData(Name)) then
		Entry.State = "nodata"
		return Entry
	end
	local Mount = disk.getMountPath(Name)
	if (not Mount) then
		Entry.State = "nodata"
		return Entry
	end
	Entry.Mount = "/" .. Mount
	Entry.DiskId = disk.getID(Name)
	Entry.Label = disk.getLabel(Name)
	local Meta = Storage.ReadMeta(Entry.Mount)
	if (Meta) then
		Entry.State = "domain"
		Entry.Domain = Meta.Domain:lower()
		Entry.Meta = Meta
	elseif (fs.exists(fs.combine(Entry.Mount, Storage.SearchFile))) then
		Entry.State = "search"
	elseif (#fs.list(Entry.Mount) == 0) then
		Entry.State = "blank"
	else
		Entry.State = "foreign"
	end
	return Entry
end

-- Turns a blank floppy in the search drive into a cc.net disk.
function Storage.SetupSearch(Entry)
	local Ok, Problem = WriteFile(fs.combine(Entry.Mount, Storage.SearchFile), textutils.serialise({ Version = 1, Created = os.epoch and os.epoch("utc") or 0 }))
	if (not Ok) then return false, Problem end
	pcall(disk.setLabel, Entry.Name, "cc.net")
	Entry.State = "search"
	Entry.Label = "cc.net"
	return true
end

function Storage.Scan()
	local Names = {}
	for _, Name in ipairs(peripheral.getNames()) do
		if (Name ~= Storage.TransferSide and IsDrive(Name)) then Names[#Names + 1] = Name end
	end
	table.sort(Names, DriveLess)
	local Drives, Domains = {}, {}
	local Search = nil
	for _, Name in ipairs(Names) do
		local Entry = Storage.Inspect(Name)
		-- The search drive serves cc.net. A domain floppy left in it keeps working as part of the
		-- cluster (so nothing goes offline), but then cc.net has no disk.
		if (Name == Storage.SearchSide and Entry.State ~= "domain") then
			if (Entry.State == "blank") then Storage.SetupSearch(Entry) end
			Search = Entry
		elseif (Entry.State == "domain") then
			if (Domains[Entry.Domain]) then
				Entry.State = "duplicate"
			else
				Domains[Entry.Domain] = Entry
			end
		end
		if (Entry ~= Search) then Drives[#Drives + 1] = Entry end
	end
	if (not Search) then
		-- A domain floppy in the search drive stays in the cluster; remember which one for the admin.
		for _, Entry in ipairs(Drives) do
			if (Entry.Name == Storage.SearchSide) then Search = { Name = Entry.Name, State = "domain", Domain = Entry.Domain } end
		end
	end
	Storage.Drives = Drives
	Storage.Domains = Domains
	Storage.SearchDrive = Search
	Storage.Generation = Storage.Generation + 1
	RouteCache = {}
	SiteVersions = {}
	Changed()
end

-- True when the search drive holds a cc.net disk.
function Storage.SearchReady()
	local Entry = Storage.SearchDrive
	return Entry ~= nil and Entry.State == "search" and Entry.Mount ~= nil and fs.exists(Entry.Mount)
end

function Storage.Get(Domain)
	if (type(Domain) ~= "string") then return nil end
	local Entry = Storage.Domains[Domain:lower()]
	if (Entry and not fs.exists(Entry.Mount)) then
		Storage.Scan()
		Entry = Storage.Domains[Domain:lower()]
	end
	return Entry
end

function Storage.DomainList()
	local List = {}
	for Name in pairs(Storage.Domains) do List[#List + 1] = Name end
	table.sort(List)
	return List
end

function Storage.Counts()
	local Counts = { Drives = #Storage.Drives, Blank = 0, Domains = 0, Empty = 0, Other = 0 }
	for _, Entry in ipairs(Storage.Drives) do
		if (Entry.State == "blank") then Counts.Blank = Counts.Blank + 1
		elseif (Entry.State == "domain") then Counts.Domains = Counts.Domains + 1
		elseif (Entry.State == "empty") then Counts.Empty = Counts.Empty + 1
		else Counts.Other = Counts.Other + 1 end
	end
	return Counts
end

function Storage.FirstBlank()
	for _, Entry in ipairs(Storage.Drives) do
		if (Entry.State == "blank" and fs.exists(Entry.Mount) and #fs.list(Entry.Mount) == 0) then return Entry end
	end
	return nil
end

function Storage.Capacity(Mount)
	if (fs.getCapacity) then
		local Ok, Capacity = pcall(fs.getCapacity, Mount)
		if (Ok and Capacity) then return Capacity end
	end
	return Storage.DefaultCapacity
end

-- Returns used bytes, capacity and free bytes of a floppy.
function Storage.Usage(Entry)
	local Capacity = Storage.Capacity(Entry.Mount)
	local Free = fs.getFreeSpace(Entry.Mount)
	if (type(Free) ~= "number") then Free = Capacity end
	return math.max(0, Capacity - Free), Capacity, Free
end

------------------------------------------------------------------------
-- Domains
------------------------------------------------------------------------

function Storage.DefaultPage(Domain)
	return table.concat({
		"--",
		"title: " .. Domain,
		"location: /",
		"--",
		"<p alignment=\"center\">",
		"Welcome to " .. Ccmd.Escape(Domain) .. "!",
		"",
		"This domain was just registered.",
		"The owner can upload files at [domain://](domain://).",
		"</p>"
	}, "\n") .. "\n"
end

-- Puts a new domain on a blank floppy. Returns the entry or nil and an error.
function Storage.Create(Domain, Salt, Hash, Options)
	Options = Options or {}
	Domain = Domain:lower()
	if (Storage.Domains[Domain]) then return nil, "That domain is already taken" end
	local Entry = Options.Entry or Storage.FirstBlank()
	if (not Entry) then return nil, "No blank floppy disks are left in this cluster" end
	local Meta = { Domain = Domain, Salt = Salt, Hash = Hash, Created = os.epoch and os.epoch("utc") or 0, Suspended = false, Version = 1 }
	local Ok, Problem = Storage.WriteMeta(Entry, Meta)
	if (not Ok) then return nil, Problem end
	fs.makeDir(fs.combine(Entry.Mount, Storage.SiteDir))
	if (not Options.Empty) then
		WriteFile(fs.combine(Entry.Mount, Storage.SiteDir .. "/index.ccmd"), Storage.DefaultPage(Domain))
	end
	pcall(disk.setLabel, Entry.Name, Domain)
	Entry.State = "domain"
	Entry.Domain = Domain
	Entry.Label = Domain
	Storage.Domains[Domain] = Entry
	Forget(Domain)
	Changed()
	return Entry
end

-- Wipes a domain floppy so it becomes blank again.
function Storage.Release(Entry)
	Wipe(Entry.Mount)
	pcall(disk.setLabel, Entry.Name, nil)
	if (Entry.Domain) then
		Storage.Domains[Entry.Domain] = nil
		Forget(Entry.Domain)
	end
	Entry.State = "blank"
	Entry.Domain = nil
	Entry.Meta = nil
	Entry.Label = nil
	Changed()
end

function Storage.SetSuspended(Entry, Suspended)
	Entry.Meta.Suspended = Suspended and true or false
	Storage.WriteMeta(Entry, Entry.Meta)
	Changed()
end

function Storage.SetPassword(Entry, Salt, Hash)
	Entry.Meta.Salt = Salt
	Entry.Meta.Hash = Hash
	Storage.WriteMeta(Entry, Entry.Meta)
end

------------------------------------------------------------------------
-- Site files
------------------------------------------------------------------------

function Storage.SiteRoot(Entry)
	return fs.combine(Entry.Mount, Storage.SiteDir)
end

-- Real path of a site path such as "/img/logo.nft", or nil when it escapes the site folder.
function Storage.SitePath(Entry, Path)
	local Clean = Protocol.NormalizePath(Path)
	if (not Clean) then return nil end
	return "/" .. fs.combine(Storage.SiteRoot(Entry), Clean:sub(2)), Clean
end

-- Every file of a site: { { Path = "/index.ccmd", Size = 123 } }, sorted by path.
function Storage.Files(Entry)
	local Root = Storage.SiteRoot(Entry)
	local Files = {}
	local function Walk(Dir, Prefix)
		if (not fs.exists(Dir)) then return end
		for _, Name in ipairs(fs.list(Dir)) do
			local Full = fs.combine(Dir, Name)
			if (fs.isDir(Full)) then
				Walk(Full, Prefix .. Name .. "/")
			else
				Files[#Files + 1] = { Path = Prefix .. Name, Size = fs.getSize(Full) }
			end
		end
	end
	Walk(Root, "/")
	table.sort(Files, function(A, B) return A.Path < B.Path end)
	return Files
end

-- Maps page locations to files by reading each .ccmd file's front matter. Cached per domain.
-- Returns Routes, Pages ({ Path, Location, Title, Error }) and Conflicts.
function Storage.Routes(Entry)
	local Cached = RouteCache[Entry.Domain]
	if (Cached) then return Cached.Routes, Cached.Pages, Cached.Conflicts end
	local Routes, Pages, Conflicts = {}, {}, {}
	for _, File in ipairs(Storage.Files(Entry)) do
		if (File.Path:lower():match("%.ccmd$")) then
			local Data = ReadFile(Storage.SitePath(Entry, File.Path)) or ""
			local Meta, _, Problem = Ccmd.ParseFrontMatter(Data)
			local Page = { Path = File.Path, Title = Meta and Meta.title, Error = Problem }
			if (Meta and Meta.location) then
				local Location = Protocol.NormalizePath(Meta.location)
				Page.Location = Location
				if (Location) then
					if (Routes[Location]) then
						Conflicts[#Conflicts + 1] = Location
					else
						Routes[Location] = File.Path
					end
				end
			end
			Pages[#Pages + 1] = Page
		end
	end
	RouteCache[Entry.Domain] = { Routes = Routes, Pages = Pages, Conflicts = Conflicts }
	return Routes, Pages, Conflicts
end

function Storage.Invalidate(Entry)
	Forget(Entry.Domain)
	Changed()
end

-- Finds the file for a request path: a page location first, then a file path, then a folder's index.ccmd.
function Storage.Resolve(Entry, Path)
	local Routes = Storage.Routes(Entry)
	local Clean = Protocol.NormalizePath(Path)
	if (not Clean) then return nil end
	if (Routes[Clean]) then return Routes[Clean] end
	local Real = Storage.SitePath(Entry, Clean)
	if (Real and fs.exists(Real)) then
		if (not fs.isDir(Real)) then return Clean end
		local Index = (Clean == "/" and "" or Clean) .. "/index.ccmd"
		if (fs.exists(Storage.SitePath(Entry, Index))) then return Index end
	end
	return nil
end

function Storage.Read(Entry, Path)
	local Real = Storage.SitePath(Entry, Path)
	return Real and ReadFile(Real)
end

-- Checks an upload path. Returns the clean path or nil and a reason.
function Storage.CleanUploadPath(Folder, Name)
	local Joined = tostring(Folder or "/") .. "/" .. tostring(Name or "")
	local Clean = Protocol.NormalizePath(Joined)
	if (not Clean or Clean == "/") then return nil, "Bad file name: " .. tostring(Name) end
	if (#Clean > Storage.MaxPathLength) then return nil, "Path too long: " .. Clean end
	if (not Clean:match("^[%w%._%-/ ]+$")) then return nil, "Use letters, numbers, spaces, dots, dashes and underscores: " .. Clean end
	local Depth = select(2, Clean:gsub("/", ""))
	if (Depth > 8) then return nil, "Folders nested too deeply: " .. Clean end
	return Clean
end

-- Writes files into a site. Files maps relative paths to contents.
-- Everything is checked (names, front matter, space) before anything is written.
-- Returns a result { Written = { paths }, Warnings = { text } } or nil and an error.
function Storage.Upload(Entry, Files, Folder)
	if (type(Files) ~= "table") then return nil, "Choose a file or folder to upload" end
	local Plan = {}
	local Count = 0
	for Name, Data in pairs(Files) do
		if (type(Data) ~= "string") then return nil, "Bad file data for " .. tostring(Name) end
		local Clean, Problem = Storage.CleanUploadPath(Folder, Name)
		if (not Clean) then return nil, Problem end
		Count = Count + 1
		if (Count > Storage.MaxUploadFiles) then return nil, "Too many files (at most " .. Storage.MaxUploadFiles .. ")" end
		Plan[#Plan + 1] = { Path = Clean, Data = Data }
	end
	if (Count == 0) then return nil, "Choose a file or folder to upload" end
	table.sort(Plan, function(A, B) return A.Path < B.Path end)

	local Warnings = {}
	local Needed = 0
	local NewDirs = {}
	for _, Item in ipairs(Plan) do
		if (Item.Path:lower():match("%.ccmd$")) then
			local _, _, Problem = Ccmd.ParseFrontMatter(Item.Data)
			if (Problem) then return nil, Item.Path .. ": " .. Problem end
		end
		local Real = Storage.SitePath(Entry, Item.Path)
		if (fs.exists(Real) and fs.isDir(Real)) then return nil, Item.Path .. " is a folder" end
		local Old = fs.exists(Real) and fs.getSize(Real) or nil
		Needed = Needed + Cost(#Item.Data) - (Old and Cost(Old) or 0)
		local Dir = fs.getDir(Real)
		while (Dir ~= "" and Dir ~= Storage.SiteRoot(Entry) and not fs.exists(Dir) and not NewDirs[Dir]) do
			NewDirs[Dir] = true
			Needed = Needed + Storage.FileOverhead
			Dir = fs.getDir(Dir)
		end
	end
	local _, _, Free = Storage.Usage(Entry)
	if (Needed > Free) then
		return nil, string.format("Not enough space: the upload needs %s but only %s is free", Storage.FormatSize(Needed), Storage.FormatSize(Free)), 413
	end

	local Written = {}
	for _, Item in ipairs(Plan) do
		local Ok, Problem = WriteFile(Storage.SitePath(Entry, Item.Path), Item.Data)
		if (not Ok) then
			Storage.Invalidate(Entry)
			return nil, "Could not write " .. Item.Path .. ": " .. tostring(Problem), 507
		end
		Written[#Written + 1] = Item.Path
	end
	Storage.Invalidate(Entry)
	local _, _, Conflicts = Storage.Routes(Entry)
	for _, Location in ipairs(Conflicts) do
		Warnings[#Warnings + 1] = "More than one page uses location " .. Location
	end
	return { Written = Written, Warnings = Warnings }
end

function Storage.Delete(Entry, Path)
	local Real, Clean = Storage.SitePath(Entry, Path)
	if (not Real or Clean == "/" or not fs.exists(Real)) then return false, "No such file" end
	fs.delete(Real)
	-- Remove folders left empty.
	local Dir = fs.getDir(Real)
	while (Dir ~= "" and "/" .. Dir ~= "/" .. Storage.SiteRoot(Entry) and fs.exists(Dir) and #fs.list(Dir) == 0) do
		fs.delete(Dir)
		Dir = fs.getDir(Dir)
	end
	Storage.Invalidate(Entry)
	return true
end

------------------------------------------------------------------------
-- Form submissions
------------------------------------------------------------------------

Storage.MaxSubmission = 2048

local function FormFile(Entry, Path)
	local Name = Path:gsub("^/", ""):gsub("[^%w%-_]", "_")
	if (Name == "") then Name = "index" end
	return fs.combine(fs.combine(Entry.Mount, Storage.FormsDir), Name .. ".log"), Name
end

-- Stores a form submission sent to a site path. Returns true or nil, error, status.
function Storage.Submit(Entry, Path, Sender, Fields)
	local Clean = {}
	for Key, Value in pairs(type(Fields) == "table" and Fields or {}) do
		if (type(Key) == "string" and (type(Value) == "string" or type(Value) == "number" or type(Value) == "boolean")) then
			Clean[Key] = tostring(Value)
		end
	end
	local Record = textutils.serialise({ Time = os.date("%Y-%m-%d %H:%M:%S"), Sender = Sender, Fields = Clean }, { compact = true }):gsub("\n", " ")
	if (#Record > Storage.MaxSubmission) then return nil, "The form data is too large", 413 end
	local File = FormFile(Entry, Path)
	local Extra = #Record + 1
	if (not fs.exists(File)) then Extra = Cost(Extra) + (fs.exists(fs.getDir(File)) and 0 or Storage.FileOverhead) end
	local _, _, Free = Storage.Usage(Entry)
	if (Extra > Free) then return nil, "This site is out of space", 507 end
	local Dir = fs.getDir(File)
	if (not fs.exists(Dir)) then fs.makeDir(Dir) end
	local Handle = fs.open(File, "a")
	if (not Handle) then return nil, "Could not save the form", 500 end
	Handle.writeLine(Record)
	Handle.close()
	Changed()
	return true
end

-- Lists submissions: { { Form = "contact", Entries = { { Time, Sender, Fields } } } }.
function Storage.Submissions(Entry)
	local Dir = fs.combine(Entry.Mount, Storage.FormsDir)
	local Result = {}
	if (not fs.exists(Dir)) then return Result end
	for _, Name in ipairs(fs.list(Dir)) do
		local Data = ReadFile(fs.combine(Dir, Name)) or ""
		local Entries = {}
		for Line in Data:gmatch("[^\n]+") do
			local Value = textutils.unserialise(Line)
			if (type(Value) == "table") then Entries[#Entries + 1] = Value end
		end
		Result[#Result + 1] = { Form = Name:gsub("%.log$", ""), Entries = Entries }
	end
	table.sort(Result, function(A, B) return A.Form < B.Form end)
	return Result
end

function Storage.ClearSubmissions(Entry)
	local Dir = fs.combine(Entry.Mount, Storage.FormsDir)
	if (fs.exists(Dir)) then fs.delete(Dir) end
	Changed()
end

------------------------------------------------------------------------
-- Copying whole floppies
------------------------------------------------------------------------

-- Bytes a folder tree would take on a disk, counting the per-file minimum.
function Storage.TreeCost(Path)
	local Total = 0
	if (not fs.exists(Path)) then return 0 end
	for _, Name in ipairs(fs.list(Path)) do
		local Full = fs.combine(Path, Name)
		if (fs.isDir(Full)) then
			Total = Total + Storage.FileOverhead + Storage.TreeCost(Full)
		else
			Total = Total + Cost(fs.getSize(Full))
		end
	end
	return Total
end

-- Copies the contents of one folder into another (which should be empty).
function Storage.CopyTree(From, To)
	if (not fs.exists(To)) then fs.makeDir(To) end
	for _, Name in ipairs(fs.list(From)) do
		local Source = fs.combine(From, Name)
		local Target = fs.combine(To, Name)
		if (fs.isDir(Source)) then
			Storage.CopyTree(Source, Target)
		else
			local Ok, Problem = WriteFile(Target, ReadFile(Source) or "")
			if (not Ok) then return false, Problem end
		end
	end
	return true
end

function Storage.FormatSize(Bytes)
	if (Bytes < 1000) then return Bytes .. " B" end
	return string.format("%.1f KB", Bytes / 1000)
end

return Storage
