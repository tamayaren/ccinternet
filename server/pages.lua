-- Builds the .ccmd pages the server generates itself (errors and domain:// pages).

local Ccmd = require("lib.ccmd")

local Pages = {}

Pages.Escape = Ccmd.Escape
Pages.Attribute = Ccmd.Attribute

local function OneLine(Text)
	return (tostring(Text or ""):gsub("[\r\n]", " "))
end

-- Joins a front matter block, an optional topbar and the body lines into page source.
function Pages.Document(Title, Location, Body, Options)
	Options = Options or {}
	local Lines = { "--", "title: " .. OneLine(Title), "location: " .. OneLine(Location) }
	if (Options.Background) then Lines[#Lines + 1] = "background: " .. Options.Background end
	if (Options.TextColor) then Lines[#Lines + 1] = "text-color: " .. Options.TextColor end
	Lines[#Lines + 1] = "--"
	if (Options.Topbar) then
		Lines[#Lines + 1] = "<topbar color=\"" .. (Options.TopbarColor or "blue") .. "\" text-color=\"white\" layout=\"horizontal\">"
		for _, Item in ipairs(Options.Topbar) do Lines[#Lines + 1] = Item end
		Lines[#Lines + 1] = "</topbar>"
	end
	for _, Line in ipairs(type(Body) == "table" and Body or { Body }) do Lines[#Lines + 1] = Line end
	return table.concat(Lines, "\n") .. "\n"
end

function Pages.Link(Text, Href)
	local Label = Ccmd.Escape((tostring(Text):gsub("[%[%]]", "")))
	local Target = tostring(Href):gsub("[%)%s]", "")
	return "[" .. Label .. "](" .. Target .. ")"
end

function Pages.Response(Status, Source, Headers)
	Headers = Headers or {}
	Headers["Content-Type"] = Headers["Content-Type"] or "text/ccmd"
	return { Status = Status, Headers = Headers, Body = Source }
end

function Pages.Redirect(Url, Status)
	return { Status = Status or 303, Headers = { Location = Url }, Body = nil }
end

-- A centred message page used for errors and confirmations.
function Pages.Message(Status, Title, Message, Links, Colour)
	local Body = {
		"<br/>",
		"<p alignment=\"center\">",
		"{" .. (Colour or (Status >= 400 and "red" or "lime")) .. "}" .. Ccmd.Escape(Title) .. "{/}",
		"</p>",
		"<br/>",
		"<p alignment=\"center\">",
		Ccmd.Escape(Message or ""),
		"</p>"
	}
	if (Links and #Links > 0) then
		Body[#Body + 1] = "<br/>"
		Body[#Body + 1] = "<p alignment=\"center\">"
		local Items = {}
		for _, Link in ipairs(Links) do Items[#Items + 1] = Pages.Link(Link[1], Link[2]) end
		Body[#Body + 1] = table.concat(Items, "   ")
		Body[#Body + 1] = "</p>"
	end
	return Pages.Response(Status, Pages.Document(Title, "/", Body))
end

function Pages.Error(Status, Title, Message, Links)
	return Pages.Message(Status, Title, Message, Links or { { "domain://", "domain://" } })
end

-- A text bar such as {lime}######{/}{gray}----{/} for storage use.
function Pages.Bar(Used, Capacity, Width)
	Width = Width or 20
	local Filled = Capacity > 0 and math.floor(Used / Capacity * Width + 0.5) or 0
	Filled = math.max(0, math.min(Width, Filled))
	local Colour = Used / math.max(1, Capacity) > 0.9 and "red" or (Used / math.max(1, Capacity) > 0.7 and "yellow" or "lime")
	return "{" .. Colour .. "}" .. string.rep("#", Filled) .. "{/}{gray}" .. string.rep("-", Width - Filled) .. "{/}"
end

return Pages
