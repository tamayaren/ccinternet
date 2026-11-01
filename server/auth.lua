-- Password hashing, domain sessions and login throttling.

local Sha256 = require("lib.sha256")

local Auth = {}

Auth.Rounds = 32
Auth.SessionLength = 30 * 60
Auth.MaxFailures = 5
Auth.LockoutTime = 60

local Sessions = {}
local Failures = {}

local function Now()
	return os.clock()
end

local function RandomHex(Length)
	local Parts = {}
	for Index = 1, Length do Parts[Index] = string.format("%x", math.random(0, 15)) end
	return table.concat(Parts)
end

Auth.RandomHex = RandomHex

function Auth.Salt()
	return RandomHex(16)
end

function Auth.Hash(Password, Salt)
	local Digest = Salt .. ":" .. tostring(Password)
	for _ = 1, Auth.Rounds do
		Digest = Sha256.Hex(Salt .. Digest)
	end
	return Digest
end

function Auth.Check(Password, Salt, Hash)
	if (type(Password) ~= "string" or type(Salt) ~= "string" or type(Hash) ~= "string") then return false end
	return Auth.Hash(Password, Salt) == Hash
end

-- Sessions let domain:// pages keep a signed-in owner without resending the password.
function Auth.NewSession(Domain)
	local Token = RandomHex(32)
	Sessions[Token] = { Domain = Domain, Expires = Now() + Auth.SessionLength }
	return Token
end

function Auth.Session(Token, Domain)
	local Session = type(Token) == "string" and Sessions[Token]
	if (not Session) then return false end
	if (Session.Expires < Now() or Session.Domain ~= Domain) then
		if (Session.Expires < Now()) then Sessions[Token] = nil end
		return false
	end
	Session.Expires = Now() + Auth.SessionLength
	return true
end

function Auth.EndSession(Token)
	if (type(Token) == "string") then Sessions[Token] = nil end
end

-- Ends every session of a domain (after a password change or when the domain is released).
function Auth.EndDomainSessions(Domain)
	for Token, Session in pairs(Sessions) do
		if (Session.Domain == Domain) then Sessions[Token] = nil end
	end
end

-- Login throttling per sender computer.
function Auth.Allowed(Sender)
	local Entry = Failures[Sender]
	if (not Entry) then return true end
	if (Entry.Until and Entry.Until > Now()) then return false, math.ceil(Entry.Until - Now()) end
	return true
end

function Auth.Fail(Sender)
	local Entry = Failures[Sender] or { Count = 0 }
	Entry.Count = Entry.Count + 1
	if (Entry.Count >= Auth.MaxFailures) then
		Entry.Until = Now() + Auth.LockoutTime
		Entry.Count = 0
	end
	Failures[Sender] = Entry
end

function Auth.Succeed(Sender)
	Failures[Sender] = nil
end

return Auth
