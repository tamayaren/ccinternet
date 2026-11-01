-- Request and event log: a ring buffer in memory plus a rotated file in the data folder.

local Log = {}

Log.Limit = 200
Log.FileLimit = 32 * 1024
Log.Entries = {}
Log.Path = nil
Log.Stats = { Requests = 0, Errors = 0 }

function Log.Init(DataDir)
	Log.Path = fs.combine(DataDir, "requests.log")
end

local function Append(Line)
	if (not Log.Path) then return end
	if (fs.exists(Log.Path) and fs.getSize(Log.Path) > Log.FileLimit) then
		local Old = Log.Path .. ".old"
		if (fs.exists(Old)) then fs.delete(Old) end
		fs.move(Log.Path, Old)
	end
	local Handle = fs.open(Log.Path, "a")
	if (Handle) then
		Handle.writeLine(Line)
		Handle.close()
	end
end

local function Push(Entry)
	table.insert(Log.Entries, 1, Entry)
	if (#Log.Entries > Log.Limit) then Log.Entries[#Log.Entries] = nil end
end

function Log.Request(Sender, Method, Url, Status)
	Log.Stats.Requests = Log.Stats.Requests + 1
	if (Status >= 500) then Log.Stats.Errors = Log.Stats.Errors + 1 end
	local Entry = { Time = os.date("%H:%M:%S"), Sender = Sender, Method = Method, Url = Url, Status = Status }
	Push(Entry)
	Append(string.format("%s #%s %s %s %d", os.date("%Y-%m-%d %H:%M:%S"), tostring(Sender), Method, Url, Status))
end

function Log.Event(Text)
	local Entry = { Time = os.date("%H:%M:%S"), Event = Text }
	Push(Entry)
	Append(os.date("%Y-%m-%d %H:%M:%S") .. " * " .. Text)
end

return Log
