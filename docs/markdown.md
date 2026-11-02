# The graph's Markdown

Prism and Weft are two ways of looking at one graph: a folder of Markdown
files, kept in a git repository. This is what those files say and how
both apps read them. The code that reads them is `Sources/GraphKit`; its
fixtures, `Tests/GraphKitTests/Fixtures`, are this document's examples, and
both apps' tests hold to them.

The one rule for every extension: **it degrades gracefully.** Shown by any
Markdown viewer — GitHub, an editor's preview, `cat` — each reads as
sensible text, never as noise, and nothing an app does not understand is
lost when it writes the file back.

## Files

| Where | What |
|---|---|
| `daily/YYYY-MM-DD.md` | a day's page |
| `weekly/YYYY-Www.md` | a week's page (`2026-W44`) |
| `notes/**/*.md` | every other page — Prism's notes and Weft's alike |
| `assets/` | pictures and other files pages show or link to |

Every page is the same kind of thing, whichever app made it. A page file is
written back byte for byte as it was read, except where it was changed.

## A page

```markdown
---
id: 01jbxk3t6y8q2zp4m9v7c5r0wd
aliases: [Atlas]
tags: [Projects]
wiki: true
status: active
related:
  - Ada Lovelace
---
# Project Atlas

- Kick-off with [[Ada Lovelace]] on [[2026-10-31]] #planning
```

- **Title**: the frontmatter's `title`, else the first `# Heading` (then
  hidden from the page's body where an app shows the title on its own),
  else the date (a day), the week (a week), or the file's name ("Untitled"
  for a name that is only an id). New pages are written with a `# Heading`.
- **id**: a lowercase ULID, the page's lasting identity, which survives
  renames. Renaming keeps a page's file; links to it are rewritten.
- **aliases**: other names the page answers to. A title written
  `Project // Topic` answers to each part too.
- **tags**: the frontmatter's `tags` and every inline `#tag` in the body,
  outside code, together, compared without regard to case.
- **Flags**: `private` (never shown, or named in a commit), `pinned`
  (`true`, or a number for its place), `inbox`, `topic`, `template`,
  `cover` (a picture's path), all as Prism reads them.
- **related**: other pages this one is related to without a link in its
  text — a list of their names (a title, an alias, a date), plain or as
  `[[links]]`. A relation goes both ways: the other page shows it too,
  though only this one has it written. Prism and Weft list a page's
  relations under it, both ways, and take one away from whichever page
  has it written. Prism writes them an item a line; either form reads.
- **wiki**: `wiki: true` marks a page as part of the wiki — canonical, kept
  up, an evolving piece of knowledge — where other notes may be passing or
  throwaway. It changes nothing about the file; apps may show and gather
  wiki pages apart (Weft makes its new pages wiki pages).
- **created**, **modified**: ISO 8601 times, kept by the app that writes.
- **Fields**: any other frontmatter key. A tag's page can give the pages
  tagged with it typed fields (below).

Frontmatter is YAML, but only its plainest part: `key: value`, quoted or
not; lists as `[a, b]` or one `- item` a line; `|` blocks. Long lists are
written an item a line, so git merges changes to different items.

## Links

| Written | Means | Degrades to |
|---|---|---|
| `[[Title]]` | a link to a page by title or alias, case aside | the title, bracketed |
| `[[Title\|shown]]` | the same, showing `shown` | readable |
| `[[2026-10-31]]`, `[[2026-W44]]` | a day's or a week's page, written yet or not | a date |
| `![[Title]]` | the page shown inside this one, live | the link, with a `!` |
| `[text](https://…)`, `<https://…>` | a web link | itself |
| `![alt](assets/x.png)<!-- {"width":425} -->` | a picture, at a size | the picture; the comment is invisible |

A link to a title no page has is a page waiting to be written: apps show it
faded, and make it when it is followed.

## Inline

`**strong**`, `*emphasis*`, `` `code` ``, `~~struck~~`, `==highlighted==`,
`#tag`. HTML comments are hidden.

## Blocks

Headings, paragraphs, lists (nested by indentation), quotes, rules, tables
and fenced code are CommonMark's and GitHub's. Beyond them:

**Tasks.** `+ [ ]` / `+ [x]` is a task (Prism's, drawn round), `- [ ]` /
`- [x]` a checklist item (drawn square). Both degrade to list items.

**Callouts**, as GitHub writes them, and draws them:

```markdown
> [!TIP]
> Follow a link and its card opens just after the card it was in.
```

`NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`. Degrades to a quote.

**Queries**: a live list of pages, in a fenced block a line a condition —
which degrades to a code block saying what it finds:

````markdown
```query
tag: Person
not tag: Archived
sort: -modified
limit: 10
show: table
```
````

| Line | Finds |
|---|---|
| `tag: X` | pages tagged X (each `tag:` line must hold) |
| `not tag: X` | pages not tagged X |
| `title: words`, `text: words` | pages with the words in their title, or body |
| `links to: X`, `linked from: X` | pages linking to X; pages X links to |
| `listed in: X` | the titles in X's `list` field, in their order |
| `has: field, …` | pages with each field |
| `wiki: yes` / `wiki: no` | wiki pages; other pages |
| `is: inbox`, `pinned`, `topic`, `template`, `wiki`, `day`, `week`, `note` | pages flagged so, or of that kind — Prism's Inbox is `is: inbox` + `sort: -modified`, its Pinned `is: pinned` + `sort: pinned` |
| `sort: title` / `created` / `modified` / `pinned` | the order (`-` before it, reversed); else the tag's own order, else title |
| `limit: n` | the first n |
| `show: list` / `inline` / `table` / `cards` / `count` / `tree` | how they are shown |
| `columns: a, b` | a table's fields (else the tag's typed fields) |

`{this}` stands for the page the query is in: `tag: {this}`. A line not
understood is kept, and written back.

**Typed fields.** A tag's page lists, in its frontmatter, the fields of the
pages tagged with it — a bare name for text:

```yaml
fields:
  - birthday (date)
  - company (link)
  - status (active | paused | done)
  - rating (number)
  - website (url)
  - met (yes/no)
```

Values are frontmatter: a date `2026-10-31` (and a link to that day), a link
a page's title, a choice one of its options, yes or no `yes`/`no`.

## Conflicts

Where two devices changed the same lines, a sync writes both between
markers (`<<<<<<< this device` … `=======` … `>>>>>>> other device`) for
the page's reader to settle; before that, frontmatter is put together field
by field — tags and lists as sets, `modified` the later — so only a page's
body comes to that.
