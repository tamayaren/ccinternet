local Mock = require("mock")
Mock.Install()
local Ccmd = require("lib.ccmd")

local Source = [[
--
title: Title of page
location: /example1
--
# frontmatter is required.
# Comments use hashtags.

<topbar color="Pink" layout="horizontal" text-color="Black">
[Button Name](ccmd://example.com/example1)
[Other](/other)
</topbar>

<p alignment="center" text-color="White">
First line
Second {red}red{/} and [a link](/x)

After blank
</p>

<table header-color="Black" text-color="White">
| Header | Header1 |
|---|:---:|
| Test1 | Test2 |
| A \| B | [L](/l) |
</table>

<br/>
<img src="/image.nft">
Loose text outside a tag.
\# not a comment
<p>inline <br/> break</p>
<form action="/send" method="post">
<input name="who" label="Name:" width="10" value="Bob"/>
<input type="password" name="pw"/>
<button text="Send" color="green"/>
</form>
<button href="/home">Home</button>
]]

local Doc = Ccmd.Parse(Source)
Equal(#Doc.Errors, 0, "no parse errors " .. table.concat(Doc.Errors, "; "))
Equal(Doc.Title, "Title of page", "title")
Equal(Doc.Location, "/example1", "location")
Check(Doc.Topbar ~= nil, "topbar parsed")
Equal(Doc.Topbar.Color, "6", "topbar pink")
Equal(Doc.Topbar.TextColor, "f", "topbar text black")
Equal(#Doc.Topbar.Items, 2, "two topbar items")
Equal(Doc.Topbar.Items[1][1].Href, "ccmd://example.com/example1", "topbar link href")

local P = Doc.Blocks[1]
Equal(P.Type, "text", "first block is paragraph")
Equal(P.Align, "center", "paragraph alignment")
Equal(#P.Lines, 4, "paragraph keeps the blank line")
Equal(P.Lines[2][2].Fg, "e", "inline red")
Equal(P.Lines[2][4].Href, "/x", "inline link")

local T = Doc.Blocks[2]
Equal(T.Type, "table", "table block")
Equal(T.Columns, 2, "two columns")
Equal(T.Align[2], "center", "column alignment")
Equal(#T.Rows, 2, "two body rows")
Equal(T.Rows[2][1][1].Text, "A | B", "escaped pipe")
Equal(T.Rows[2][2][1].Href, "/l", "link in a cell")

Equal(Doc.Blocks[3].Type, "break", "br")
Equal(Doc.Blocks[4].Type, "image", "img")
Equal(Doc.Blocks[4].Src, "/image.nft", "img src")
Equal(Doc.Blocks[5].Type, "text", "loose text")
Equal(Doc.Blocks[5].Lines[2][1].Text, "# not a comment", "escaped hash")
Equal(#Doc.Blocks[6].Lines, 2, "inline br in p")
local Form = Doc.Blocks[7]
Equal(Form.Type, "form", "form block")
Equal(Form.Method, "POST", "form method")
Equal(#Form.Blocks, 3, "form children")
Equal(#Doc.Inputs, 2, "two inputs")
Equal(Doc.Inputs[2].Kind, "password", "password input")
Equal(Doc.Blocks[8].Type, "button", "link button")
Equal(Doc.Blocks[8].Text, "Home", "button inner text")
Equal(Doc.Blocks[8].Href, "/home", "button href")

local Fields = Ccmd.FormFields(Doc, 1, { [2] = "secret" }, Form.Blocks[3])
Equal(Fields.who, "Bob", "default field value")
Equal(Fields.pw, "secret", "typed field value")

-- Missing front matter is reported but still renders.
local Bad = Ccmd.Parse("Hello")
Check(#Bad.Errors > 0, "missing front matter reported")
Equal(Bad.Blocks[1].Lines[1][1].Text, "Hello", "body still parsed")

local _, _, Problem = Ccmd.ParseFrontMatter("--\ntitle: x\n--\n")
Check(Problem and Problem:match("location"), "location required")

-- Escape round trip.
local Escaped = Ccmd.Escape("[a](b) {red} <p> # x")
local Spans = Ccmd.ParseInline(Escaped)
Equal(#Spans, 1, "escaped text is one span")
Equal(Spans[1].Text, "[a](b) {red} <p> # x", "escape round trip")

-- Colours.
Equal(Ccmd.Colour("Light Blue"), "3", "light blue")
Equal(Ccmd.Colour("lightGray"), "8", "lightGray")
Equal(Ccmd.Colour("nope"), nil, "unknown colour")
local On = Ccmd.ParseInline("{white on red}alert{/} ok")
Equal(On[1].Fg, "0", "fg of on-span")
Equal(On[1].Bg, "e", "bg of on-span")
Equal(On[2].Fg, nil, "style ends")
