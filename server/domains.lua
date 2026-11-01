-- domain:// — the built-in pages where people register domains, upload files and manage their sites.
--
-- Pages (the part after domain:// is the page name):
--   domain://                home: sign in, register
--   domain://register        GET form / POST domain, password, confirm
--   domain://login           POST domain, password
--   domain://manage          GET domain, token
--   domain://upload          POST domain, token (or password), files = { [path] = contents }, folder
--   domain://delete          GET confirm page / POST domain, token, path
--   domain://password        GET form / POST domain, token, old, new, confirm
--   domain://release         GET confirm page / POST domain, token, password
--   domain://submissions     GET domain, token / POST clear
--   domain://logout          GET token
--   domain://directory       list of every domain in the cluster

local Ccmd = require("lib.ccmd")
local Protocol = require("lib.protocol")
local Storage = require("server.storage")
local Config = require("server.config")
local Auth = require("server.auth")
local Pages = require("server.pages")

local Domains = {}

local E = Ccmd.Escape
local A = Ccmd.Attribute

local function Url(Page, Params)
	return Protocol.Url("domain", Page, "/", Params)
end

local function GuestBar()
	local Items = { Pages.Link("Home", "domain://") }
	if (Config.Values.Registration) then Items[#Items + 1] = Pages.Link("Register", Url("register")) end
	if (Config.Values.PublicDirectory) then Items[#Items + 1] = Pages.Link("Directory", Url("directory")) end
	return { table.concat(Items, "  ") }
end

local function OwnerBar(Domain, Token)
	local Params = { domain = Domain, token = Token }
	return { table.concat({
		Pages.Link("Files", Url("manage", Params)),
		Pages.Link("Forms", Url("submissions", Params)),
		Pages.Link("Password", Url("password", Params)),
		Pages.Link("Visit", "ccmd://" .. Domain .. "/"),
		Pages.Link("Sign out", Url("logout", { token = Token }))
	}, "  ") }
end

local function Hidden(Domain, Token)
	return {
		"<input type=\"hidden\" name=\"domain\" value=\"" .. A(Domain) .. "\"/>",
		"<input type=\"hidden\" name=\"token\" value=\"" .. A(Token) .. "\"/>"
	}
end

local function Append(List, Items)
	for _, Item in ipairs(Items) do List[#List + 1] = Item end
	return List
end

local function Notice(Body, Message, Colour)
	if (not Message or Message == "") then return end
	Body[#Body + 1] = "<p>"
	for Line in (tostring(Message) .. "\n"):gmatch("(.-)\n") do
		Body[#Body + 1] = "{" .. (Colour or "lime") .. "}" .. E(Line) .. "{/}"
	end
	Body[#Body + 1] = "</p>"
	Body[#Body + 1] = "<br/>"
end

local function Page(Status, Title, Body, Bar)
	return Pages.Response(Status, Pages.Document(Title, "/", Body, { Topbar = Bar or GuestBar() }))
end

------------------------------------------------------------------------
-- Guest pages
------------------------------------------------------------------------

local function LoginForm(Body, Domain)
	Append(Body, {
		"<form action=\"domain://login\" method=\"POST\">",
		"<input type=\"text\" name=\"domain\" label=\"Domain:  \" width=\"24\" value=\"" .. A(Domain or "") .. "\" placeholder=\"example.com\"/>",
		"<input type=\"password\" name=\"password\" label=\"Password:\" width=\"24\"/>",
		"<button text=\"Sign in\" color=\"blue\" text-color=\"white\"/>",
		"</form>"
	})
end

function Domains.Home(Message, Colour, Status)
	local Counts = Storage.Counts()
	local Body = {}
	Notice(Body, Message, Colour)
	Append(Body, {
		"<p>",
		"Welcome to {yellow}" .. E(Config.Values.Hostname) .. "{/}.",
		"Own a domain here and host a website of up to " .. Storage.FormatSize(Storage.DefaultCapacity) .. ".",
		"</p>",
		"<br/>",
		"<table header-color=\"gray\" text-color=\"white\">",
		"| Cluster | |",
		"|---|---|",
		"| Domains | " .. Counts.Domains .. " |",
		"| Free floppies | " .. Counts.Blank .. " |",
		"</table>",
		"<br/>",
		"{lightGray}Sign in to manage your domain:{/}"
	})
	LoginForm(Body)
	Body[#Body + 1] = "<br/>"
	if (Config.Values.Registration) then
		Body[#Body + 1] = "No domain yet? " .. Pages.Link("Register one", Url("register"))
	else
		Body[#Body + 1] = "{orange}Registration is closed on this server.{/}"
	end
	return Page(Status or 200, "domain://", Body)
end

function Domains.RegisterForm(Message, Fields, Status)
	local Body = {}
	Notice(Body, Message, "red")
	if (not Config.Values.Registration) then
		Notice(Body, "Registration is closed on this server.", "orange")
		return Page(403, "Register a domain", Body)
	end
	local Counts = Storage.Counts()
	if (Counts.Blank == 0) then
		Notice(Body, "There are no free floppy disks right now. Ask the server admin to insert a blank floppy, then try again.", "orange")
	end
	Append(Body, {
		"<p>",
		"Pick a name like {yellow}mysite.com{/}: letters, numbers and dashes, separated by dots.",
		"Your site gets one floppy disk (" .. Storage.FormatSize(Storage.DefaultCapacity) .. ").",
		"</p>",
		"<br/>",
		"<form action=\"domain://register\" method=\"POST\">",
		"<input type=\"text\" name=\"domain\" label=\"Domain:  \" width=\"24\" value=\"" .. A(Fields and Fields.domain or "") .. "\" placeholder=\"mysite.com\"/>",
		"<input type=\"password\" name=\"password\" label=\"Password:\" width=\"24\"/>",
		"<input type=\"password\" name=\"confirm\" label=\"Confirm: \" width=\"24\"/>",
		"<button text=\"Register\" color=\"green\" text-color=\"white\"/>",
		"</form>"
	})
	return Page(Status or 200, "Register a domain", Body)
end

function Domains.Directory()
	if (not Config.Values.PublicDirectory) then return Pages.Error(403, "Directory hidden", "This server does not list its domains.") end
	local Body = { "<table header-color=\"gray\" text-color=\"white\">", "| Domain | Title |", "|---|---|" }
	local Count = 0
	for _, Domain in ipairs(Storage.DomainList()) do
		local Entry = Storage.Domains[Domain]
		if (not Entry.Meta.Suspended) then
			local Routes, Pages_ = Storage.Routes(Entry)
			local Title = ""
			for _, Info in ipairs(Pages_) do
				if (Info.Location == "/") then Title = Info.Title or "" end
			end
			Body[#Body + 1] = "| " .. Pages.Link(Domain, "ccmd://" .. Domain .. "/") .. " | " .. E(Title):gsub("|", "\\|") .. " |"
			Count = Count + 1
		end
	end
	Body[#Body + 1] = "</table>"
	if (Count == 0) then Body = { "{lightGray}No domains yet.{/}" } end
	return Page(200, "Directory", Body)
end

------------------------------------------------------------------------
-- Owner pages
------------------------------------------------------------------------

function Domains.Manage(Entry, Token, Message, Colour)
	local Domain = Entry.Domain
	local Used, Capacity = Storage.Usage(Entry)
	local Files = Storage.Files(Entry)
	local Routes, PageList, Conflicts = Storage.Routes(Entry)
	local PageOf = {}
	for _, Info in ipairs(PageList) do PageOf[Info.Path] = Info end

	local Body = {}
	Notice(Body, Message, Colour)
	Append(Body, {
		"<p>",
		"Domain:  {yellow}" .. E(Domain) .. "{/}" .. (Entry.Meta.Suspended and "  {red}(suspended by the admin){/}" or ""),
		"Storage: " .. Pages.Bar(Used, Capacity, 16) .. " " .. Storage.FormatSize(Used) .. " of " .. Storage.FormatSize(Capacity),
		"</p>",
		"<br/>",
		"<table header-color=\"gray\" text-color=\"white\">",
		"| File | Size | Location | |",
		"|---|---:|---|---|"
	})
	for _, File in ipairs(Files) do
		local Info = PageOf[File.Path]
		local Location = Info and (Info.Location and E(Info.Location) or "{red}no location{/}") or ""
		local Delete = Pages.Link("Delete", Url("delete", { domain = Domain, token = Token, path = File.Path }))
		Body[#Body + 1] = "| " .. Pages.Link(File.Path, "ccmd://" .. Domain .. File.Path) .. " | " .. Storage.FormatSize(File.Size) .. " | " .. Location .. " | " .. Delete .. " |"
	end
	Body[#Body + 1] = "</table>"
	if (#Files == 0) then Body[#Body + 1] = "{lightGray}No files yet.{/}" end
	if (#Conflicts > 0) then
		Body[#Body + 1] = "{orange}More than one page uses: " .. E(table.concat(Conflicts, ", ")) .. "{/}"
	end
	Append(Body, {
		"<br/>",
		"{lightGray}Upload a file or a whole folder (pages need front matter):{/}",
		"<form action=\"domain://upload\" method=\"POST\">"
	})
	Append(Body, Hidden(Domain, Token))
	Append(Body, {
		"<input type=\"file\" name=\"files\" label=\"Files: \" width=\"24\" placeholder=\"Choose a file or folder\"/>",
		"<input type=\"text\" name=\"folder\" label=\"Folder:\" width=\"24\" value=\"/\"/>",
		"<button text=\"Upload\" color=\"green\" text-color=\"white\"/>",
		"</form>",
		"<br/>",
		Pages.Link("Release this domain", Url("release", { domain = Domain, token = Token }))
	})
	return Page(200, "Manage " .. Domain, Body, OwnerBar(Domain, Token))
end

-- Finds the domain and checks the token or password. Returns the entry and token, or nil and an error response.
local function Authorize(Fields, Sender)
	local Domain = type(Fields.domain) == "string" and Fields.domain:lower() or ""
	local Entry = Storage.Get(Domain)
	if (type(Fields.token) == "string" and Entry and Auth.Session(Fields.token, Domain)) then
		return Entry, Fields.token
	end
	if (type(Fields.password) == "string" and Fields.password ~= "") then
		local Allowed, Wait = Auth.Allowed(Sender)
		if (not Allowed) then
			return nil, nil, Domains.Home("Too many wrong passwords. Wait " .. Wait .. " seconds.", "red", 429)
		end
		if (Entry and Auth.Check(Fields.password, Entry.Meta.Salt, Entry.Meta.Hash)) then
			Auth.Succeed(Sender)
			return Entry, Auth.NewSession(Domain)
		end
		Auth.Fail(Sender)
		return nil, nil, Domains.Home("Wrong domain or password.", "red", 403)
	end
	return nil, nil, Domains.Home("Your session has ended. Sign in again.", "orange", 403)
end

local function Register(Fields, Sender)
	if (not Config.Values.Registration) then return Domains.RegisterForm(nil, Fields, 403) end
	local Domain = type(Fields.domain) == "string" and Fields.domain:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
	local Valid, Problem = Storage.ValidDomain(Domain)
	if (not Valid) then return Domains.RegisterForm(Problem, Fields, 400) end
	if (Storage.Get(Domain)) then return Domains.RegisterForm(Domain .. " is already taken.", Fields, 409) end
	local Password = type(Fields.password) == "string" and Fields.password or ""
	if (#Password < 4) then return Domains.RegisterForm("Passwords need at least 4 characters.", Fields, 400) end
	if (Password ~= Fields.confirm) then return Domains.RegisterForm("The passwords do not match.", Fields, 400) end
	local Salt = Auth.Salt()
	local Entry, CreateProblem = Storage.Create(Domain, Salt, Auth.Hash(Password, Salt))
	if (not Entry) then
		local Status = Storage.FirstBlank() and 500 or 507
		return Domains.RegisterForm(CreateProblem, Fields, Status)
	end
	return Domains.Manage(Entry, Auth.NewSession(Domain), "Registered " .. Domain .. "! Upload your pages below.")
end

local function Upload(Entry, Token, Fields)
	local Result, Problem = Storage.Upload(Entry, Fields.files, type(Fields.folder) == "string" and Fields.folder or "/")
	if (not Result) then return Domains.Manage(Entry, Token, Problem, "red") end
	local Message = "Uploaded " .. #Result.Written .. (#Result.Written == 1 and " file." or " files.")
	if (#Result.Warnings > 0) then Message = Message .. "\n" .. table.concat(Result.Warnings, "\n") end
	return Domains.Manage(Entry, Token, Message, #Result.Warnings > 0 and "orange" or "lime")
end

local function DeleteConfirm(Entry, Token, Path)
	local Body = {
		"<p>",
		"Delete {yellow}" .. E(Path) .. "{/} from " .. E(Entry.Domain) .. "?",
		"</p>",
		"<form action=\"domain://delete\" method=\"POST\">"
	}
	Append(Body, Hidden(Entry.Domain, Token))
	Append(Body, {
		"<input type=\"hidden\" name=\"path\" value=\"" .. A(Path) .. "\"/>",
		"<button text=\"Delete\" color=\"red\" text-color=\"white\"/>",
		"</form>",
		Pages.Link("Cancel", Url("manage", { domain = Entry.Domain, token = Token }))
	})
	return Page(200, "Delete file", Body, OwnerBar(Entry.Domain, Token))
end

local function PasswordForm(Entry, Token, Message, Status)
	local Body = {}
	Notice(Body, Message, "red")
	Body[#Body + 1] = "<form action=\"domain://password\" method=\"POST\">"
	Append(Body, Hidden(Entry.Domain, Token))
	Append(Body, {
		"<input type=\"password\" name=\"old\" label=\"Current:\" width=\"24\"/>",
		"<input type=\"password\" name=\"new\" label=\"New:    \" width=\"24\"/>",
		"<input type=\"password\" name=\"confirm\" label=\"Confirm:\" width=\"24\"/>",
		"<button text=\"Change password\" color=\"blue\" text-color=\"white\"/>",
		"</form>"
	})
	return Page(Status or 200, "Change password", Body, OwnerBar(Entry.Domain, Token))
end

local function ReleaseForm(Entry, Token, Message, Status)
	local Body = {}
	Notice(Body, Message, "red")
	Append(Body, {
		"<p>",
		"{red}This deletes every file of " .. E(Entry.Domain) .. "{/} and frees the name.",
		"Type your password to confirm.",
		"</p>",
		"<form action=\"domain://release\" method=\"POST\">"
	})
	Append(Body, Hidden(Entry.Domain, Token))
	Append(Body, {
		"<input type=\"password\" name=\"password\" label=\"Password:\" width=\"24\"/>",
		"<button text=\"Release domain\" color=\"red\" text-color=\"white\"/>",
		"</form>"
	})
	return Page(Status or 200, "Release " .. Entry.Domain, Body, OwnerBar(Entry.Domain, Token))
end

local function Submissions(Entry, Token, Message)
	local Body = {}
	Notice(Body, Message)
	local List = Storage.Submissions(Entry)
	if (#List == 0) then
		Body[#Body + 1] = "{lightGray}Nobody has sent a form to this site yet.{/}"
	end
	for _, Form in ipairs(List) do
		Body[#Body + 1] = "{yellow}" .. E(Form.Form) .. "{/} (" .. #Form.Entries .. ")"
		Body[#Body + 1] = "<table header-color=\"gray\" text-color=\"white\">"
		Body[#Body + 1] = "| Time | From | Fields |"
		Body[#Body + 1] = "|---|---|---|"
		for Index = #Form.Entries, math.max(1, #Form.Entries - 49), -1 do
			local Item = Form.Entries[Index]
			local Parts = {}
			local Keys = {}
			for Key in pairs(Item.Fields or {}) do Keys[#Keys + 1] = Key end
			table.sort(Keys)
			for _, Key in ipairs(Keys) do Parts[#Parts + 1] = Key .. "=" .. tostring(Item.Fields[Key]) end
			Body[#Body + 1] = "| " .. E(Item.Time or "") .. " | #" .. E(Item.Sender or "?") .. " | " .. E(table.concat(Parts, ", ")):gsub("|", "\\|") .. " |"
		end
		Body[#Body + 1] = "</table>"
		Body[#Body + 1] = "<br/>"
	end
	if (#List > 0) then
		Body[#Body + 1] = "<form action=\"domain://submissions\" method=\"POST\">"
		Append(Body, Hidden(Entry.Domain, Token))
		Body[#Body + 1] = "<button text=\"Clear all\" name=\"clear\" value=\"yes\" color=\"red\" text-color=\"white\"/>"
		Body[#Body + 1] = "</form>"
	end
	return Page(200, "Form submissions", Body, OwnerBar(Entry.Domain, Token))
end

------------------------------------------------------------------------
-- Dispatch
------------------------------------------------------------------------

local OwnerPages = {
	manage = function(Entry, Token, Fields, Method)
		return Domains.Manage(Entry, Token)
	end,
	upload = function(Entry, Token, Fields, Method)
		if (Method ~= "POST") then return Domains.Manage(Entry, Token) end
		return Upload(Entry, Token, Fields)
	end,
	delete = function(Entry, Token, Fields, Method)
		local Path = type(Fields.path) == "string" and Fields.path or ""
		if (Method ~= "POST") then return DeleteConfirm(Entry, Token, Path) end
		local Ok, Problem = Storage.Delete(Entry, Path)
		if (not Ok) then return Domains.Manage(Entry, Token, Problem, "red") end
		return Domains.Manage(Entry, Token, "Deleted " .. Path .. ".")
	end,
	password = function(Entry, Token, Fields, Method)
		if (Method ~= "POST") then return PasswordForm(Entry, Token) end
		if (not Auth.Check(Fields.old, Entry.Meta.Salt, Entry.Meta.Hash)) then return PasswordForm(Entry, Token, "The current password is wrong.", 403) end
		if (type(Fields.new) ~= "string" or #Fields.new < 4) then return PasswordForm(Entry, Token, "Passwords need at least 4 characters.", 400) end
		if (Fields.new ~= Fields.confirm) then return PasswordForm(Entry, Token, "The new passwords do not match.", 400) end
		local Salt = Auth.Salt()
		Storage.SetPassword(Entry, Salt, Auth.Hash(Fields.new, Salt))
		Auth.EndDomainSessions(Entry.Domain)
		return Domains.Manage(Entry, Auth.NewSession(Entry.Domain), "Password changed.")
	end,
	release = function(Entry, Token, Fields, Method, Sender)
		if (Method ~= "POST") then return ReleaseForm(Entry, Token) end
		if (not Auth.Check(Fields.password, Entry.Meta.Salt, Entry.Meta.Hash)) then return ReleaseForm(Entry, Token, "Wrong password.", 403) end
		local Domain = Entry.Domain
		Auth.EndDomainSessions(Domain)
		Storage.Release(Entry)
		return Domains.Home(Domain .. " was released.", "lime")
	end,
	submissions = function(Entry, Token, Fields, Method)
		if (Method == "POST" and Fields.clear) then
			Storage.ClearSubmissions(Entry)
			return Submissions(Entry, Token, "Cleared.")
		end
		return Submissions(Entry, Token)
	end
}

-- Handles a domain:// request. Fields come from the POST body or, for GET, the query string.
function Domains.Handle(Method, Parsed, Body, Sender)
	local Name = Parsed.Host ~= "" and Parsed.Host or "home"
	local Fields = {}
	for Key, Value in pairs(Parsed.Params) do Fields[Key] = Value end
	if (Method == "POST" and type(Body) == "table") then
		for Key, Value in pairs(Body) do Fields[Key] = Value end
	end

	if (Name == "home") then return Domains.Home() end
	if (Name == "directory") then return Domains.Directory() end
	if (Name == "register") then
		if (Method == "POST") then return Register(Fields, Sender) end
		return Domains.RegisterForm()
	end
	if (Name == "login") then
		if (Method ~= "POST") then return Domains.Home() end
		local Entry, Token, Problem = Authorize({ domain = Fields.domain, password = Fields.password or "" }, Sender)
		if (not Entry) then
			if (type(Fields.password) ~= "string" or Fields.password == "") then return Domains.Home("Enter your password.", "red", 400) end
			return Problem
		end
		return Domains.Manage(Entry, Token, "Signed in.")
	end
	if (Name == "logout") then
		Auth.EndSession(Fields.token)
		return Domains.Home("Signed out.")
	end
	local Handler = OwnerPages[Name]
	if (not Handler) then return Pages.Error(404, "Not found", "domain://" .. Name .. " does not exist.") end
	local Entry, Token, Problem = Authorize(Fields, Sender)
	if (not Entry) then return Problem end
	return Handler(Entry, Token, Fields, Method, Sender)
end

return Domains
