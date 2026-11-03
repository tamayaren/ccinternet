# Building a ccinternet browser

This document is for people (and agents) who want to make a ccinternet browser for their own
CC: Tweaked operating system, for example as a BlockOS app. It describes the wire protocol,
the addresses and how pages should be drawn. The reference browser is `lib/browser.lua`
(launched by `client/browser.lua`).

## The short way: reuse the libraries

All four libraries are plain Lua modules with no globals, so they can be copied into any OS:

| Module | What it does |
|---|---|
| `lib/protocol.lua` | URLs, the message format, chunking, `Protocol.Request` and `Protocol.NetworkTransport` |
| `lib/ccmd.lua` | Parses `.ccmd` source into a document tree (`Ccmd.Parse`) and collects form fields (`Ccmd.FormFields`) |
| `lib/layout.lua` | Lays a document out for a width and height: blit rows, clickable regions and scroll limits |
| `lib/image.lua` | Reads `.nft`, `.bimg` and `.nfp` into blit rows |

They `require` each other as `lib.ccmd` and so on, so put the folder that contains `lib/` on
`package.path`. A minimal page viewer:

```lua
package.path = "/ccinternet/?.lua;" .. package.path
local Protocol = require("lib.protocol")
local Ccmd = require("lib.ccmd")
local Layout = require("lib.layout")

local Transport = Protocol.NetworkTransport("ccinternet")
local Response, Problem = Transport.Send("GET", "ccmd://example.com/", { Accept = "text/ccmd" })
if (not Response) then error(Problem) end

local Width, Height = term.getSize()
local Area = window.create(term.current(), 1, 2, Width, Height - 1)
local Doc = Ccmd.Parse(Response.Body)
local Page = Layout.Build(Doc, Width, Height - 1)
local Scroll = 0
Layout.Draw(Page, Area, Scroll)

-- Clicks: Layout.Hit(Page, X, Y - 1, Scroll) returns { Kind = "link" | "button" | "input", ... }
```

The rest of this file is the specification, for anyone writing their own versions.

## 1. Finding the core

- Open every modem with `rednet.open`. Browsers need a wireless or ender modem, or a wired
  modem on the core's network.
- The core registers with `rednet.host("ccinternet", Hostname)`. Find it with
  `rednet.lookup("ccinternet", Hostname)`.
- The default hostname is `ccinternet`. The reference browser keeps the name in the setting
  `ccinternet.host`, so another internet can be used by changing it (`set ccinternet.host other`).
- If a request times out, look the core up once more before giving up, since it may have been
  restarted.

## 2. Messages

All messages use the rednet protocol `ccinternet` and are tables:

| Field | Type | Meaning |
|---|---|---|
| `CCI` | number | Protocol version, currently `1` |
| `Type` | string | `"request"` or `"response"` |
| `Id` | number | Chosen by the browser; the response uses the same `Id` |
| `Part`, `Parts` | number | This part's number and the total (1 to 64) |
| `Kind` | string | Part 1 only: `"string"`, `"table"` or `"nil"`, the body type |
| `Head` | table | Part 1 only: see below |
| `Data` | string | This part's piece of the encoded body |

The body is encoded to a string (a string body as-is, a table body with the encoding in
section 3), cut into pieces of 16384 bytes, and sent as `Parts` messages. Join the `Data` of
parts 1..N in order and decode according to `Kind`. Parts may arrive in any order; drop
incomplete messages after 30 seconds.

Request head: `{ Method = "GET" | "POST", Url = "ccmd://site.com/page", Headers = { ... } }`

Response head: `{ Status = 200, Headers = { ["Content-Type"] = "text/ccmd", ... } }`

`Protocol.Pack` / `Protocol.Assembler` in `lib/protocol.lua` implement this.

## 3. Table encoding

Table bodies (form fields, uploads) use a small length-prefixed format instead of
`textutils.serialise`, so decoding never runs code:

| Value | Encoding |
|---|---|
| string | `s` + byte length + `:` + bytes, e.g. `s5:hello` |
| number | `n` + number + `;`, e.g. `n42;` |
| `true` / `false` | `T` / `F` |
| `nil` | `N` |
| table | `{` then key, value, key, value … then `}` |

Keys are strings or numbers. Nesting is limited to 16 levels.

## 4. Addresses

| Scheme | Meaning |
|---|---|
| `ccmd://host/path?query` | A page or file of a website. `ccmd://` without a host redirects to `domain://`. |
| `domain://page?query` | The core's built-in pages for registering and managing domains (section 8). |

`ccmd://cc.net/` is the network's search engine and the default home page. It is an ordinary
site to a browser, served by the core from the cc.net disk. Cores without that disk answer
`ccmd://cc.net/` with a redirect to `domain://`. Searches are `GET ccmd://cc.net/search?q=words`
(`&page=2` for more results, `&blocky=1` to be redirected to the best result).

- Hosts are case-insensitive. Paths are normalised: `.` and `..` are resolved, and a path that
  climbs above `/` is invalid.
- Links resolve against the current page: `/x` is on the same host, `x` is next to the
  current path, `?q=1` replaces the query.
- An address typed without a scheme (`example.com/page`) means `ccmd://example.com/page`.
- Query strings are `key=value&key=value` with `%XX` escapes (`+` is a space).

## 5. Responses

| Status | Meaning |
|---|---|
| 200 | OK |
| 301, 302, 303 | Redirect to `Headers.Location`. Follow it with `GET` (at most 5 times). |
| 400 | Bad request or unknown scheme |
| 403 | Suspended site, wrong password or expired session |
| 404 | No such site or page |
| 405 | Method not allowed |
| 409 | Domain already taken |
| 413 | Upload too large |
| 429 | Too many wrong passwords; wait a minute |
| 500 | Server error |
| 507 | Out of space (the site's floppy, or no blank floppies left for new domains) |

Error responses still have a `.ccmd` body explaining the problem, so a browser can just show it.

`Content-Type` values: `text/ccmd` (pages), `image/nft`, `image/bimg`, `image/nfp`,
`text/plain`, `application/octet-stream`. Other headers: `Server` (the core's hostname),
`Content-Length`, `Location`.

## 6. Drawing pages

The page format is specified in [docs/CCMD.md](docs/CCMD.md). Browsers should follow these
rules so pages look the same everywhere:

- **Page area.** Draw pages in an area below the browser's own controls. The `title` front
  matter goes in the window or tab title.
- **Topbar.** `layout="horizontal"` is drawn on the top rows of the page area and does not
  scroll. Items go left to right, starting at column 2, with two spaces between them, wrapping
  onto more rows if needed (at most half the page height). `layout="vertical"` is a sidebar on
  the left, as wide as the widest item plus 2 (at most a third of the width), one item per row
  starting at row 2. The content area is what remains.
- **Footer.** Drawn on the bottom rows of the page area and does not scroll. Items go left to
  right with two spaces between them, aligned by `alignment` with one column of margin on each
  side, wrapping onto more rows if needed (at most a third of the page height). A vertical
  sidebar stops above the footer.
- **Vertical alignment.** When the content is shorter than the content area, `center` moves it
  down by half the free rows (rounded down) and `bottom` by all of them.
- **Blocks** stack top to bottom in source order with no automatic spacing. Text wraps at
  spaces and breaks words longer than the width.
- **Colours.** Defaults: black background, white text, light blue links, gray topbar with white
  text, gray table header, light-gray input fields with black text (white while being edited),
  blue buttons with white text. Placeholders are gray.
- **Tables.** One space before each column and after the last. If the columns are too wide,
  shrink the widest column one character at a time, then wrap cells inside their columns.
- **Images.** Ask for each `src` after the page is shown, then redraw. Use the `Content-Type`
  (or the file extension) to pick the format. Transparent `.nfp` pixels show the page background.
  Show `[alt]` while loading and `[image failed: alt]` on failure.
- **Inputs** take one row: the label, a space, then the field, aligned together by `alignment`.
  Hidden inputs are not drawn.
- **Buttons** take one row each, except that `inline` buttons join the row of the button
  before them, two spaces apart, wrapping when the row is full. The row is aligned by its
  first button.
  Password fields show `*`. File fields show the number of chosen files.
- **Scrolling.** Mouse wheel, arrow keys, Page Up/Down, Home/End. Only the content scrolls.

## 7. Forms

- `Ccmd.FormFields(Doc, FormIndex, State, Button)` returns the fields to send: every input of
  the form (typed value, else its `value`), plus the pressed button's `name` = `value`.
- `POST` sends the fields table as the request body. `GET` replaces the query string of the
  `action` address with the fields.
- The action defaults to the current address.
- Pressing Enter in a text field should move to the next text field of the form and, on the
  last one, send the form.
- **File inputs** (`type="file"`): let the user pick a local file or folder. The value is a
  table mapping relative paths to contents, for example `{ ["index.ccmd"] = "...",
  ["img/logo.nft"] = "..." }`. For a folder, include the files inside it with paths relative to
  it. Uploads are limited by the site's floppy (about 125 KB).

## 8. `domain://`

These pages are normal `.ccmd` pages with forms, so a browser that supports forms and file
inputs needs nothing special for them. Programs can call them directly too:

| Address | Method | Fields |
|---|---|---|
| `domain://` | GET | Home page: sign in or register |
| `domain://register` | POST | `domain`, `password`, `confirm` → management page with a session `token` |
| `domain://login` | POST | `domain`, `password` → management page with a `token` |
| `domain://manage` | GET | `domain`, `token` |
| `domain://upload` | POST | `domain`, `token` (or `password`), `files` (path → contents table), `folder` (default `/`) |
| `domain://delete` | POST | `domain`, `token`, `path` |
| `domain://password` | POST | `domain`, `token`, `old`, `new`, `confirm` |
| `domain://release` | POST | `domain`, `token`, `password` (deletes the site and frees the name) |
| `domain://submissions` | GET / POST | `domain`, `token`; POST with `clear` deletes stored form submissions |
| `domain://logout` | GET | `token` |
| `domain://directory` | GET | Every domain on the core (if the admin allows it) |

Sessions last 30 minutes after their last use. After 5 wrong passwords from one computer,
sign-in is blocked for 60 seconds.

## 9. Checklist

- [ ] Opens modems and looks up the core by hostname (default `ccinternet`).
- [ ] Sends chunked requests and puts chunked responses back together.
- [ ] Follows redirects; shows error pages from the body.
- [ ] Resolves relative links against the current page.
- [ ] Draws the topbar fixed (horizontal and vertical) and the footer fixed at the bottom,
      paragraphs with alignment, vertical alignment, tables, inline colours and links.
- [ ] Loads `.nft`, `.bimg` and `.nfp` images after the page.
- [ ] Supports text, password, hidden and file inputs, aligned inputs, inline buttons, buttons with
      `href`, and form `GET`/`POST`.
- [ ] Uses `ccmd://cc.net/` as the default home page.
- [ ] Shows the page `title`.
- [ ] Has back, forward, reload and an address bar.
