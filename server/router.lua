-- Turns a request into a response. Used by the network loop and by the core's own browser.

local Protocol = require("lib.protocol")
local Storage = require("server.storage")
local Config = require("server.config")
local Pages = require("server.pages")
local Domains = require("server.domains")

local Router = {}

Router.Local = "local" -- sender name for requests made on the core itself
Router.OnRequest = nil  -- function(Sender, Method, Url, Status), set by the server to log requests

local function Visitor404(Entry, Url)
	local Routes = Storage.Routes(Entry)
	local File = Routes["/404"]
	if (File) then
		local Data = Storage.Read(Entry, File)
		if (Data) then return Pages.Response(404, Data) end
	end
	return Pages.Error(404, "Page not found", "ccmd://" .. Entry.Domain .. Url.Path .. " does not exist.", {
		{ "Home page", "ccmd://" .. Entry.Domain .. "/" }
	})
end

local function Serve(Entry, Url, Status)
	local File = Storage.Resolve(Entry, Url.Path)
	if (not File) then return Visitor404(Entry, Url) end
	local Data = Storage.Read(Entry, File)
	if (not Data) then return Visitor404(Entry, Url) end
	return { Status = Status or 200, Headers = { ["Content-Type"] = Protocol.ContentType(File), ["Content-Length"] = #Data }, Body = Data }
end

function Router.Site(Method, Url, Body, Sender)
	if (Url.Host == "") then return Pages.Redirect("domain://", 301) end
	local Entry = Storage.Get(Url.Host)
	if (not Entry) then
		local Links = { { "domain://", "domain://" } }
		if (Config.Values.Registration and Storage.ValidDomain(Url.Host)) then
			Links[#Links + 1] = { "Register it", Protocol.Url("domain", "register", "/", { domain = Url.Host }) }
		end
		return Pages.Error(404, "Site not found", "Nobody owns " .. Url.Host .. " on " .. Config.Values.Hostname .. ".", Links)
	end
	if (Entry.Meta.Suspended and Sender ~= Router.Local) then
		return Pages.Error(403, "Site suspended", Url.Host .. " was suspended by the server admin.")
	end
	if (Method == "GET") then
		return Serve(Entry, Url)
	elseif (Method == "POST") then
		local Ok, Problem, Status = Storage.Submit(Entry, Url.Path, Sender, Body)
		if (not Ok) then return Pages.Error(Status or 500, "Form not sent", Problem, { { "Back", "ccmd://" .. Url.Host .. "/" } }) end
		if (Storage.Resolve(Entry, Url.Path)) then return Serve(Entry, Url) end
		return Pages.Message(200, "Sent!", "Your form was sent to " .. Url.Host .. ".", { { "Back to the site", "ccmd://" .. Url.Host .. "/" } })
	end
	return Pages.Error(405, "Not allowed", Method .. " is not supported on websites.")
end

local function CleanHeaders(Headers)
	local Clean = {}
	local Count = 0
	if (type(Headers) ~= "table") then return Clean end
	for Key, Value in pairs(Headers) do
		if (type(Key) == "string" and (type(Value) == "string" or type(Value) == "number")) then
			Count = Count + 1
			if (Count > 32) then break end
			Clean[Key] = tostring(Value):sub(1, 256)
		end
	end
	return Clean
end

-- Request is { Head = { Method, Url, Headers }, Body }. Returns the response and the parsed URL.
function Router.Handle(Request, Sender)
	local Head = type(Request.Head) == "table" and Request.Head or {}
	local Method = type(Head.Method) == "string" and Head.Method:upper() or "GET"
	local Url = type(Head.Url) == "string" and Protocol.ParseUrl(Head.Url) or nil
	Request.Headers = CleanHeaders(Head.Headers)
	local Response
	if (not Url) then
		Response = Pages.Error(400, "Bad request", "That address could not be read.")
	elseif (Url.Scheme == "domain") then
		Response = Domains.Handle(Method, Url, Request.Body, Sender)
	elseif (Url.Scheme == "ccmd") then
		Response = Router.Site(Method, Url, Request.Body, Sender)
	else
		Response = Pages.Error(400, "Unknown address", Url.Scheme .. ":// is not served here. Use ccmd:// or domain://.")
	end
	Response.Headers = Response.Headers or {}
	Response.Headers.Server = Config.Values.Hostname
	return Response, Url
end

-- Runs Handle and turns errors into a 500 page.
function Router.SafeHandle(Request, Sender)
	local Ok, Response, Url = pcall(Router.Handle, Request, Sender)
	if (not Ok) then
		return Pages.Error(500, "Server error", tostring(Response)), nil
	end
	return Response, Url
end

-- A transport for the browser running on the core itself: it calls the router directly.
function Router.LocalTransport()
	return {
		Hostname = Config.Values.Hostname,
		Local = true,
		Send = function(Method, Url, Headers, Body)
			local Response = Router.SafeHandle({ Head = { Method = Method, Url = Url, Headers = Headers or {} }, Body = Body }, Router.Local)
			if (Router.OnRequest) then Router.OnRequest(Router.Local, Method, Url, Response.Status) end
			return { Status = Response.Status, Headers = Response.Headers or {}, Body = Response.Body }
		end
	}
end

return Router
