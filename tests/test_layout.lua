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
