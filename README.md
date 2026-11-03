# ccinternet

An in-game internet for [CC: Tweaked](https://tweaked.cc). One computer, the **core**, hosts
every website of the network on floppy disks. Other computers visit those sites with the
**browser**, and anyone can claim a domain and upload a site through `domain://`.

Sites are written in [`.ccmd`](docs/CCMD.md), a small Markdown/HTML mix made for the terminal:
paragraphs, a fixed topbar, tables, inline colours and links, `.nft`/`.bimg` pictures and forms.

```
 Home About Contact
                       ccmd
                      example

           Welcome to the example site!
          This page is written in .ccmd.

 Feature              Supported
 Paragraphs              yes
 Tables                  yes
```

## Install

On the computer, run:

```
wget run https://raw.githubusercontent.com/tamayaren/ccinternet/main/install.lua
```

Pick **Browser** or **Server**. You can also pass it directly:
`... install.lua browser` or `... install.lua server`. A third argument installs from another
branch. Files go to `/ccinternet`, and `/startup/ccinternet.lua` adds the `browser` command
(and, on a core, starts the server at boot).

## Building a core

| Block | Where | Purpose |
|---|---|---|
| Advanced Computer | — | The core. Runs the server and the admin screen. |
| Wireless or ender modem | any side | Browsers reach the core through it. An ender modem works at any distance and across dimensions. |
| Wired modem + networking cable | any side | Connects the cluster's disk drives. Right-click each drive's wired modem to attach it. |
| Disk drives, each with a floppy | on the cable | One floppy holds one domain. Add as many as the Minecraft server can handle. |
| Disk drive | **left** of the core | The transfer drive, for copying domains to and from floppies. |
| Disk drive + floppy | **right** of the core | Optional. Holds the **cc.net** disk, the network's search engine and the browsers' home page. |

Each domain lives on its own floppy, which holds the domain's owner data, its site and its form
submissions. A floppy holds 125 KB by default (`floppy_space_limit` in the CC: Tweaked server
config), so that is the size limit of a site. The core's own disk only keeps its settings and
the request log, so the cluster can grow as big as you like: put a blank floppy in a new
drive and the next person to register gets it.

### cc.net, the search engine

Put a disk drive on the **right** of the core with a blank floppy in it, and the core turns it
into the cc.net disk (labelled `cc.net`). Browsers then open `ccmd://cc.net/` as their home page:

```
                   cc.net    (big, in colour)

           [ Search the network         ]

           Search    I'm Feeling Blocky

     12 websites hosted  Connected to ccinternet
```

- **Search** lists every page of every website that matches the words, best first: the domain
  name counts most, then page titles, then the text on the page. Suspended sites are left out.
- **I'm Feeling Blocky** goes straight to the best result, or to a random website when the
  search bar is empty.
- The footer shows how many websites the server hosts and the name of the server the browser
  is connected to.

The search index is kept on the cc.net disk and is updated on its own when sites change. If the
index of a very large network does not fit on the floppy, searching still works; the index is
just rebuilt after a restart. The drive is optional: without it, `ccmd://cc.net/` sends browsers
to `domain://` instead. A domain floppy put in that drive by mistake keeps serving its domain.
The side can be changed under **Settings → cc.net drive**, and `cc.net` cannot be registered.

### First start

The core asks for:

1. **A server name.** Browsers look for `ccinternet` by default. Keep it unless you want a
   separate internet (browsers then need `set ccinternet.host <name>` or the menu's
   *Server* option).
2. **An admin password**, which unlocks the admin screen. The screen locks at every boot and
   after 5 minutes without input (changeable in Settings).

Setup also turns off `shell.allow_disk_startup`, so a floppy in the transfer drive can never
run its own `startup` in place of the server at boot.

The server keeps answering browsers while the admin screen is locked. Ctrl+T does not stop it;
use **Settings → Stop server**.

### The admin screen

| Tab | What it does |
|---|---|
| **Domains** | Every domain with its drive, size and status. Type to filter. Click a domain for its details: storage bar, files and their page locations, and buttons to **Open** it in the browser, **Suspend**/**Resume**, set a new **Password**, **Export** it to the transfer floppy or **Delete** it (the floppy becomes blank). Click a file to view it in the browser, right-click to edit it with `edit`. Right-click a domain in the list to open its site. |
| **Drives** | Every cluster drive: blank, holding a domain, empty, or holding other files. Click a floppy with other files to wipe it for reuse. **Rescan** re-reads all drives (this also happens on its own when disks or drives come and go). |
| **Transfer** | The drive on the left. **Export a domain** copies a domain and all its files to the floppy there. A floppy holding an exported domain can be **imported** into the cluster (or replace the copy that is already there). A floppy holding plain website files (`.ccmd` pages at its root or in a `site` folder) can be **imported as a new domain** with a name and owner password you choose. **Wipe** and **Eject** are there too. |
| **Log** | Recent requests (computer ID, method, address, status) and admin events. Also saved in `/ccinternet/data/requests.log`. |
| **Settings** | Rename the server, change the admin password, auto-lock time, open or close registration, show or hide the public directory, pick the transfer drive side, see the cc.net drive (pages indexed; `*` means the index only fits in memory), pick its side or wipe a floppy there for it, reconnect the network, stop the server. |

**Web** in the top-right corner opens the browser on the core itself. It talks to the server
directly, without the network, and can also view suspended sites.

## The browser

```
browser [address]
```

Needs a wireless or ender modem. Best on an Advanced Computer or Advanced Pocket Computer.

| Control | Action |
|---|---|
| `<` `>` `@` | Back, forward, reload |
| Address bar (or Ctrl+L) | Type an address: `example.com`, `ccmd://example.com/about`, `domain://` |
| `=` menu | Home (`ccmd://cc.net/` unless changed), set home page, choose the server, save the current file, quit |
| Wheel, arrows, Page Up/Down, Home/End | Scroll |
| Tab / Enter | Move between links and fields / open the selected one |
| Backspace | Back |
| Ctrl+R, Ctrl+S, Ctrl+Q | Reload, save, quit |

Click a field to type in it. Enter moves to the next field and sends the form after the last
one. A **file** field asks for a path on your computer: a file, or a folder to upload
everything inside it.

## Owning a domain

1. Open `domain://` in the browser and choose **Register**.
2. Pick a name (`mysite.com`: letters, numbers and dashes, separated by dots, up to 32
   characters) and a password.
3. On the management page, pick a file or folder under **Files** and press **Upload**. For
   example, upload `/ccinternet/examples/site` from a core.
4. Visit `ccmd://mysite.com`.

From the management page you can also delete files, read what visitors sent through your
site's forms, change the password and release the domain. If no blank floppy is left, ask the
admin to insert one and try again.

## Writing pages

See **[docs/CCMD.md](docs/CCMD.md)** for the full format, and `examples/site` for a small site.

```
--
title: My page
location: /
--
<topbar color="pink" text-color="black">
[Home](/) [About](/about)
</topbar>
<p alignment="center">
Hello from {yellow}ccinternet{/}!
</p>
```

## Other browsers

[BROWSER.md](BROWSER.md) describes the protocol, addresses, drawing rules and `domain://`
pages, for anyone who wants to build a browser for their own OS. The libraries in `lib/` can be
reused as they are.

## Project layout

```
install.lua          installer
lib/                 shared: ccmd parser, layout, images, protocol, browser, sha256
client/browser.lua   the browser program
server/              the core: main loop, admin screen, storage, transfers, router, domain://, cc.net search
docs/CCMD.md         page format
BROWSER.md           protocol and browser guide
examples/site/       example website
tests/               tests that run outside the game with Lua 5.2
```

## Tests

```
lua5.2 tests/run.lua
```

The tests fake the CC: Tweaked APIs (filesystem with floppy capacities, drives, terminal) and
cover the parser, layout, protocol, server, admin screen and browser.

## Security notes

- Rednet traffic is not encrypted. Anyone with a modem in range can read passwords sent to
  `domain://`. Use passwords you don't use anywhere else.
- Passwords are stored salted and hashed (SHA-256, repeated 32 times).
- Requests are decoded with a data-only format, so other computers cannot run code on the core.
- Only `ccinternet.meta`, `site/` and `forms/` are copied when importing a domain floppy.
- Physical access to the core (breaking it, editing its files from another computer) is up to
  your server's protection rules.
