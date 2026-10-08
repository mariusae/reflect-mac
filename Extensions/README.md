# Reflect Capture

A browser extension that saves the page you are on into your Reflect notes, as
Reflect's own clipper does: a note of its own — its title, address and
description, the passages you highlighted, and a screenshot — linked from today
under `[[Links]]`. Capturing a page again adds what is new to the same note.

Highlight on any page by selecting text and pressing ⇧⌘H. Capture with the
toolbar button (⇧⌘Y). Both keys can be changed at `chrome://extensions/shortcuts`.

Pages are saved through Reflect Mac, which must be running: it listens on
`127.0.0.1:47811` for the extension alone. The first time, the extension asks to
connect and Reflect Mac asks you to allow it.

- `Browser/` — the extension itself, for Chrome and Safari alike.
- `Safari/` — the Mac app Safari needs to carry it, made from `Browser/` by
  `xcrun safari-web-extension-converter`; its extension uses those same files.

## Chrome

`chrome://extensions` → turn on **Developer mode** → **Load unpacked** → choose
`Extensions/Browser`.

## Safari

Build and run the app — `Extensions/Safari/Reflect Capture/Reflect Capture.xcodeproj`,
signed with your team — then turn the extension on in Safari ▸ Settings ▸
Extensions. A build signed only locally needs Safari ▸ Develop ▸ Developer
Settings ▸ **Allow unsigned extensions**.

# Prism Capture

`Prism/` is the same extension for Prism: it saves pages the same way, into the
same kind of note, through Prism — which listens on `127.0.0.1:47821`, beside
Reflect Mac's — and its popup shows the page as Prism will, as a card: the site
and when, a screenshot, the title (editable), its description, and the passages
highlighted. It can also save a page to **Today** instead: a plain bullet
linking to it at the top of today's note, its highlights under it, and no note
of its own. The choice is remembered. Both extensions can be installed at once.

`chrome://extensions` → **Developer mode** → **Load unpacked** → choose
`Extensions/Prism`.

For Safari, `Safari/Prism Capture/` carries it as `Safari/Reflect Capture/`
carries Reflect's, from the same files in `Prism/`: build and run
`Prism Capture.xcodeproj`, signed with your team, then turn it on in Safari ▸
Settings ▸ Extensions (a build signed only locally needs **Allow unsigned
extensions**, as above).
