# The `.ccmd` page format

`.ccmd` is the page format of ccinternet. It is a small mix of Markdown and HTML made for the
CC: Tweaked terminal: one text size, 16 colours, no headings.

```
--
title: Title of page
location: /example1
--
# A comment. Front matter is required.

<topbar color="pink" layout="horizontal" text-color="black">
[Home](/) [Example](ccmd://example.com/example1)
</topbar>

<p alignment="center" text-color="white">
Line breaks inside a paragraph are kept.
{red}Coloured{/} words and [links](/about) work anywhere.
</p>

<table header-color="black" text-color="white">
| Header | Header1 |
|---|---|
| Test1 | Test2 |
</table>

<br/>
<img src="/image.nft">
Text can also sit outside a paragraph.
```

## Front matter

Every page starts with a block between two `--` lines (`---` also works).

| Key | Required | Meaning |
|---|---|---|
| `title` | yes | Shown in the browser's title bar (and the multishell tab). |
| `location` | yes | The address of the page inside the domain, such as `/` or `/about`. The file name does not matter; the location is the address. |
| `background` | no | Page background colour (default `black`). |
| `text-color` | no | Default text colour (default `white`). |
| `link-color` | no | Link colour (default `lightBlue`). |
| `vertical-alignment` | no | `top` (default), `center` or `bottom`: where a page shorter than the screen sits. |

A page with `location: /404` is shown when a visitor asks for a page that does not exist.

The server refuses to upload a `.ccmd` file without a title and a location.

## Comments and escapes

A line whose first non-space character is `#` is a comment, anywhere in the page. Start a line
with `\#` to show a real `#`.

A backslash shows the next character literally: `\[`, `\{`, `\<`, `\\`. In table cells, `\|`
is a literal pipe.

## Inline markup

Inline markup works in paragraphs, loose text, table cells and the topbar.

| Markup | Result |
|---|---|
| `[text](url)` | A link. The URL can be absolute (`ccmd://site.com/page`, `domain://`), start with `/` (same site) or be relative (`page2`, `../up`). |
| `{red}text{/}` | Text in a colour. |
| `{white on red}text{/}` | Text colour and background. |

Colour spans can be nested; `{/}` closes the newest one.

Colours (not case-sensitive, spaces/dashes ignored): `white orange magenta lightBlue yellow lime
pink gray lightGray cyan purple blue brown green red black`. `grey`, `lightGrey` and `silver` also
work, as do blit characters `0`–`f`.

## Blocks

Tags are lower case, are written on their own lines and take `name="value"` attributes.
Blank lines outside tags are ignored; use `<br/>` for spacing.

### `<topbar>` … `</topbar>`

A bar that stays visible while the page scrolls. Each line inside is one item (usually links).

| Attribute | Values | Default |
|---|---|---|
| `layout` | `horizontal` (top of the page, wraps onto more rows) or `vertical` (a sidebar on the left) | `horizontal` |
| `color` | background colour | `gray` |
| `text-color` | text and link colour | `white` |

Only one topbar is used per page (the last one).

### `<footer>` … `</footer>`

A bar fixed to the bottom of the page that does not scroll. Each line inside is one item; items
go left to right with two spaces between them and wrap onto more rows if needed.

| Attribute | Values | Default |
|---|---|---|
| `alignment` | `left`, `center`, `right` | `left` |
| `color` | background colour | `gray` |
| `text-color` | text and link colour | `white` |

Only one footer is used per page (the last one).

### `<p>` … `</p>`

A paragraph. Line breaks and blank lines inside it are kept, long lines wrap at words, and
`<br/>` inside starts a new line. Shared indentation is removed.

| Attribute | Values |
|---|---|
| `alignment` (or `align`) | `left`, `center`, `right` |
| `text-color` | text colour |
| `color` | background colour |

### Loose text

Text outside any tag is shown as left-aligned lines in the page's text colour.

### `<table>` … `</table>`

Markdown table rows. The second row `|---|---|` marks the first row as the header; `:---:` and
`---:` centre or right-align a column. Long cells wrap inside their column.

| Attribute | Meaning | Default |
|---|---|---|
| `header-color` | header row background | `gray` |
| `header-text-color` | header row text | the table's text colour |
| `text-color` | text colour | page text colour |
| `color` | body background | page background |

### `<br/>`

One empty row.

### `<img src="…">`

Shows a picture: CC: Tweaked `.nft`, BlockOS / blit `.bimg` (first frame) or paintutils `.nfp`.
The `src` resolves like a link. Attributes: `alignment` and `alt` (text shown while loading).
Pictures wider than the screen are cropped.

### `<form>` … `</form>`

Groups inputs and buttons. Anything else may sit inside too.

| Attribute | Meaning | Default |
|---|---|---|
| `action` | where to send the form | the current page |
| `method` | `POST` (fields in the body) or `GET` (fields in the query string) | `POST` |

Sending a `POST` to a page of a normal website stores the fields on the site's floppy (the
owner reads them under **Forms** at `domain://`) and then shows the page at `action`, or a
"Sent!" page if there is none.

### `<input …/>`

| Attribute | Meaning |
|---|---|
| `name` | field name sent with the form |
| `type` | `text` (default), `password`, `hidden` or `file` |
| `label` | text shown before the field |
| `value` | starting value |
| `placeholder` | grey hint while empty |
| `width` | field width in characters (default 20) |
| `alignment` | `left`, `center`, `right` (the label and field together) |
| `color`, `text-color` | field colours |

A `file` input lets the visitor pick a file or folder on their own computer. It is sent as a
table of relative path → contents.

### `<button …/>` or `<button …>Text</button>`

| Attribute | Meaning |
|---|---|
| `text` | label (or put it between the tags) |
| `href` | makes the button a link instead of a submit button |
| `name`, `value` | sent with the form when this button is pressed |
| `alignment` | `left`, `center`, `right` |
| `inline` | put the button on the same row as the button right before it |
| `color`, `text-color` | colours (default blue and white) |

Buttons sharing a row are two spaces apart and aligned by the first button's `alignment`. When
they do not fit, they wrap onto the next row.

```
<button text="Search" alignment="center"/>
<button text="I'm Feeling Blocky" inline/>
```

Inside a form, a button without `href` submits the form.

## Sites

A site is every file uploaded to a domain: `.ccmd` pages, pictures and any other files.
Everything has to fit on one floppy disk, 125 KB by default. CC: Tweaked counts every file and
folder as at least 500 bytes, so many tiny files use up space faster than their sizes suggest.

See `examples/site` for a small site with a topbar, a table, a picture and a contact form.
