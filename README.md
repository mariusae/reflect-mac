# Reflect Mac

A native Mac front end for a [Reflect](../reflect-open) graph: the daily notes
as one long page, each day an outline you edit the way you would in
[Bike](https://www.hogbaysoftware.com/bike/), kept in git.

It reads and writes the same files the Reflect app does — `daily/YYYY-MM-DD.md`
in a checkout of your notes repository — and commits, merges and pushes the
way Reflect does, so the two can be used side by side.

## The timeline

Every day is there, oldest at the top, whether or not anything was written on
it; scrolling in either direction goes on for as long as you do. The app opens
with today at the top of the window. A day with nothing in it shows an empty
row to write in, and does not become a file until something is written.

The arrow keys run off the end of one day into the next. ⌘T goes to today,
⌃⌥↑ and ⌃⌥↓ to the day before and after. A `[[2026-09-25]]` link goes to its day.

## Notes, and finding them

⌘O opens the chooser: one field that finds anything. A note by its title or
any of its names — frontmatter `aliases`, the parts of a `Project // Topic`
title — with the whole name first, then its start, the starts of its words,
and its initials ("dd" finds "Design Doc"). A day by its date, written or said
("2026-09-24", "sep 24", "next friday", "yesterday"). Notes by words in them:
from Reflect's own search index (`.reflect/index.sqlite`, read only, never
written) when Reflect keeps one for the graph, else by reading the notes. With
nothing typed, today and the notes edited last. ↩ opens; ⌥↩ or an ⌥-click
opens in the split view; ⌘↩ opens the note with the name typed, making it
when there is none.

A note opens in place of the timeline, edited as a day is; ⌘[ and ⌘] go back
and forward, and ⌘T back to today. The split view slides a second note in
from the right, over the first; ⌘W puts it away. A `[[link]]` opens its note —
by date, then title, then alias, as Reflect resolves them — or, with ⌥, in
the split view; a link to a note that is not there yet makes it, as Reflect
does: `notes/<slug>.md`, with a ULID `id` and the title as its first heading.

Resting the pointer on a link shows its card. A link to the web shows the
page's icon, title and description — read as Reflect reads them, from
`og:title` or `<title>`, fetched once and cached — with Open and Copy; an
address written out bare also offers Use Title, which puts
`[Page Title](address)` in its place. A link to a post on X shows the post. A
`[[link]]` shows the note it leads to, as it reads, with Open and Open in Split
View, or offers to make it when there is no such note. Links in a note marked
`private: true` are never looked up.

Typing `[[` in a note brings up the chooser's own search, under the caret, for
the words that follow: ↑ and ↓ choose, Return or Tab puts in `[[Title]]` (or
`[[2026-09-24]]` for a day), and Escape leaves what is typed as it is.

## The outline

Each row is a Markdown list item — or a heading, a paragraph, a quote, a
fenced code block, a rule — and indentation is nesting. Inline Markdown is
shown for what it means, its markup hidden: **bold**, _italic_, `code`,
~~struck~~, links, `[[wiki links]]`. The markup is still in the file, byte for
byte; it just draws nothing.

Images are drawn in place of their Markdown: `assets/…` files from the graph,
and pictures on the web, fetched once and cached. The size Reflect notes after
an image (`<!-- {"width":425,"height":270} -->`) is the size it is drawn at;
otherwise a picture is shown at its own size, never wider than the column. To
the caret an image is one character: an arrow key passes it, and Delete takes
it, size and all. A source that is not a picture — a tweet's page, a link that
no longer answers — stays as its Markdown.

A link to a post on X or Twitter written as an image
(`![](https://x.com/…/status/…)`, as Reflect's capture writes them) is shown
as a card — who, what, when, and its first picture — fetched once from X's
embed service and cached.

Pictures pasted or dropped in are saved as `assets/pasted-<time>.png`; other
files keep a readable form of their own name (`Q3 Report (final).PDF` →
`assets/q3-report-final.pdf`) and are linked by it. Nothing already there is
ever written over: a name in use gets `-2`, `-3`. Double-click a picture or a
card to open it, or right-click it to open it, show it in the Finder, copy it
(as PNG and TIFF, so it pastes anywhere) or its address, or delete it; click a link to a file in `assets/` to open it in the app
that opens it. Over a bullet, a checkbox or a picture the pointer is an arrow.

As in Bike, the caret has two places at each edge of a styled span — inside it
and outside it — side by side on screen. ← and → stop at both, and a small tail
at the caret's foot points to the side it is attached to: typed text joins the
span when the tail points into it. Delete takes the nearest shown character,
never the markup, and the last character of a span takes the span with it.
⌘K edits where a link goes (or the note a wiki link names), or makes one.

Editing follows Bike:

- Text is edited as text, a row at a time. A selection that reaches past one
  row selects **rows**, and Escape selects the caret's row. With rows selected,
  ↑ and ↓ move between them (⇧ to extend), ← and → fold and unfold, Space checks
  them off, Delete deletes them, Return starts a new row after them, and Escape
  goes back to the text.
- A row always takes its children with it — when indented, outdented, moved,
  copied or deleted.
- Return splits the row; at the end of a row with its children showing, the new
  row is its first child. ⌘Return makes a new row without touching the text.
- Typing Markdown at the start of a row, then a space, sets its type: `#` to
  `######` a heading, `>` a quote, `[]` a task, `1.` a numbered row, `---` a
  rule. Delete at the start of a typed row makes it a plain row again.
- Tasks are written `+ [ ]`, as Reflect writes them, and drawn round; `- [ ]`
  checklists are drawn square. Clicking a checkbox checks it; clicking the
  bullet of a row with children folds it.

| | |
|---|---|
| Tab, ⇧Tab, ⌃⌘→, ⌃⌘← | Indent, outdent |
| ⌃⌘↑, ⌃⌘↓ | Move up, move down |
| ⌘0, ⌘9 | Expand, collapse |
| ⌃⌘0, ⌃⌘9 | Expand, collapse completely |
| ⌥⌘0, ⌥⌘9 | Expand, collapse all |
| ⇧⌘D, ⇧⌘K | Duplicate, delete rows |
| ⌥⌘↑, ⌥⌘↓ | Expand, contract selection |
| ⇧⌘L, ⇧⌘B | Select paragraph, select branch |
| ⌘B, ⌘I, ⇧⌘\`, ⇧⌘- | Bold, italic, code, strikethrough |
| ⌘K | Edit or add a link |
| ⌘S, ⌘R | Save now, sync now |
| ⌘+, ⌘- | Type size |

The whole note is an outline, but only list items show bullets: a heading or
a paragraph between them reads as Markdown, and shows a faint ghost of a bullet
when the pointer is over it, to say it is a row all the same. Clicking a bullet
(or the ghost) of a row with nothing folded in it selects the row.

A heading at the top level holds its section: the rows after it, up to the
next heading of its rank or higher. Collapsing a heading folds its section;
moving, deleting, copying or selecting its branch takes the section along.
Indenting follows list nesting only, since that is all Markdown can indent.

The app opens where it was left: the same day at the top of the window, as far
into it, the caret or selection where it was, the rows folded as they were,
and the console if it was open. This is kept per graph in
`~/Library/Application Support/Reflect Mac/State.json` — it is how this Mac
shows the notes, so it stays out of them and out of the repository. A fold
is remembered by the row's place and its text, so it finds its row again
after the note changes elsewhere, and is dropped when the row is gone.

Folding is how a day is shown, not what it says: a folded row's children are
written out like any other.

## Files

A note is written a moment after typing stops, and only when what would be
written differs from what is there. Reading a note and writing it back
unchanged gives the same bytes — blank lines, bullet characters, indentation
and all — so a note is only ever rewritten where it was edited. A note in a
shape the editor cannot write back exactly opens read only (none of the 1,934
in the graph this was built against do).

Another app, or a sync, writing a note while it is being edited here is merged
with what was written here (`git merge-file`), keeping both sides between
conflict markers where they touch the same lines.

## Sync

The graph is expected to be a git checkout with an `origin`. Sync follows
Reflect's protocol exactly (its sync engine and `merge.rs`), so the two apps
can share a repository:

- Writing is committed thirty seconds after it stops (never more than five
  minutes after it starts) and pushed, without asking the remote for anything
  unless it has moved on.
- A full sync — commit, fetch, merge, push — runs at launch, when the app
  comes to the front, and on ⌘R. There is no timer beyond that.
- A push turned away because another device pushed first is met with a fetch
  and merge, and tried again, up to three times.
- Commit messages are Reflect's: `Update daily note for 2026-09-25`,
  `Add Project Atlas`, `Rename Old to New`, `Update 2 notes and 1 attachment`,
  `Add private note`.
- Files of 95 MB or more are left out of commits, and you are told which.
- `.reflect/` is never committed.
- A repository some other tool left mid-merge or mid-rebase, or on a detached
  HEAD, is left alone, with a message.

### The console

Window ▸ Console (⌥⌘L) shows what the app did as it happens: each sync and
how it ended, every git command with what it said and how long it took, files
added, pictures that would not load. When a sync fails, the sync button turns
into a warning that opens it. The same log is kept in
`~/Library/Logs/Reflect Mac/Reflect Mac.log`.

### Conflicts

A merge never stops the sync. Where both devices changed the same lines of a
note, both versions go into it between markers labelled `this device` and
`other device`, and the merge is committed as `Merge changes from other
devices (conflicts to review)`. A note one device changed and the other
deleted is kept; a binary file both changed keeps this device's copy and puts
the other beside it as `name (conflict).ext`.

A day whose note has conflict markers is marked **Needs Review** and shown as
its two sides — this device's in the accent colour, the other's in grey —
under Reflect's notice, with **Keep This Device's Version**, **Keep the Other
Device's** and **Keep Both**. Choosing splices the file's text directly (the
markers never pass through the editor) and the day becomes an outline again.
Every version stays in the repository's history. The window's subtitle says
how many notes need review, and Go ▸ Next Note Needing Review goes to them.

A note that changes on disk — by a sync, or another app — while you have
unsaved writing in it is not written over: saving pauses, and **Keep Mine** or
**Load Theirs** decides.

## Building

```sh
scripts/build-app.sh        # build/Reflect Mac.app
scripts/build-app.sh run    # and launch it
swift test                  # REFLECT_GRAPH=~/reflect also round-trips a graph
```

The graph is chosen on first launch (File ▸ Open Graph…, ⌘O, to change it),
or given with `-GraphPath <folder>`.

## Code

- `Sources/ReflectCore` — no AppKit. `OutlineMarkdown` reads and writes a note
  as rows; `OutlineEditing` is the outline commands on rows; `Git` and `Graph`
  are the repository and the files.
- `Sources/ReflectMac/Editor` — the outline editor: an `NSTextView` (TextKit 1)
  whose paragraphs are rows, each carrying its row as an attribute.
  `OutlineLayoutManager` draws bullets, checkboxes and selected rows.
- `Sources/ReflectMac` — the timeline (`TimelineViewController`, which keeps
  only the days near the window as views), a day (`DayView`), sync, menus.
- `Script.swift` drives the app from a script of keys, for trying it without a
  person at the keyboard: `REFLECT_SCRIPT=<file> REFLECT_SNAP_DIR=<dir>`.

## Not yet

Backlinks, focusing into a row (Bike's
⌥⌘→), and dragging rows.
