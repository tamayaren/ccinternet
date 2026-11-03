local Mock = require("mock")
Mock.Install()
local Ccmd = require("lib.ccmd")
local Layout = require("lib.layout")
local Image = require("lib.image")

local Source = [[
--
title: Layout test
location: /
--
<topbar color="pink" text-color="black">
[Home](/) [About](/about)
[A much longer link label](/long)
</topbar>
<p alignment="center">
Centered text
</p>
<p alignment="right">
Right
</p>
This is a long line of loose text that has to wrap onto more than one row of the screen.
<table header-color="gray">
| Name | Value |
|---|---:|
| alpha | 1 |
| a very long cell value that needs wrapping inside its column | 22 |
</table>
<img src="/logo.nft" alt="logo">
<form>
<input name="q" label="Search:" width="12" placeholder="type here"/>
<button text="Go" align="center"/>
</form>
]]

local Doc = Ccmd.Parse(Source)
Equal(#Doc.Errors, 0, "no errors")
local Nft = "\30e\31f AB \30b\31a CD\n\30d\31f E\n"
local Logo = Image.Parse(Nft, "nft")
Equal(Logo.W, 7, "nft width")
Equal(Logo.H, 2, "nft height")
Equal(Logo.Rows[1][3], "eeeebbb", "nft background colours")

local Page = Layout.Build(Doc, 40, 15, { Images = function(Src) return Src == "/logo.nft" and Logo or nil end })
Equal(Page.Bar.Side, "top", "horizontal bar on top")
Equal(Page.ViewY, Page.Bar.Size + 1, "content starts under the bar")
for _, Row in ipairs(Page.Rows) do
	Equal(#Row[1], Page.ViewW, "row width")
	Check(#Row[1] == #Row[2] and #Row[2] == #Row[3], "blit lengths match")
end

local Screen = Mock.NewTerm(40, 15)
Layout.Draw(Page, Screen, 0)
print(Screen.Dump())
print(("-"):rep(40))
Layout.Draw(Page, Screen, Page.MaxScroll)
print(Screen.Dump())

-- Bar links are clickable.
local Hit = Layout.Hit(Page, 3, 1, 0)
Check(Hit and Hit.Href == "/", "home link in bar")
-- Content link regions: the input is somewhere in the rows.
local InputRegion = Layout.InputRegion(Page, 1)
Check(InputRegion ~= nil, "input region")
local X, Y = Layout.RegionPosition(Page, InputRegion, Page.MaxScroll)
local Found = Layout.Hit(Page, X, Y, Page.MaxScroll)
Check(Found and Found.Kind == "input", "hit test finds the input")

-- Vertical bar.
local Side = Ccmd.Parse("--\ntitle: x\nlocation: /\n--\n<topbar layout=\"vertical\" color=\"blue\">\n[One](/1)\n[Two](/2)\n</topbar>\nHello world")
local SidePage = Layout.Build(Side, 30, 10)
Equal(SidePage.Bar.Side, "left", "vertical bar on the left")
Equal(SidePage.ViewX, SidePage.Bar.Size + 1, "content right of the bar")
local SideHit = Layout.Hit(SidePage, 2, 3, 0)
Check(SideHit and SideHit.Href == "/2", "second sidebar link")
local SideScreen = Mock.NewTerm(30, 10)
Layout.Draw(SidePage, SideScreen, 0)
print(("-"):rep(30))
print(SideScreen.Dump())

-- Text wraps at word boundaries.
local Long = Ccmd.Parse("--\ntitle: x\nlocation: /\n--\nalpha beta gamma delta")
local LongPage = Layout.Build(Long, 11, 5)
Equal(LongPage.Rows[1][1], "alpha beta ", "wrap row 1")
Equal(LongPage.Rows[2][1], "gamma delta", "wrap row 2")

-- bimg and nfp images.
local Bimg = Image.Parse(textutils.serialise({ { { "hi", "01", "ef" } } }), "bimg")
Equal(Bimg and Bimg.Rows[1][1], "hi", "bimg text")
local Nfp = Image.Parse("e b\n", "nfp")
Equal(Nfp.Rows[1][3], "e b", "nfp keeps transparency as a space")

-- Footer, aligned inputs, inline buttons and vertical alignment.
local Extras = Ccmd.Parse([[
--
title: x
location: /
vertical-alignment: bottom
--
<form>
<input name="q" width="10" alignment="right"/>
<button text="One" alignment="center"/>
<button text="Two" inline/>
<button text="Three" inline="true"/>
<button text="Four"/>
</form>
<footer color="blue" text-color="white" alignment="right">
[About](/about)
Footer text
</footer>
]])
Equal(#Extras.Errors, 0, "extras parse")
Equal(Extras.VerticalAlign, "bottom", "vertical alignment")
Equal(Extras.Footer.Align, "right", "footer alignment")
Equal(Extras.Footer.Color, "b", "footer colour")
Equal(Extras.Inputs[1].Align, "right", "input alignment")
local ExtrasPage = Layout.Build(Extras, 30, 10)
Equal(ExtrasPage.Footer.Size, 1, "footer rows")
Equal(ExtrasPage.ViewH, 9, "footer takes the last row")
Equal(ExtrasPage.FooterY, 10, "footer position")
Equal(ExtrasPage.Footer.Rows[1][1], "           About  Footer text ", "footer aligned right with a margin")
Equal(ExtrasPage.Footer.Rows[1][3], string.rep("b", 30), "footer background")
local AboutHit = Layout.Hit(ExtrasPage, 13, 10, 0)
Check(AboutHit and AboutHit.Href == "/about", "footer link clickable")
Equal(Layout.Hit(ExtrasPage, 2, 10, 0), nil, "footer outside links")
local Field = Layout.InputRegion(ExtrasPage, 1)
Equal(Field.X1, 21, "right-aligned input")
Equal(Field.X2, 30, "right-aligned input end")
Equal(#ExtrasPage.Rows, 9, "content fills the area")
Equal(ExtrasPage.Rows[6][1], string.rep(" ", 30), "pushed to the bottom")
Equal(ExtrasPage.Rows[8][1], "     One    Two    Three      ", "inline buttons share a centred row")
Equal(ExtrasPage.Rows[9][1], " Four" .. string.rep(" ", 25), "a button without inline starts a row")
local TwoHit = Layout.Hit(ExtrasPage, 13, 8, 0)
Check(TwoHit and TwoHit.Kind == "button" and TwoHit.Button.Text == "Two", "inline button clickable")
-- Narrow: inline buttons wrap, each row centred.
local Narrow = Layout.Build(Extras, 12, 10)
local Found = {}
for _, Row in ipairs(Narrow.Rows) do
	if (Row[1]:find("%S")) then Found[#Found + 1] = Row[1] end
end
Equal(Found[1], " One    Two ", "first button row")
Equal(Found[2], "   Three    ", "wrapped button row")
Equal(Found[3], " Four       ", "next button row")
-- Footer under a sidebar.
local Both = Ccmd.Parse("--\ntitle: x\nlocation: /\n--\n<topbar layout=\"vertical\">\n[A](/a)\n</topbar>\n<footer>\nF\n</footer>\nHi")
local BothPage = Layout.Build(Both, 20, 8)
Equal(#BothPage.Bar.Rows, 7, "sidebar stops above the footer")
Equal(BothPage.ViewH, 7, "content above the footer")
local BothScreen = Mock.NewTerm(20, 8)
Layout.Draw(BothPage, BothScreen, 0)
Equal(BothScreen.State.Text[8], " F                  ", "footer drawn on the last row")
