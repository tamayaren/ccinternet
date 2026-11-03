-- cc.net: the search engine and home page of the network, served from the cc.net disk in the
-- search drive (right of the core by default).
--
--   ccmd://cc.net/                     home page: logo, search bar, Search and I'm Feeling Blocky
--   ccmd://cc.net/search?q=...         results (page=N for more)
--   ccmd://cc.net/search?q=...&blocky=1  goes straight to the best result (a random site without q)
--
-- The index keeps the title, location, some text and the words of every page of every domain.
-- It is rebuilt per domain when that domain's files change, and saved on the cc.net disk so a
-- restarted core does not have to read every floppy again.

local Ccmd = require("lib.ccmd")
local Protocol = require("lib.protocol")
local Storage = require("server.storage")
local Config = require("server.config")
local Pages = require("server.pages")

local Search = {}

Search.Host = "cc.net"
Search.IndexFile = "index.db"
Search.PerPage = 6         -- results per page
Search.MaxTerms = 8        -- words of a query that are used
Search.MaxPages = 40       -- pages indexed per domain
Search.MaxWords = 200      -- different words kept per page
Search.TextLength = 400    -- characters of page text kept for snippets
Search.SnippetLength = 100

Search.SaveProblem = nil   -- why the index could not be saved on the disk, if it could not

local E = Ccmd.Escape
local A = Ccmd.Attribute

local Index = {}       -- domain -> { Stamp, Signature, Pages = { { Location, Title, Text, Words } } }
local LoadedDisk = nil -- which disk the index was loaded from ("mount:id")

------------------------------------------------------------------------
-- Indexing
------------------------------------------------------------------------

local function Collapse(Text)
	return (Text:gsub("[%c%s]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function SpansText(Spans, Into)
	for _, Span in ipairs(Spans or {}) do Into[#Into + 1] = Span.Text end
	Into[#Into + 1] = " "
end

-- The visible text of a parsed page, without its topbar and footer.
function Search.DocumentText(Doc)
	local Parts = {}
	local function Walk(Blocks)
		for _, Block in ipairs(Blocks) do
			if (Block.Type == "text") then
				for _, Line in ipairs(Block.Lines) do SpansText(Line, Parts) end
			elseif (Block.Type == "table") then
				if (Block.Header) then
					for _, Cell in ipairs(Block.Header) do SpansText(Cell, Parts) end
				end
				for _, Row in ipairs(Block.Rows) do
					for _, Cell in ipairs(Row) do SpansText(Cell, Parts) end
				end
			elseif (Block.Type == "button") then
				Parts[#Parts + 1] = Block.Text .. " "
			elseif (Block.Type == "image" and Block.Alt) then
				Parts[#Parts + 1] = Block.Alt .. " "
			elseif (Block.Type == "form") then
				Walk(Block.Blocks)
			end
		end
	end
	Walk(Doc.Blocks)
	return Collapse(table.concat(Parts))
end

-- Lower-case words of a text, each once, as " one two three " so lookups are plain finds.
local function WordList(Text, Limit)
	local Seen, List = {}, {}
	for Word in Text:lower():gmatch("%w+") do
		if (#Word >= 2 and #Word <= 24 and not Seen[Word]) then
			Seen[Word] = true
			List[#List + 1] = Word
			if (#List >= Limit) then break end
		end
	end
	return " " .. table.concat(List, " ") .. " "
end

-- Changes whenever a file of the site is added, removed or changes size.
local function Signature(Entry)
	local Parts = {}
	for _, File in ipairs(Storage.Files(Entry)) do Parts[#Parts + 1] = File.Path .. ":" .. File.Size end
	return table.concat(Parts, ";")
end

local function IndexDomain(Entry)
	local _, PageList = Storage.Routes(Entry)
	local Result = {}
	for _, Info in ipairs(PageList) do
		if (Info.Location and not Info.Error and Info.Location ~= "/404") then
			local Data = Storage.Read(Entry, Info.Path)
			if (Data) then
				local Doc = Ccmd.Parse(Data)
				local Text = Search.DocumentText(Doc)
				local Title = Collapse(Info.Title or Info.Location)
				Result[#Result + 1] = {
					Location = Info.Location,
					Title = Title,
					Text = Text:sub(1, Search.TextLength),
					Words = WordList(Title .. " " .. Info.Location:gsub("[/%-_%.]", " ") .. " " .. Text, Search.MaxWords)
				}
			end
		end
	end
	table.sort(Result, function(First, Second) return First.Location < Second.Location end)
	while (#Result > Search.MaxPages) do Result[#Result] = nil end
	return Result
end

local function IndexPath()
	return fs.combine(Storage.SearchDrive.Mount, Search.IndexFile)
end

local function Load()
	local Drive = Storage.SearchDrive
	local Key = Drive.Mount .. ":" .. tostring(Drive.DiskId)
	if (LoadedDisk == Key) then return end
	LoadedDisk = Key
	Index = {}
	local Data = Storage.ReadFile(IndexPath())
	local Saved = Data and textutils.unserialise(Data)
	if (type(Saved) ~= "table" or type(Saved.Domains) ~= "table") then return end
	for Domain, Item in pairs(Saved.Domains) do
		if (type(Domain) == "string" and type(Item) == "table" and type(Item.Signature) == "string" and type(Item.Pages) == "table") then
			local Clean = {}
			for _, Page in ipairs(Item.Pages) do
				if (type(Page) == "table" and type(Page.Location) == "string" and type(Page.Title) == "string" and type(Page.Text) == "string" and type(Page.Words) == "string") then
					Clean[#Clean + 1] = { Location = Page.Location, Title = Page.Title, Text = Page.Text, Words = Page.Words }
				end
			end
			Index[Domain] = { Signature = Item.Signature, Pages = Clean }
		end
	end
end

local function Save()
	local Domains = {}
	for Domain, Item in pairs(Index) do Domains[Domain] = { Signature = Item.Signature, Pages = Item.Pages } end
	local Data = textutils.serialise({ Version = 1, Domains = Domains })
	local Path = IndexPath()
	local Old = fs.exists(Path) and fs.getSize(Path) or 0
	local Free = fs.getFreeSpace(Storage.SearchDrive.Mount)
	if (type(Free) == "number" and math.max(#Data, Storage.FileOverhead) > Free + math.max(Old, Storage.FileOverhead)) then
		-- Too big for the floppy: searching still works from memory, it just is not kept.
		if (fs.exists(Path)) then fs.delete(Path) end
		Search.SaveProblem = "The index (" .. Storage.FormatSize(#Data) .. ") does not fit on the cc.net disk"
		return
	end
	local Ok, Problem = Storage.WriteFile(Path, Data)
	Search.SaveProblem = (not Ok) and tostring(Problem) or nil
end

-- Brings the index up to date with the cluster. Only domains whose files changed are read again.
function Search.Refresh()
	if (not Storage.SearchReady()) then return false end
	Load()
	local Fresh = {}
	local Changed = false
	for Domain, Entry in pairs(Storage.Domains) do
		local Stamp = Storage.SiteStamp(Domain)
		local Old = Index[Domain]
		if (Old and Old.Stamp == Stamp) then
			Fresh[Domain] = Old
		else
			local Current = Signature(Entry)
			if (Old and Old.Signature == Current) then
				Old.Stamp = Stamp
				Fresh[Domain] = Old
			else
				Fresh[Domain] = { Stamp = Stamp, Signature = Current, Pages = IndexDomain(Entry) }
				Changed = true
			end
		end
	end
	for Domain in pairs(Index) do
		if (not Fresh[Domain]) then Changed = true end
	end
	Index = Fresh
	if (Changed) then Save() end
	return true
end

-- Domains visitors can see (suspended ones are left out).
function Search.Sites()
	local List = {}
	for _, Domain in ipairs(Storage.DomainList()) do
		if (not Storage.Domains[Domain].Meta.Suspended) then List[#List + 1] = Domain end
	end
	return List
end

-- Number of pages in the index.
function Search.PageCount()
	local Count = 0
	for _, Item in pairs(Index) do Count = Count + #Item.Pages end
	return Count
end

------------------------------------------------------------------------
-- Searching
------------------------------------------------------------------------

-- Splits a query into terms: { Text = "my-site.com", Words = { "my", "site", "com" } }.
function Search.Terms(Query)
	local Terms = {}
	for Raw in tostring(Query or ""):lower():gmatch("%S+") do
		local Text = Raw:gsub("[^%w%.%-]", "")
		if (Text ~= "") then
			local Words = {}
			for Word in Text:gmatch("%w+") do Words[#Words + 1] = Word end
			Terms[#Terms + 1] = { Text = Text, Words = Words }
			if (#Terms >= Search.MaxTerms) then break end
		end
	end
	return Terms
end

local function Score(Domain, Page, Terms)
	local Total, Matched = 0, 0
	local Title = Page.Title:lower()
	local Location = Page.Location:lower()
	for _, Term in ipairs(Terms) do
		local Points = 0
		if (Domain == Term.Text) then
			Points = Points + 60
		elseif (Domain:find(Term.Text, 1, true)) then
			Points = Points + 25
		end
		if (Title:find(Term.Text, 1, true)) then Points = Points + 15 end
		if (Location:find(Term.Text, 1, true)) then Points = Points + 4 end
		for _, Word in ipairs(Term.Words) do
			if (Page.Words:find(" " .. Word .. " ", 1, true)) then
				Points = Points + 6
			elseif (#Word >= 2 and Page.Words:find(" " .. Word, 1, true)) then
				Points = Points + 2
			end
		end
		if (Points > 0) then
			Matched = Matched + 1
			Total = Total + Points
		end
	end
	if (Matched > 0 and Page.Location == "/") then Total = Total + 1 end
	return Matched, Total
end

-- Returns the matching pages, best first: { { Domain, Location, Title, Text, Url, Matched, Score } }.
function Search.Query(Query)
	Search.Refresh()
	local Terms = Search.Terms(Query)
	local Results = {}
	if (#Terms == 0) then return Results, Terms end
	for _, Domain in ipairs(Search.Sites()) do
		local Item = Index[Domain]
		for _, Page in ipairs(Item and Item.Pages or {}) do
			local Matched, Points = Score(Domain, Page, Terms)
			if (Matched > 0) then
				Results[#Results + 1] = {
					Domain = Domain, Location = Page.Location, Title = Page.Title, Text = Page.Text,
					Url = "ccmd://" .. Domain .. Page.Location, Matched = Matched, Score = Points
				}
			end
		end
	end
	table.sort(Results, function(First, Second)
		if (First.Matched ~= Second.Matched) then return First.Matched > Second.Matched end
		if (First.Score ~= Second.Score) then return First.Score > Second.Score end
		if (First.Domain ~= Second.Domain) then return First.Domain < Second.Domain end
		return First.Location < Second.Location
	end)
	return Results, Terms
end

-- A piece of the page text around the first match, with matched words in black.
function Search.Snippet(Text, Terms)
	Text = Text or ""
	if (Text == "") then return "{lightGray}No text on this page.{/}" end
	local Lower = Text:lower()
	local Words = {}
	for _, Term in ipairs(Terms) do
		for _, Word in ipairs(Term.Words) do
			if (#Word >= 2) then Words[#Words + 1] = Word end
		end
	end
	local First
	for _, Word in ipairs(Words) do
		local Found = Lower:find(Word, 1, true)
		if (Found and (not First or Found < First)) then First = Found end
	end
	local Start = 1
	if (First and First > 30) then
		Start = Text:find(" ", First - 30, true) or First
		Start = math.min(Start + 1, First)
	end
	local Piece = Text:sub(Start, Start + Search.SnippetLength - 1)
	local Prefix = Start > 1 and "..." or ""
	local Suffix = Start + Search.SnippetLength - 1 < #Text and "..." or ""
	-- Highlight every match inside the piece.
	local Out = {}
	local PieceLower = Piece:lower()
	local Pos = 1
	while (Pos <= #Piece) do
		local Best, BestEnd
		for _, Word in ipairs(Words) do
			local Found = PieceLower:find(Word, Pos, true)
			if (Found and (not Best or Found < Best or (Found == Best and Found + #Word - 1 > BestEnd))) then
				Best, BestEnd = Found, Found + #Word - 1
			end
		end
		if (not Best) then break end
		Out[#Out + 1] = E(Piece:sub(Pos, Best - 1))
		Out[#Out + 1] = "{black}" .. E(Piece:sub(Best, BestEnd)) .. "{/}"
		Pos = BestEnd + 1
	end
	Out[#Out + 1] = E(Piece:sub(Pos))
	return "{gray}" .. Prefix .. table.concat(Out) .. Suffix .. "{/}"
end

------------------------------------------------------------------------
-- Pages
------------------------------------------------------------------------

-- The big logo: 5 rows of coloured blocks. Each letter is 3 columns wide ("." is 1).
local LogoFont = {
	c = { "###", "#  ", "#  ", "#  ", "###" },
	["."] = { " ", " ", " ", " ", "#" },
	n = { "## ", "# #", "# #", "# #", "# #" },
	e = { "###", "# #", "###", "#  ", "###" },
	t = { " # ", "###", " # ", " # ", " ##" }
}
local LogoText = "cc.net"
local LogoColours = { "blue", "red", "yellow", "blue", "green", "red" }

-- Source lines for the big logo, for a page with the given background colour.
function Search.Logo(Background)
	local Lines = {}
	for Row = 1, 5 do
		local Cells = {}
		for Index = 1, #LogoText do
			local Glyph = LogoFont[LogoText:sub(Index, Index)][Row]
			for Column = 1, #Glyph do
				Cells[#Cells + 1] = Glyph:sub(Column, Column) == "#" and LogoColours[Index] or Background
			end
			if (Index < #LogoText) then Cells[#Cells + 1] = Background end
		end
		-- One span per run of the same colour; spaces with a background colour draw the blocks.
		local Parts = {}
		local Run, Count = Cells[1], 0
		for Index = 1, #Cells + 1 do
			if (Cells[Index] == Run) then
				Count = Count + 1
			else
				Parts[#Parts + 1] = "{" .. Run .. " on " .. Run .. "}" .. string.rep(" ", Count) .. "{/}"
				Run, Count = Cells[Index], 1
			end
		end
		Lines[#Lines + 1] = table.concat(Parts)
	end
	return Lines
end

-- "cc.net" in its colours, each letter a link home.
local function SmallLogo()
	local Parts = {}
	for Index = 1, #LogoText do
		Parts[#Parts + 1] = "{" .. LogoColours[Index] .. "}" .. Pages.Link(LogoText:sub(Index, Index), "ccmd://cc.net/") .. "{/}"
	end
	return table.concat(Parts)
end

local function Plural(Count, One, Many)
	return Count .. " " .. (Count == 1 and One or Many)
end

-- The footer shown on every cc.net page: websites on this server and the server's name.
local function Footer()
	return {
		"<footer color=\"lightGray\" text-color=\"gray\" alignment=\"center\">",
		"{black}" .. Plural(#Search.Sites(), "website", "websites") .. "{/} hosted",
		"Connected to {black}" .. E(Config.Values.Hostname) .. "{/}",
		"</footer>"
	}
end

local function Document(Title, Location, Body, VerticalAlign)
	local Lines = {
		"--",
		"title: " .. Title:gsub("[\r\n]", " "),
		"location: " .. Location,
		"background: white",
		"text-color: black",
		"link-color: blue"
	}
	if (VerticalAlign) then Lines[#Lines + 1] = "vertical-alignment: " .. VerticalAlign end
	Lines[#Lines + 1] = "--"
	for _, Line in ipairs(Body) do Lines[#Lines + 1] = Line end
	for _, Line in ipairs(Footer()) do Lines[#Lines + 1] = Line end
	return table.concat(Lines, "\n") .. "\n"
end

local function SearchForm(Query, Width, Align, Buttons)
	local Lines = {
		"<form action=\"ccmd://cc.net/search\" method=\"GET\">",
		"<input type=\"text\" name=\"q\" width=\"" .. Width .. "\" alignment=\"" .. Align .. "\" value=\"" .. A(Query or "") .. "\" placeholder=\"Search the network\" color=\"lightGray\" text-color=\"black\"/>"
	}
	if (Buttons) then
		Lines[#Lines + 1] = "<br/>"
		Lines[#Lines + 1] = "<button text=\"Search\" alignment=\"" .. Align .. "\" color=\"lightGray\" text-color=\"black\"/>"
		Lines[#Lines + 1] = "<button text=\"I'm Feeling Blocky\" name=\"blocky\" value=\"1\" inline=\"true\" color=\"lightGray\" text-color=\"black\"/>"
	end
	Lines[#Lines + 1] = "</form>"
	return Lines
end

function Search.Home()
	local Body = { "<p alignment=\"center\">" }
	for _, Line in ipairs(Search.Logo("white")) do Body[#Body + 1] = Line end
	Body[#Body + 1] = "</p>"
	Body[#Body + 1] = "<br/>"
	for _, Line in ipairs(SearchForm("", 30, "center", true)) do Body[#Body + 1] = Line end
	return Pages.Response(200, Document("cc.net", "/", Body, "center"))
end

local function ResultsUrl(Query, Page)
	return Protocol.Url("ccmd", Search.Host, "/search", { q = Query, page = Page > 1 and tostring(Page) or nil })
end

function Search.Results(Query, PageNumber)
	local Results, Terms = Search.Query(Query)
	local Total = math.max(1, math.ceil(#Results / Search.PerPage))
	PageNumber = math.max(1, math.min(Total, math.floor(tonumber(PageNumber) or 1)))
	local Body = { "<p>", SmallLogo(), "</p>" }
	for _, Line in ipairs(SearchForm(Query, 40, "left", false)) do Body[#Body + 1] = Line end
	Body[#Body + 1] = "<p text-color=\"gray\">"
	if (#Results == 0) then
		Body[#Body + 1] = "No pages match {black}" .. E(Query) .. "{/}."
		Body[#Body + 1] = ""
		Body[#Body + 1] = "Try other words, or a domain name like example.com."
		Body[#Body + 1] = "</p>"
	else
		local Shown = PageNumber > 1 and ("Page " .. PageNumber .. " of " .. Plural(#Results, "result", "results")) or (Plural(#Results, "result", "results"))
		Body[#Body + 1] = Shown
		Body[#Body + 1] = "</p>"
		for Index = (PageNumber - 1) * Search.PerPage + 1, math.min(#Results, PageNumber * Search.PerPage) do
			local Result = Results[Index]
			Body[#Body + 1] = "<br/>"
			Body[#Body + 1] = "<p>"
			Body[#Body + 1] = "{green}" .. E(Result.Domain .. (Result.Location == "/" and "" or Result.Location)) .. "{/}"
			Body[#Body + 1] = Pages.Link(Result.Title ~= "" and Result.Title or Result.Url, Result.Url)
			Body[#Body + 1] = Search.Snippet(Result.Text, Terms)
			Body[#Body + 1] = "</p>"
		end
		if (Total > 1) then
			local Links = {}
			if (PageNumber > 1) then Links[#Links + 1] = Pages.Link("< Previous", ResultsUrl(Query, PageNumber - 1)) end
			for Number = 1, Total do
				Links[#Links + 1] = Number == PageNumber and ("{black}" .. Number .. "{/}") or Pages.Link(tostring(Number), ResultsUrl(Query, Number))
			end
			if (PageNumber < Total) then Links[#Links + 1] = Pages.Link("Next >", ResultsUrl(Query, PageNumber + 1)) end
			Body[#Body + 1] = "<br/>"
			Body[#Body + 1] = "<p alignment=\"center\">"
			Body[#Body + 1] = table.concat(Links, " ")
			Body[#Body + 1] = "</p>"
		end
	end
	Body[#Body + 1] = "<br/>"
	return Pages.Response(200, Document(Query .. " - cc.net", "/search", Body))
end

function Search.NotFound(Path)
	local Body = {
		"<p alignment=\"center\">",
		SmallLogo(),
		"",
		"{red}404.{/} {gray}That's an error.{/}",
		"",
		"{gray}cc.net" .. E(Path) .. " does not exist.{/}",
		"",
		Pages.Link("Back to search", "ccmd://cc.net/"),
		"</p>"
	}
	return Pages.Response(404, Document("Not found - cc.net", "/404", Body, "center"))
end

-- I'm Feeling Blocky: the best result, or any site when the query is empty.
local function Blocky(Query)
	local Results = Search.Query(Query)
	if (#Results > 0) then return Pages.Redirect(Results[1].Url, 302) end
	if (Query == "") then
		local Sites = Search.Sites()
		if (#Sites > 0) then return Pages.Redirect("ccmd://" .. Sites[math.random(#Sites)] .. "/", 302) end
	end
	return Search.Results(Query, 1)
end

-- Handles a request for ccmd://cc.net/...
function Search.Handle(Method, Url)
	if (not Storage.SearchReady()) then
		-- cc.net is optional: without its disk the home page falls back to domain://.
		if (Url.Path == "/") then return Pages.Redirect("domain://", 302) end
		return Pages.Error(503, "cc.net is offline", "This server has no cc.net disk. The admin can put a floppy in a disk drive on the " .. Storage.SearchSide .. " of the core.", {
			{ "domain://", "domain://" },
			{ "Directory", "domain://directory" }
		})
	end
	if (Method ~= "GET") then return Pages.Error(405, "Not allowed", "cc.net only answers GET requests.", { { "cc.net", "ccmd://cc.net/" } }) end
	if (Url.Path == "/") then return Search.Home() end
	if (Url.Path == "/search") then
		local Query = Collapse(tostring(Url.Params.q or "")):sub(1, 100)
		if (Url.Params.blocky) then return Blocky(Query) end
		if (Query == "") then return Pages.Redirect("ccmd://cc.net/", 302) end
		return Search.Results(Query, Url.Params.page)
	end
	return Search.NotFound(Url.Path)
end

return Search
