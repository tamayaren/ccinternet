-- A small fake CC: Tweaked environment for running ccinternet code under plain Lua 5.2.
-- Provides fs (in memory, with floppy capacity accounting), textutils, peripheral, disk, rednet,
-- os.*, colours, keys, settings, term and window.

local Mock = {}

------------------------------------------------------------------------
-- fs
------------------------------------------------------------------------

local Root = { Dir = true, Children = {} }
local Mounts = {} -- mount name -> { Capacity }
Mock.FileOverhead = 500

local function Split(Path)
	local Parts = {}
	for Part in tostring(Path):gmatch("[^/\\]+") do
		if (Part == "..") then
			Parts[#Parts] = nil
		elseif (Part ~= ".") then
			Parts[#Parts + 1] = Part
		end
	end
	return Parts
end

local function Find(Path)
	local Node = Root
	for _, Part in ipairs(Split(Path)) do
		if (not Node.Dir) then return nil end
		Node = Node.Children[Part]
		if (not Node) then return nil end
	end
	return Node
end

local function Parent(Path, Create)
	local Parts = Split(Path)
	local Name = table.remove(Parts)
	local Node = Root
	for _, Part in ipairs(Parts) do
		local Child = Node.Children[Part]
		if (not Child) then
			if (not Create) then return nil end
			Child = { Dir = true, Children = {} }
			Node.Children[Part] = Child
		end
		if (not Child.Dir) then return nil end
		Node = Child
	end
	return Node, Name
end

local function TreeUsed(Node)
	if (not Node.Dir) then return math.max(#Node.Data, Mock.FileOverhead) end
	local Total = 0
	for _, Child in pairs(Node.Children) do
		Total = Total + TreeUsed(Child)
		if (Child.Dir) then Total = Total + Mock.FileOverhead end
	end
	return Total
end

local function MountOf(Path)
	local First = Split(Path)[1]
	if (First and Mounts[First]) then return First end
	return nil
end

local function CheckSpace(Path)
	local Mount = MountOf(Path)
	if (not Mount) then return end
	local Node = Find(Mount)
	if (TreeUsed(Node) > Mounts[Mount].Capacity) then error("Out of space", 0) end
end

local fs = {}

function fs.combine(...)
	local Parts = {}
	for _, Path in ipairs({ ... }) do
		for _, Part in ipairs(Split(Path)) do Parts[#Parts + 1] = Part end
	end
	return table.concat(Split(table.concat(Parts, "/")), "/")
end

function fs.getName(Path)
	local Parts = Split(Path)
	return Parts[#Parts] or "root"
end

function fs.getDir(Path)
	local Parts = Split(Path)
	if (#Parts == 0) then return ".." end
	Parts[#Parts] = nil
	return table.concat(Parts, "/")
end

function fs.exists(Path) return Find(Path) ~= nil end
function fs.isDir(Path) local Node = Find(Path) return Node ~= nil and Node.Dir == true end
function fs.isReadOnly() return false end

function fs.list(Path)
	local Node = Find(Path)
	if (not Node or not Node.Dir) then error("Not a directory: " .. tostring(Path), 2) end
	local Names = {}
	for Name in pairs(Node.Children) do Names[#Names + 1] = Name end
	table.sort(Names)
	return Names
end

function fs.makeDir(Path)
	local Node = Root
	for _, Part in ipairs(Split(Path)) do
		local Child = Node.Children[Part]
		if (not Child) then
			Child = { Dir = true, Children = {} }
			Node.Children[Part] = Child
		elseif (not Child.Dir) then
			error("File exists", 2)
		end
		Node = Child
	end
	CheckSpace(Path)
end

function fs.delete(Path)
	local Parts = Split(Path)
	if (#Parts == 1 and Mounts[Parts[1]]) then
		Find(Path).Children = {}
		return
	end
	local Node, Name = Parent(Path)
	if (Node and Name) then Node.Children[Name] = nil end
end

function fs.getSize(Path)
	local Node = Find(Path)
	if (not Node) then error("No such file", 2) end
	return Node.Dir and 0 or #Node.Data
end

function fs.move(From, To)
	local Node = Find(From)
	fs.delete(From)
	local Target, Name = Parent(To, true)
	Target.Children[Name] = Node
end

function fs.copy(From, To)
	local function Clone(Node)
		if (not Node.Dir) then return { Data = Node.Data } end
		local Copy = { Dir = true, Children = {} }
		for Name, Child in pairs(Node.Children) do Copy.Children[Name] = Clone(Child) end
		return Copy
	end
	local Target, Name = Parent(To, true)
	Target.Children[Name] = Clone(Find(From))
	CheckSpace(To)
end

function fs.getFreeSpace(Path)
	local Mount = MountOf(Path)
	if (not Mount) then return 1000000 end
	return math.max(0, Mounts[Mount].Capacity - TreeUsed(Find(Mount)))
end

function fs.getCapacity(Path)
	local Mount = MountOf(Path)
	if (not Mount) then return 1000000 end
	return Mounts[Mount].Capacity
end

function fs.open(Path, Mode)
	local Node = Find(Path)
	if (Mode:sub(1, 1) == "r") then
		if (not Node or Node.Dir) then return nil, "No such file" end
		local Data = Node.Data
		local Pos = 1
		return {
			readAll = function()
				local Rest = Data:sub(Pos)
				Pos = #Data + 1
				return Rest
			end,
			readLine = function()
				if (Pos > #Data) then return nil end
				local Line, Next = Data:match("^([^\n]*)\n?()", Pos)
				Pos = Next
				return Line
			end,
			close = function() end
		}
	end
	local Folder, Name = Parent(Path, true)
	if (not Folder or not Name) then return nil, "Cannot open" end
	if (Folder.Children[Name] and Folder.Children[Name].Dir) then return nil, "Is a directory" end
	local File = Folder.Children[Name]
	if (not File or Mode:sub(1, 1) == "w") then
		File = { Data = "" }
		Folder.Children[Name] = File
	end
	return {
		write = function(Text)
			File.Data = File.Data .. tostring(Text)
			local Ok, Problem = pcall(CheckSpace, Path)
			if (not Ok) then
				File.Data = File.Data:sub(1, -#tostring(Text) - 1)
				error(Problem, 0)
			end
		end,
		writeLine = function(Text)
			File.Data = File.Data .. tostring(Text) .. "\n"
		end,
		close = function() end
	}
end

function fs.complete() return {} end

Mock.fs = fs

function Mock.AddMount(Name, Capacity)
	Mounts[Name] = { Capacity = Capacity or 125000 }
	fs.makeDir(Name)
end

function Mock.RemoveMount(Name)
	Mounts[Name] = nil
	Root.Children[Name] = nil
end

------------------------------------------------------------------------
-- textutils
------------------------------------------------------------------------

local textutils = {}

local function Serialise(Value, Indent)
	local Kind = type(Value)
	if (Kind == "string") then return string.format("%q", Value):gsub("\\\n", "\\n") end
	if (Kind == "number" or Kind == "boolean" or Kind == "nil") then return tostring(Value) end
	if (Kind == "table") then
		local Parts = {}
		for Key, Item in pairs(Value) do
			local KeyText = type(Key) == "string" and Key:match("^[%a_][%w_]*$") and Key or ("[" .. Serialise(Key) .. "]")
			Parts[#Parts + 1] = KeyText .. "=" .. Serialise(Item)
		end
		return "{" .. table.concat(Parts, ",") .. "}"
	end
	error("Cannot serialise " .. Kind)
end

function textutils.serialise(Value) return (Serialise(Value)) end
textutils.serialize = textutils.serialise

function textutils.unserialise(Text)
	local Chunk = load("return " .. tostring(Text), "unserialise", "t", {})
	if (not Chunk) then return nil end
	local Ok, Value = pcall(Chunk)
	if (Ok) then return Value end
	return nil
end
textutils.unserialize = textutils.unserialise

function textutils.formatTime() return "12:00" end

Mock.textutils = textutils

------------------------------------------------------------------------
-- peripherals and disks
------------------------------------------------------------------------

local Peripherals = {}
local NextDiskId = 1
local MountCount = 0

local peripheral = {}
function peripheral.getNames()
	local Names = {}
	for Name in pairs(Peripherals) do Names[#Names + 1] = Name end
	table.sort(Names)
	return Names
end
function peripheral.getType(Name) return Peripherals[Name] and Peripherals[Name].Type end
function peripheral.hasType(Name, Type) return Peripherals[Name] ~= nil and Peripherals[Name].Type == Type end
function peripheral.isPresent(Name) return Peripherals[Name] ~= nil end

local disk = {}
local function Drive(Name) return Peripherals[Name] and Peripherals[Name].Type == "drive" and Peripherals[Name] or nil end
function disk.isPresent(Name) local D = Drive(Name) return D ~= nil and D.Disk ~= nil end
function disk.hasData(Name) local D = Drive(Name) return D ~= nil and D.Disk ~= nil and D.Disk.Mount ~= nil end
function disk.getMountPath(Name) local D = Drive(Name) return D and D.Disk and D.Disk.Mount end
function disk.getID(Name) local D = Drive(Name) return D and D.Disk and D.Disk.Id end
function disk.getLabel(Name) local D = Drive(Name) return D and D.Disk and D.Disk.Label end
function disk.setLabel(Name, Label) local D = Drive(Name) if (D and D.Disk) then D.Disk.Label = Label end end
function disk.eject(Name)
	local D = Drive(Name)
	if (D and D.Disk) then
		if (D.Disk.Mount) then Mock.RemoveMount(D.Disk.Mount) end
		D.Disk = nil
	end
end

-- Adds a disk drive. Floppy = true inserts a blank floppy.
function Mock.AddDrive(Name, Floppy, Capacity)
	Peripherals[Name] = { Type = "drive" }
	if (Floppy) then Mock.InsertFloppy(Name, Capacity) end
	return Peripherals[Name]
end

function Mock.InsertFloppy(Name, Capacity)
	MountCount = MountCount + 1
	local Mount = MountCount == 1 and "disk" or ("disk" .. MountCount)
	Mock.AddMount(Mount, Capacity)
	Peripherals[Name].Disk = { Id = NextDiskId, Mount = Mount }
	NextDiskId = NextDiskId + 1
	return Mount
end

function Mock.AddPeripheral(Name, Type)
	Peripherals[Name] = { Type = Type }
end

Mock.peripheral = peripheral
Mock.disk = disk

------------------------------------------------------------------------
-- rednet (records sent messages)
------------------------------------------------------------------------

local rednet = { Sent = {}, Hosted = {} }
function rednet.open() end
function rednet.isOpen() return true end
function rednet.send(Id, Message, Protocol) rednet.Sent[#rednet.Sent + 1] = { Id = Id, Message = Message, Protocol = Protocol } return true end
function rednet.broadcast() end
function rednet.host(Protocol, Name) rednet.Hosted[Protocol] = Name end
function rednet.unhost(Protocol) rednet.Hosted[Protocol] = nil end
function rednet.lookup() return nil end
Mock.rednet = rednet

------------------------------------------------------------------------
-- terminal
------------------------------------------------------------------------

local function NewTerm(W, H)
	local T = { W = W, H = H, X = 1, Y = 1, Fg = "0", Bg = "f", Text = {}, FgRows = {}, BgRows = {} }
	local function Clear()
		for Y = 1, T.H do
			T.Text[Y] = string.rep(" ", T.W)
			T.FgRows[Y] = string.rep(T.Fg, T.W)
			T.BgRows[Y] = string.rep(T.Bg, T.W)
		end
	end
	Clear()
	local function Put(Text, Fg, Bg)
		if (T.Y < 1 or T.Y > T.H) then T.X = T.X + #Text return end
		for I = 1, #Text do
			local X = T.X + I - 1
			if (X >= 1 and X <= T.W) then
				local function Set(Row, C) return Row:sub(1, X - 1) .. C .. Row:sub(X + 1) end
				T.Text[T.Y] = Set(T.Text[T.Y], Text:sub(I, I))
				T.FgRows[T.Y] = Set(T.FgRows[T.Y], Fg:sub(I, I))
				T.BgRows[T.Y] = Set(T.BgRows[T.Y], Bg:sub(I, I))
			end
		end
		T.X = T.X + #Text
	end
	local Api = {}
	function Api.getSize() return T.W, T.H end
	function Api.setCursorPos(X, Y) T.X, T.Y = math.floor(X), math.floor(Y) end
	function Api.getCursorPos() return T.X, T.Y end
	function Api.blit(Text, Fg, Bg)
		assert(#Text == #Fg and #Fg == #Bg, "blit arguments must be the same length")
		assert(not Fg:find("[^0-9a-f]") and not Bg:find("[^0-9a-f]"), "Invalid blit colour")
		Put(Text, Fg, Bg)
	end
	function Api.write(Text) Text = tostring(Text) Put(Text, string.rep(T.Fg, #Text), string.rep(T.Bg, #Text)) end
	function Api.clear() Clear() end
	function Api.clearLine() local X = T.X T.X = 1 Api.write(string.rep(" ", T.W)) T.X = X end
	local function ToChar(Colour) return string.format("%x", math.floor(math.log(Colour) / math.log(2) + 0.5)) end
	function Api.setTextColour(C) T.Fg = ToChar(C) end
	function Api.setBackgroundColour(C) T.Bg = ToChar(C) end
	Api.setTextColor, Api.setBackgroundColor = Api.setTextColour, Api.setBackgroundColour
	function Api.getTextColour() return 2 ^ tonumber(T.Fg, 16) end
	function Api.getBackgroundColour() return 2 ^ tonumber(T.Bg, 16) end
	function Api.setCursorBlink() end
	function Api.isColour() return true end
	Api.isColor = Api.isColour
	function Api.scroll() end
	function Api.setVisible() end
	function Api.redraw() end
	function Api.reposition(X, Y, W, H) end
	Api.State = T
	function Api.Dump()
		return table.concat(T.Text, "\n")
	end
	return Api
end

Mock.NewTerm = NewTerm

------------------------------------------------------------------------
-- Install into _G
------------------------------------------------------------------------

function Mock.Install(Options)
	Options = Options or {}
	_G.fs = fs
	_G.textutils = textutils
	_G.peripheral = peripheral
	_G.disk = disk
	_G.rednet = rednet
	local Colours = {}
	local Names = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }
	for Index, Name in ipairs(Names) do Colours[Name] = 2 ^ (Index - 1) end
	Colours.grey, Colours.lightGrey = Colours.gray, Colours.lightGray
	_G.colours, _G.colors = Colours, Colours
	_G.keys = { enter = 28, backspace = 14, tab = 15, up = 200, down = 208, pageUp = 201, pageDown = 209, home = 199, ["end"] = 207, leftCtrl = 29, rightCtrl = 157, l = 38, r = 19, s = 31, q = 16, y = 21, n = 49, space = 57 }
	local Store = {}
	_G.settings = {
		define = function() end,
		get = function(Name) return Store[Name] end,
		set = function(Name, Value) Store[Name] = Value end,
		save = function() end
	}
	local Clock = 0
	Mock.Events = {}
	os.clock = function() return Clock end
	Mock.Advance = function(Seconds) Clock = Clock + Seconds end
	os.epoch = function() return 1700000000000 end
	os.getComputerID = function() return 1 end
	os.getComputerLabel = function() return nil end
	os.setComputerLabel = function() end
	os.queueEvent = function(...) end
	os.startTimer = function() return 1 end
	os.cancelTimer = function() end
	os.time = function() return 12 end
	os.pullEventRaw = function()
		local Event = table.remove(Mock.Events, 1)
		if (not Event) then error("No more scripted events", 0) end
		if (type(Event) == "function") then return Event() end
		return table.unpack(Event)
	end
	os.pullEvent = os.pullEventRaw
	Mock.ReadQueue = {}
	_G.read = function(Replace, History, Complete, Default)
		local Value = table.remove(Mock.ReadQueue, 1)
		if (Value == nil) then return Default or "" end
		return Value
	end
	local Screen = NewTerm(Options.Width or 51, Options.Height or 19)
	Mock.Screen = Screen
	local Current = Screen
	_G.term = setmetatable({
		current = function() return Current end,
		redirect = function(Target) local Old = Current Current = Target return Old end
	}, { __index = function(_, Key) return Current[Key] end })
	_G.window = {
		create = function(ParentTerm, X, Y, W, H)
			-- A window that writes through to its parent at an offset.
			local Win = NewTerm(W, H)
			local OffsetX, OffsetY = X - 1, Y - 1
			local Blit = Win.blit
			Win.blit = function(Text, Fg, Bg)
				local CX, CY = Win.getCursorPos()
				Blit(Text, Fg, Bg)
				ParentTerm.setCursorPos(CX + OffsetX, CY + OffsetY)
				ParentTerm.blit(Text:sub(1, math.max(0, W - CX + 1)), Fg:sub(1, math.max(0, W - CX + 1)), Bg:sub(1, math.max(0, W - CX + 1)))
			end
			Win.reposition = function(NX, NY, NW, NH) OffsetX, OffsetY = NX - 1, NY - 1 W, H = NW or W, NH or H end
			return Win
		end
	}
	package.path = "./?.lua;" .. package.path
end

return Mock
