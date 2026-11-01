-- ccinternet browser. Usage: browser [address]
-- Finds the core named by the "ccinternet.host" setting (default "ccinternet") over rednet.

local Program = shell.getRunningProgram()
local Root = "/" .. fs.getDir(fs.getDir(Program))
package.path = Root .. "/?.lua;" .. package.path

local Browser = require("lib.browser")
local Args = { ... }

if (Args[1] == "-h" or Args[1] == "--help") then
	print("Usage: browser [address]")
	print("Addresses look like ccmd://example.com/page or domain://")
	print("Set the core to use: set ccinternet.host <name>")
	return
end

math.randomseed(os.epoch and os.epoch("utc") or os.time())
Browser.Run({ Url = Args[1] })
