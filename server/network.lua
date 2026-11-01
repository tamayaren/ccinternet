-- Answers browser requests that arrive over rednet.

local Protocol = require("lib.protocol")
local Router = require("server.router")
local Log = require("server.log")

local Network = {
	Hostname = nil,
	Hosted = false,
	Modems = 0,
	Problem = nil
}

-- Opens the modems and registers the hostname so browsers can find this core.
function Network.Start(Hostname)
	Network.Hostname = Hostname
	Network.Modems = Protocol.OpenModems()
	if (Network.Modems == 0) then
		Network.Hosted = false
		Network.Problem = "No modem attached"
		return false, Network.Problem
	end
	local Ok, Problem = pcall(rednet.host, Protocol.Name, Hostname)
	Network.Hosted = Ok
	Network.Problem = not Ok and (tostring(Problem):match("in use") and ("Another computer already uses \"" .. Hostname .. "\"") or tostring(Problem)) or nil
	return Ok, Network.Problem
end

-- Checks whether another computer already answers to a hostname.
function Network.InUse(Hostname)
	if (Protocol.OpenModems() == 0) then return false end
	local Id = rednet.lookup(Protocol.Name, Hostname)
	return Id ~= nil and Id ~= os.getComputerID()
end

function Network.Rename(Hostname)
	if (Network.InUse(Hostname)) then return false, "Another computer already uses \"" .. Hostname .. "\"" end
	pcall(rednet.unhost, Protocol.Name)
	return Network.Start(Hostname)
end

-- Handles one finished request message and sends the response back.
function Network.Answer(Full)
	local Response, Url = Router.SafeHandle(Full, Full.Sender)
	local Head = { Status = Response.Status, Headers = Response.Headers }
	Protocol.Send(Full.Sender, "response", Full.Id, Head, Response.Body)
	local Method = type(Full.Head.Method) == "string" and Full.Head.Method:upper() or "GET"
	local UrlText = Url and Protocol.FormatUrl(Url) or tostring(Full.Head.Url)
	Log.Request(Full.Sender, Method, UrlText, Response.Status)
	os.queueEvent("ccinternet_log")
end

function Network.Loop()
	local Collector = Protocol.Assembler()
	while (true) do
		local _, Sender, Message, Name = os.pullEventRaw("rednet_message")
		if (Name == Protocol.Name and type(Message) == "table" and Message.Type == "request") then
			local Full = Collector:Feed(Sender, Message)
			if (Full) then Network.Answer(Full) end
		end
	end
end

return Network
