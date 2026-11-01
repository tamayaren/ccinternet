-- The transfer drive (left of the core by default): copy a domain out to a floppy, or load one in.

local Storage = require("server.storage")
local Ccmd = require("lib.ccmd")

local Transfer = {}

-- Only the parts of a domain floppy the server knows about are copied, so a floppy cannot smuggle
-- in other files (such as a startup.lua that would run when the core boots).
local DomainParts = { Storage.MetaFile, Storage.SiteDir, Storage.FormsDir }

local function CopyDomain(From, To)
	for _, Name in ipairs(DomainParts) do
		local Source = fs.combine(From, Name)
		if (fs.exists(Source)) then
			local Target = fs.combine(To, Name)
			if (fs.isDir(Source)) then
				local Ok, Problem = Storage.CopyTree(Source, Target)
				if (not Ok) then return false, Problem end
			else
				local Ok, Problem = Storage.WriteFile(Target, Storage.ReadFile(Source) or "")
				if (not Ok) then return false, Problem end
			end
		end
	end
	return true
end

local function DomainCost(Mount)
	local Total = 0
	for _, Name in ipairs(DomainParts) do
		local Path = fs.combine(Mount, Name)
		if (fs.exists(Path)) then
			Total = Total + (fs.isDir(Path) and (Storage.FileOverhead + Storage.TreeCost(Path)) or math.max(Storage.FileOverhead, fs.getSize(Path)))
		end
	end
	return Total
end

function Transfer.Side()
	return Storage.TransferSide
end

-- Describes the floppy in the transfer drive. State is one of:
--   "missing" no drive on that side    "none"    no disk in the drive    "nodata" a disk without files
--   "blank"   an empty floppy          "domain"  an exported domain (has ccinternet.meta)
--   "site"    loose website files (has .ccmd pages, no meta)             "foreign" other files
function Transfer.Status()
	local Side = Storage.TransferSide
	local Status = { Side = Side }
	if (not Storage.IsDrive(Side)) then
		Status.State = "missing"
		return Status
	end
	local Entry = Storage.Inspect(Side)
	Status.Entry = Entry
	Status.Mount = Entry.Mount
	Status.Label = Entry.Label
	if (Entry.State == "empty") then
		Status.State = "none"
	elseif (Entry.State == "nodata") then
		Status.State = "nodata"
	elseif (Entry.State == "domain") then
		Status.State = "domain"
		Status.Domain = Entry.Domain
		Status.Meta = Entry.Meta
	elseif (Entry.State == "blank") then
		Status.State = "blank"
	else
		Status.State = "foreign"
		local Root = Transfer.SiteSource(Entry.Mount)
		for _, Name in ipairs(fs.list(Root)) do
			if (Name:lower():match("%.ccmd$")) then Status.State = "site" end
		end
	end
	if (Entry.Mount) then
		Status.Used = Storage.TreeCost(Entry.Mount)
		Status.Capacity = Storage.Capacity(Entry.Mount)
	end
	return Status
end

-- Loose site files may sit at the root of the floppy or inside a site folder.
function Transfer.SiteSource(Mount)
	local Inner = fs.combine(Mount, Storage.SiteDir)
	if (fs.exists(Inner) and fs.isDir(Inner)) then return Inner end
	return Mount
end

-- Copies a whole domain floppy onto the transfer floppy. Overwrite wipes whatever is on it first.
function Transfer.Export(Domain, Overwrite)
	local Entry = Storage.Get(Domain)
	if (not Entry) then return false, "No such domain" end
	local Status = Transfer.Status()
	if (Status.State == "missing") then return false, "There is no disk drive on the " .. Status.Side .. " side" end
	if (Status.State == "none" or Status.State == "nodata") then return false, "Put a floppy disk in the transfer drive" end
	if (Status.State ~= "blank" and not Overwrite) then return false, "The transfer floppy is not empty", "confirm" end
	local Needed = DomainCost(Entry.Mount)
	if (Needed > Storage.Capacity(Status.Mount)) then return false, "The domain does not fit on the transfer floppy" end
	Storage.Wipe(Status.Mount)
	local Ok, Problem = CopyDomain(Entry.Mount, Status.Mount)
	if (not Ok) then return false, Problem end
	pcall(disk.setLabel, Status.Side, Entry.Domain)
	return true
end

-- Loads an exported domain from the transfer floppy into the cluster.
-- Replace overwrites a domain of the same name that is already in the cluster.
function Transfer.Import(Replace)
	local Status = Transfer.Status()
	if (Status.State ~= "domain") then return false, "The transfer floppy does not hold an exported domain" end
	local Domain = Status.Domain
	local Target = Storage.Get(Domain)
	if (Target and not Replace) then return false, Domain .. " already exists in this cluster", "confirm" end
	if (not Target) then
		Target = Storage.FirstBlank()
		if (not Target) then return false, "No blank floppy disks are left in the cluster" end
	end
	if (DomainCost(Status.Mount) > Storage.Capacity(Target.Mount)) then return false, "The domain does not fit on a cluster floppy" end
	Storage.Wipe(Target.Mount)
	local Ok, Problem = CopyDomain(Status.Mount, Target.Mount)
	if (not Ok) then
		Storage.Scan()
		return false, Problem
	end
	pcall(disk.setLabel, Target.Name, Domain)
	Storage.Scan()
	return true, Domain
end

-- Creates a new domain from loose site files on the transfer floppy.
function Transfer.ImportSite(Domain, Salt, Hash)
	local Status = Transfer.Status()
	if (Status.State ~= "site" and Status.State ~= "foreign") then return false, "The transfer floppy has no website files" end
	local Valid, Problem = Storage.ValidDomain(Domain)
	if (not Valid) then return false, Problem end
	local Source = Transfer.SiteSource(Status.Mount)
	-- Check every page before copying anything.
	for _, Name in ipairs(fs.list(Source)) do
		local Full = fs.combine(Source, Name)
		if (not fs.isDir(Full) and Name:lower():match("%.ccmd$")) then
			local _, _, Error = Ccmd.ParseFrontMatter(Storage.ReadFile(Full) or "")
			if (Error) then return false, Name .. ": " .. Error end
		end
	end
	local Entry, CreateProblem = Storage.Create(Domain, Salt, Hash, { Empty = true })
	if (not Entry) then return false, CreateProblem end
	local Site = Storage.SiteRoot(Entry)
	if (Storage.TreeCost(Source) > select(3, Storage.Usage(Entry))) then
		Storage.Release(Entry)
		return false, "The files do not fit on one floppy"
	end
	local Ok, CopyProblem = Storage.CopyTree(Source, Site)
	if (not Ok) then
		Storage.Release(Entry)
		return false, CopyProblem
	end
	Storage.Invalidate(Entry)
	return true, Domain
end

function Transfer.Wipe()
	local Status = Transfer.Status()
	if (not Status.Mount) then return false, "There is no floppy in the transfer drive" end
	Storage.Wipe(Status.Mount)
	pcall(disk.setLabel, Status.Side, nil)
	return true
end

return Transfer
