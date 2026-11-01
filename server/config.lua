-- Server configuration, stored as a serialised table in the data folder.

local Config = {}

Config.Defaults = {
	Hostname = "ccinternet",  -- name browsers look up with rednet.lookup("ccinternet", Hostname)
	TransferSide = "left",    -- the disk drive used to copy domains to and from floppies
	AutoLock = 5,             -- minutes of no input before the admin screen locks (0 = never)
	Registration = true,      -- whether domain:// accepts new domains
	PublicDirectory = true,   -- whether domain://directory lists every domain
	AdminSalt = nil,
	AdminHash = nil
}

Config.Values = {}
Config.Path = "/ccinternet/data/config.db"

local function Copy(Value)
	if (type(Value) ~= "table") then return Value end
	local Result = {}
	for Key, Item in pairs(Value) do Result[Key] = Copy(Item) end
	return Result
end

function Config.Init(DataDir)
	Config.Path = fs.combine(DataDir, "config.db")
	Config.Load()
end

function Config.Load()
	local Values = Copy(Config.Defaults)
	if (fs.exists(Config.Path)) then
		local Handle = fs.open(Config.Path, "r")
		if (Handle) then
			local Stored = textutils.unserialise(Handle.readAll() or "")
			Handle.close()
			if (type(Stored) == "table") then
				for Key, Value in pairs(Stored) do Values[Key] = Value end
			end
		end
	end
	Config.Values = Values
	return Values
end

function Config.Save()
	local Dir = fs.getDir(Config.Path)
	if (Dir ~= "" and not fs.exists(Dir)) then fs.makeDir(Dir) end
	local Handle = fs.open(Config.Path, "w")
	Handle.write(textutils.serialise(Config.Values))
	Handle.close()
end

function Config.Get(Key)
	return Config.Values[Key]
end

function Config.Set(Key, Value)
	Config.Values[Key] = Value
	Config.Save()
end

function Config.IsOnboarded()
	return Config.Values.AdminHash ~= nil
end

return Config
