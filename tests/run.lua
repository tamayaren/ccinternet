-- Runs every test file: lua5.2 tests/run.lua (from the repository root).
package.path = "./?.lua;./tests/?.lua;" .. package.path

local Files = { "test_ccmd", "test_layout", "test_protocol", "test_server", "test_browser", "test_admin" }
local Only = arg[1]
local Passed, Failed = 0, 0

_G.Check = function(Condition, Message)
	if (Condition) then
		Passed = Passed + 1
	else
		Failed = Failed + 1
		print("  FAIL: " .. tostring(Message) .. "\n" .. debug.traceback("", 2):gsub("\n[^\n]*run%.lua.*", ""))
	end
end

_G.Equal = function(Actual, Expected, Message)
	Check(Actual == Expected, (Message or "values differ") .. ": expected " .. tostring(Expected) .. ", got " .. tostring(Actual))
end

for _, Name in ipairs(Files) do
	if (not Only or Only == Name) then
		-- Fresh module state for every file.
		for Module in pairs(package.loaded) do
			if (Module:match("^lib%.") or Module:match("^server%.") or Module == "mock") then package.loaded[Module] = nil end
		end
		print(Name)
		local Ok, Problem = pcall(dofile, "tests/" .. Name .. ".lua")
		if (not Ok) then
			Failed = Failed + 1
			print("  ERROR: " .. tostring(Problem))
		end
	end
end

print(string.format("\n%d passed, %d failed", Passed, Failed))
os.exit(Failed == 0 and 0 or 1)
