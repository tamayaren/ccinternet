-- Small drawing and dialog helpers for the admin screen.

local UI = {}

UI.Regions = {}

local function Colour(Char)
	return 2 ^ tonumber(Char, 16)
end

UI.Colour = Colour

function UI.Size()
	return term.getSize()
end

function UI.Begin()
	UI.Regions = {}
end

function UI.Fit(Text, Width)
	Text = tostring(Text or "")
	if (Width <= 0) then return "" end
	if (#Text > Width) then return Text:sub(1, math.max(0, Width - 1)) .. "\187" end
	return Text .. string.rep(" ", Width - #Text)
end

function UI.Fill(X, Y, W, H, Bg)
	if (W <= 0) then return end
	local Line = string.rep(" ", W)
	local Fg = string.rep("0", W)
	local Back = string.rep(Bg, W)
	for Row = Y, Y + H - 1 do
		term.setCursorPos(X, Row)
		term.blit(Line, Fg, Back)
	end
end

function UI.Text(X, Y, Text, Fg, Bg)
	Text = tostring(Text)
	if (#Text == 0) then return end
	term.setCursorPos(X, Y)
	term.blit(Text, string.rep(Fg, #Text), string.rep(Bg, #Text))
end

-- Registers a clickable area. Button 1 is left click, 2 is right click.
function UI.Region(X1, Y, X2, Action, Right)
	UI.Regions[#UI.Regions + 1] = { X1 = X1, X2 = X2, Y = Y, Action = Action, Right = Right }
end

function UI.Button(X, Y, Label, Fg, Bg, Action)
	local Text = " " .. Label .. " "
	UI.Text(X, Y, Text, Fg, Bg)
	UI.Region(X, Y, X + #Text - 1, Action)
	return #Text
end

function UI.Click(Button, X, Y)
	for Index = #UI.Regions, 1, -1 do
		local Region = UI.Regions[Index]
		if (Region.Y == Y and X >= Region.X1 and X <= Region.X2) then
			if (Button == 2 and Region.Right) then
				Region.Right()
				return true
			elseif (Region.Action) then
				Region.Action(Button)
				return true
			end
		end
	end
	return false
end

-- Draws a centred box and returns its position.
function UI.Box(Title, Lines, Width, Extra)
	local W, H = UI.Size()
	Width = math.min(W - 2, math.max(Width or 0, #Title + 4))
	for _, Line in ipairs(Lines) do Width = math.min(W - 2, math.max(Width, #Line + 4)) end
	local BoxH = #Lines + 3 + (Extra or 0)
	local X = math.floor((W - Width) / 2) + 1
	local Y = math.floor((H - BoxH) / 2) + 1
	UI.Fill(X, Y, Width, 1, "b")
	UI.Text(X + 1, Y, UI.Fit(Title, Width - 2), "0", "b")
	UI.Fill(X, Y + 1, Width, BoxH - 1, "8")
	for Index, Line in ipairs(Lines) do
		UI.Text(X + 2, Y + 1 + Index, UI.Fit(Line, Width - 4), "f", "8")
	end
	return X, Y, Width, BoxH
end

-- Splits text into lines that fit a width.
function UI.Wrap(Text, Width)
	local Lines = {}
	for Paragraph in (tostring(Text) .. "\n"):gmatch("(.-)\n") do
		local Line = ""
		for Word in Paragraph:gmatch("%S+") do
			if (#Line == 0) then
				Line = Word
			elseif (#Line + 1 + #Word <= Width) then
				Line = Line .. " " .. Word
			else
				Lines[#Lines + 1] = Line
				Line = Word
			end
			while (#Line > Width) do
				Lines[#Lines + 1] = Line:sub(1, Width)
				Line = Line:sub(Width + 1)
			end
		end
		Lines[#Lines + 1] = Line
	end
	return Lines
end

-- Reads text in a field. Returns the text (may be empty).
function UI.Read(X, Y, W, Default, Replace)
	local Field = window.create(term.current(), X, Y, W, 1)
	Field.setBackgroundColour(colours.white)
	Field.setTextColour(colours.black)
	Field.clear()
	local Previous = term.redirect(Field)
	local Ok, Result = pcall(read, Replace, nil, nil, Default)
	term.redirect(Previous)
	if (not Ok) then return nil end
	return Result
end

-- Asks for a line of text. Returns the text, or nil when left empty.
function UI.Prompt(Title, Message, Default, Replace)
	local W = UI.Size()
	local Lines = UI.Wrap(Message or "", math.min(W - 6, 40))
	local X, Y, Width, BoxH = UI.Box(Title, Lines, 32, 2)
	local FieldY = Y + BoxH - 2
	UI.Text(X + 2, FieldY + 1, UI.Fit("Enter to confirm, empty to cancel", Width - 4), "7", "8")
	local Value = UI.Read(X + 2, FieldY, Width - 4, Default, Replace)
	if (Value == "") then return nil end
	return Value
end

-- Shows a message until a key or click.
function UI.Alert(Title, Message, Colour_)
	local W = UI.Size()
	local Lines = UI.Wrap(Message or "", math.min(W - 6, 40))
	local X, Y, Width, BoxH = UI.Box(Title, Lines, 24, 1)
	local Label = " OK "
	UI.Text(X + Width - #Label - 2, Y + BoxH - 1, Label, "0", Colour_ or "b")
	while (true) do
		local Event, A = os.pullEventRaw()
		if (Event == "mouse_click" or (Event == "key" and (A == keys.enter or A == keys.space))) then return end
	end
end

-- Asks yes or no. Returns true for yes.
function UI.Confirm(Title, Message, Yes, Danger)
	local W = UI.Size()
	local Lines = UI.Wrap(Message or "", math.min(W - 6, 40))
	local X, Y, Width, BoxH = UI.Box(Title, Lines, 28, 1)
	local YesLabel = " " .. (Yes or "Yes") .. " "
	local NoLabel = " Cancel "
	local ButtonY = Y + BoxH - 1
	local NoX = X + Width - #NoLabel - 2
	local YesX = NoX - #YesLabel - 1
	UI.Text(YesX, ButtonY, YesLabel, "0", Danger and "e" or "d")
	UI.Text(NoX, ButtonY, NoLabel, "0", "7")
	while (true) do
		local Event, A, B, C = os.pullEventRaw()
		if (Event == "mouse_click" and C == ButtonY) then
			if (B >= YesX and B < YesX + #YesLabel) then return true end
			if (B >= NoX and B < NoX + #NoLabel) then return false end
		elseif (Event == "key") then
			if (A == keys.y) then return true end
			if (A == keys.n or A == keys.backspace) then return false end
		end
	end
end

-- Lets the user pick one item from a list. Returns the item or nil.
function UI.Pick(Title, Items)
	local W, H = UI.Size()
	local Width = math.min(W - 4, 36)
	local Visible = math.min(#Items, H - 6)
	local X = math.floor((W - Width) / 2) + 1
	local Y = math.floor((H - Visible - 3) / 2) + 1
	local Scroll = 0
	while (true) do
		UI.Fill(X, Y, Width, 1, "b")
		UI.Text(X + 1, Y, UI.Fit(Title, Width - 4), "0", "b")
		UI.Text(X + Width - 2, Y, "\215", "e", "b")
		UI.Fill(X, Y + 1, Width, Visible + 2, "8")
		for Row = 1, Visible do
			local Item = Items[Scroll + Row]
			if (Item) then UI.Text(X + 1, Y + 1 + Row, UI.Fit(" " .. Item, Width - 2), "f", "0") end
		end
		if (#Items == 0) then UI.Text(X + 2, Y + 2, "Nothing to pick", "7", "8") end
		local Event, A, B, C = os.pullEventRaw()
		if (Event == "mouse_click") then
			if (C == Y and B >= X + Width - 2) then return nil end
			local Row = C - Y - 1
			if (B >= X and B < X + Width and Items[Scroll + Row] and Row >= 1 and Row <= Visible) then return Items[Scroll + Row] end
			if (B < X or B >= X + Width or C < Y or C > Y + Visible + 2) then return nil end
		elseif (Event == "mouse_scroll") then
			Scroll = math.max(0, math.min(#Items - Visible, Scroll + A))
		elseif (Event == "key" and A == keys.backspace) then
			return nil
		end
	end
end

return UI
