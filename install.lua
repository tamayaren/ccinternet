-- ccinternet installer.
--   wget run https://raw.githubusercontent.com/tamayaren/ccinternet/main/install.lua [server|browser] [branch]
-- "server" installs the core (admin screen + browser), "browser" installs only the browser.

local Args = { ... }
local Mode = Args[1]
local Branch = Args[2] or "main"
local Base = "https://raw.githubusercontent.com/tamayaren/ccinternet/" .. Branch .. "/"
local Root = "/ccinternet"

local BrowserFiles = {
	"lib/ccmd.lua", "lib/layout.lua", "lib/image.lua", "lib/protocol.lua", "lib/browser.lua",
	"client/browser.lua"
}
local ServerFiles = {
	"lib/sha256.lua",
	"server/main.lua", "server/admin.lua", "server/ui.lua", "server/config.lua", "server/auth.lua",
	"server/log.lua", "server/storage.lua", "server/transfer.lua", "server/router.lua",
	"server/pages.lua", "server/domains.lua", "server/network.lua",
	"examples/site/index.ccmd", "examples/site/about.ccmd", "examples/site/contact.ccmd",
	"examples/site/thanks.ccmd", "examples/site/img/logo.nft"
}

if (not http) then
	printError("HTTP is disabled on this server, so ccinternet cannot be downloaded.")
	return
end

if (Mode ~= "server" and Mode ~= "browser") then
	print("ccinternet installer")
	print("  1) Browser - visit websites")
	print("  2) Server  - turn this computer into an internet core")
	write("Choose 1 or 2: ")
	local Choice = read()
	Mode = (Choice == "2" or Choice == "server") and "server" or "browser"
end

local Files = {}
for _, File in ipairs(BrowserFiles) do Files[#Files + 1] = File end
if (Mode == "server") then
	if (not term.isColour()) then
		printError("The core needs an Advanced Computer.")
		return
	end
	for _, File in ipairs(ServerFiles) do Files[#Files + 1] = File end
end

for Index, File in ipairs(Files) do
	write(string.format("[%2d/%2d] %s ", Index, #Files, File))
	local Response, Problem = http.get(Base .. File, nil, true)
	if (not Response) then
		print("")
		printError("Download failed: " .. tostring(Problem))
		return
	end
	local Data = Response.readAll()
	Response.close()
	local Handle = fs.open(fs.combine(Root, File), "wb")
	Handle.write(Data)
	Handle.close()
	print("ok")
end

-- Startup files go in /startup/. A /startup.lua file would stop that folder from running, so move it in.
if (fs.exists("/startup.lua") and not fs.isDir("/startup.lua")) then
	if (not fs.exists("/startup")) then fs.makeDir("/startup") end
	fs.move("/startup.lua", "/startup/00_startup.lua")
	print("Moved your startup.lua to /startup/00_startup.lua")
elseif (fs.exists("/startup") and not fs.isDir("/startup")) then
	fs.move("/startup", "/startup.old")
	print("Moved your startup file to /startup.old")
end

local Startup = {
	"-- Added by the ccinternet installer.",
	"shell.setAlias(\"browser\", \"" .. Root .. "/client/browser.lua\")"
}
if (Mode == "server") then
	Startup[#Startup + 1] = "shell.run(\"" .. Root .. "/server/main.lua\")"
end
local Handle = fs.open("/startup/ccinternet.lua", "w")
Handle.write(table.concat(Startup, "\n") .. "\n")
Handle.close()

print("")
if (Mode == "server") then
	print("Installed the ccinternet core. Starting setup...")
	sleep(1)
	shell.setAlias("browser", Root .. "/client/browser.lua")
	shell.run(Root .. "/server/main.lua")
else
	shell.setAlias("browser", Root .. "/client/browser.lua")
	print("Installed. Run: browser")
	print("It needs a wireless or ender modem.")
end
