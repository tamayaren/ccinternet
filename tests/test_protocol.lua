local Mock = require("mock")
Mock.Install()
local Protocol = require("lib.protocol")

-- URLs
local U = Protocol.ParseUrl("ccmd://Example.com/a/b?x=1&y=two%20words")
Equal(U.Scheme, "ccmd", "scheme")
Equal(U.Host, "example.com", "host lowercased")
Equal(U.Path, "/a/b", "path")
Equal(U.Params.y, "two words", "query decoded")
Equal(Protocol.ParseUrl("/c", U).Path, "/c", "absolute path")
Equal(Protocol.ParseUrl("d", U).Path, "/a/d", "relative path")
Equal(Protocol.ParseUrl("../d", U).Path, "/d", "dot dot")
Equal(Protocol.ParseUrl("?z=1", U).Params.z, "1", "query only")
Equal(Protocol.ParseUrl("example.com/page").Scheme, "ccmd", "typed address gets ccmd")
Equal(Protocol.ParseUrl("domain://").Host, "", "empty host")
Equal(Protocol.ParseUrl("domain://manage?domain=a").Host, "manage", "domain page")
Equal(Protocol.ParseUrl("ccmd://x/../../etc"), nil, "escaping path rejected")
Equal(Protocol.FormatUrl(Protocol.ParseUrl("ccmd://x.com/")), "ccmd://x.com", "format drops the root slash")
Equal(Protocol.FormatUrl(Protocol.ParseUrl("ccmd://x.com/a b")), "ccmd://x.com/a%20b", "format escapes")
local Built = Protocol.Url("domain", "delete", "/", { path = "/img/a b.nft", token = "t" })
Equal(Protocol.ParseUrl(Built).Params.path, "/img/a b.nft", "query round trip")

-- Encoding
local Value = { a = "x", [1] = 2, nested = { flag = true, bin = "\0\30\31\255\n" }, n = -1.5 }
local Decoded = Protocol.Decode(Protocol.Encode(Value))
Equal(Decoded.a, "x", "string field")
Equal(Decoded[1], 2, "number key")
Equal(Decoded.nested.flag, true, "boolean")
Equal(Decoded.nested.bin, "\0\30\31\255\n", "binary string")
Equal(Decoded.n, -1.5, "float")
Check(Protocol.Decode("s99:abc") == nil, "truncated string rejected")
Check(Protocol.Decode("{s1:a") == nil, "unclosed table rejected")
Check(Protocol.Decode("x") == nil, "bad tag rejected")
Check(Protocol.Decode(string.rep("{", 40) .. string.rep("}", 40)) == nil, "deep nesting rejected")

-- Chunking
local Big = string.rep("0123456789", 5000)
local Messages = Protocol.Pack("response", 7, { Status = 200 }, Big)
Equal(#Messages, math.ceil(#Big / Protocol.ChunkSize), "parts")
local Collector = Protocol.Assembler()
local Result
for Index = #Messages, 1, -1 do -- out of order
	Result = Collector:Feed(5, Messages[Index]) or Result
end
Check(Result ~= nil, "assembled")
Equal(Result.Body, Big, "body intact")
Equal(Result.Head.Status, 200, "head kept")
local Table = Protocol.Pack("request", 1, { Method = "POST" }, { files = { ["a.ccmd"] = Big } })
local Joined
local Collector2 = Protocol.Assembler()
for _, Message in ipairs(Table) do Joined = Collector2:Feed(3, Message) or Joined end
Equal(Joined.Body.files["a.ccmd"], Big, "table body intact")
Check(Collector:Feed(1, { CCI = 1, Type = "request", Id = 1, Part = 1, Parts = 9999, Data = "" }) == nil, "too many parts rejected")
Check(Collector:Feed(1, "junk") == nil, "junk rejected")
