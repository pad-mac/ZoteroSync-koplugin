# Zotero Atelier — fork notes

Source project: https://github.com/Atelier-Recherche/zoteroatelier.koplugin
This fork: v0.12, 2026-10-24 (GPL-3.0, like the original).
Repository and releases: https://github.com/pad-mac/ZoteroSync-koplugin

## v0.12 — updates from GitHub

The plugin now updates itself from the releases of
https://github.com/pad-mac/ZoteroSync-koplugin.

* **Automatically after a sync**, at most once a day: when the device is
  online for the sync anyway (Wi-Fi is never turned on for this), the plugin
  asks GitHub for the latest release and, if it is newer, installs it. The
  sync's summary says so and a restart is offered: the new version runs after
  KOReader has been restarted. If GitHub cannot be reached, nothing is said.
* **By hand:** Zotero Atelier > Updates > Check for updates. It shows the
  release notes and asks before installing.
* **Nothing is replaced unless the whole update checks out:** the download
  must be complete and match the SHA-256 checksum GitHub lists for it; it
  must contain the plugin's folder with its main files; every Lua file must
  compile; and the version inside must be the release's. Each file is then
  written beside the old one and renamed over it; should that fail half-way,
  the files already replaced are put back.
* **The version it replaces is kept.** Updates > Restore the previous version
  puts it back; automatic updates then leave out the version that was taken
  out until a newer one is published.
* Automatic updates can be switched off: Updates > Install updates
  automatically.

Publishing: when a push to `main` changes the version in `zoteroapi.lua`, a
GitHub workflow compiles every Lua file, packages
`zoteroatelier.koplugin.zip` and publishes it as release `v<version>`, with
the section of these notes for that version as release notes.

## v0.11 — "Discard" in the popup after a selection

With KOReader set to highlight a selection at once and to ask for the colour
(Long-press on text: "Highlight action: Highlight", "Highlight prompt:
color", or style, or both), lifting the finger brings up a list of colours.
Everything one can do there makes a highlight - a tap on a colour, and a tap
beside the list too (it takes the current colour) - so a selection that went
wrong had to be highlighted first and then deleted through the highlight's
own dialog.

The list now has one more row at the bottom, **Discard**: the selection is
dropped, nothing is highlighted, and the passage can be selected again right
away. The same row is in the list of styles, and in the list that follows
"Highlight" or "Add note" in the reader's selection menu. A tap beside the
list still highlights in the current colour, as before.

* It is KOReader's popup, so this applies to every document, not only to
  Zotero's. It can be switched off: Settings > "Discard" in the popup after
  selecting text.
* The list remains KOReader's own widget with a row added. Should a future
  KOReader build its popup differently, the plugin leaves it alone (the
  setting is then greyed out), and if adding the row fails, KOReader's own
  popup comes up: highlighting is never blocked by this.
* Done in the plugin rather than as a KOReader user patch: one thing to
  install, a setting to switch it off, and covered by the plugin's tests.
* A highlight that was already made (a colour was tapped) is removed as
  before: tap the highlight, Delete.

## v0.10 — a profile per kind of document, and a clearer browser

**Profile per kind of document** (Settings). For PDFs, EPUBs and web
snapshots one of KOReader's profiles can be chosen each; its settings (font,
font size, margins, line spacing, zoom, contrast, whatever the profile
holds) are applied when a Zotero document of that kind is opened.

* Profiles are KOReader's own: Tools > Profiles. The quickest way to make
  one is to open a document of the kind, set it up as it should look, and
  choose "New with current book settings" there.
* Only documents that belong to Zotero are touched; other books keep to
  KOReader's rules (which has its own "auto-execute on book opening" for
  those).
* A document takes the profile once, and again after the profile has been
  changed or another one chosen. What is adjusted in a single document in
  between stays: the profile sets the starting point for a kind, it does not
  undo changes at every opening.
* A profile that was deleted or renamed in KOReader is shown as such in the
  menu and nothing is applied. It also works with KOReader's Profiles plugin
  switched off (the profiles are read from its file).

**The browser.**

* Collections are set in bold, with a folder in front, and no longer end in
  "/". The path under the title is written `/Collection/Sub-collection`.
* A collection that is set to "Download this collection during sync" has a
  filled folder with an arrow pointing down. Long-pressing a collection and
  changing the setting updates the folder at once.
* An entry shows the kind of file a tap on it opens (PDF, EPUB, WEB for a
  snapshot; the same order of preference as the tap): black with a filled
  band when the file is on this device, grey with an empty band when it has
  to be downloaded first. An entry with several files of that kind is black
  only if all of them are there; a copy that is older than Zotero's counts
  as not there, because opening it downloads the new one. Entries with
  nothing to open here (links only, no attachment) have no picture.
* The pictures are drawn by the plugin, not taken from a font or image
  files, and sized by the list's text; they are looked up only for the rows
  of the page shown, so large collections open as fast as before.
* The files, links and notes of entries are no longer listed as rows of
  their own at the top level and in "All Items" (they have no collection, and
  the top level showed every one of them after the collections). A file that
  is an entry of its own is still listed.
* "All Items" is one level below the top (one Return leads back; it used to
  take two, with an empty page in between), and Return after two searches in
  a row goes back to the first.

## v0.9 — annotations in web snapshots

Highlights and underlines now sync in both directions for the HTML snapshots
Zotero saves of web pages, with the same rules as for PDF and EPUB (colours,
comments, edits, deletions, the delete log, nothing sent without a sync you
start).

**How Zotero addresses a place in a snapshot.** Not by its text: by a CSS
selector for an element plus character offsets counted over that element's
text nodes (`{"type":"CssSelector","value":"#content > p:nth-child(3)",
"refinedBy":{"type":"TextPositionSelector","start":12,"end":40}}`), in the
document tree Zotero's reader builds: the file read as UTF-8 by an HTML5
parser, `<base>`, `<noscript>` and content-security `<meta>` removed, written
out and parsed a second time. KOReader has another parser, another tree and
no CSS selectors. So the plugin carries its own HTML5 parser
(`zotero_htmlparse.lua`, with the full entity table) to build Zotero's tree
from the file, a small selector engine to resolve and to write selectors the
way Zotero does, and matches that tree with KOReader's by text.

**Nothing is guessed.** A place is carried from one tree to the other only
through text that occurs exactly once in both (the window is grown until it
does). Going to Zotero, the result is carried back and must be the selection
again, and the written position must resolve to it. Coming from Zotero, the
passage found must carry the annotation's own text (short texts exactly), and
is checked in the open document before it is stored; a position whose text
is not there is looked for by its text near the place Zotero's sort index
names, and otherwise the annotation is left in Zotero and reported as not
placed. A selection that cannot be carried with certainty is not uploaded,
and says why.

**Snapshots are prepared for KOReader's engine.** KOReader's HTML parser
ends a tag at the first `>`, even inside a quoted attribute value. Saved
pages are full of such values: SingleFile, which Zotero uses, writes the
document of every frame into `srcdoc="<html>..."`, and pages carry pictures
and tooltips as markup in attributes. KOReader then shows attribute text as
page text, or, after a frame, nothing more of the page. The plugin therefore
rewrites *its own copy* of a snapshot once: `>` inside attribute values
becomes `&gt;` (the same value to every HTML parser) and the inline documents
of frames are emptied (KOReader does not display frames). Before the copy is
used it is parsed again and must give the same tree as the original, so
Zotero's positions mean the same in both. This happens when a snapshot is
downloaded, when an entry is opened from the Zotero browser, and - once, with
the page being opened again - when a snapshot stored by an earlier version is
opened from KOReader's history. Never rewritten: linked files, files in
Zotero's own storage folder (external storage setting), pages that are not
UTF-8, and a copy that already carries highlights made in KOReader (their
positions belong to the page as it was read before).

**KOReader's own output is read strictly.** The plugin learns KOReader's
tree from the engine's HTML dump, which writes attribute values unescaped
(`alt="... <a href="...">"`). Where a tag ends was a heuristic; it is now
decided by the form of the whole dump (every element closed by its own name,
text only between the engine's text marks), with readings taken back when
the form breaks. This also serves EPUBs.

What was checked, and how:

* Zotero's side is Zotero's own reader code (selector creation, resolution,
  sort index, annotation text), run unchanged in headless Chromium on the
  document built the way the reader builds it. Against it: the plugin's
  tree is identical on 175 real pages (130 pages of Mozilla's Readability
  test set, 45 of them saved again with SingleFile); the HTML parser passes
  1541 of 1592 html5lib tree-construction tests (the rest: framesets, which
  are refused, and a `<select>` parsing change browsers are adopting only
  now); the plugin resolves 6879 of 6880 reference positions as Zotero does
  and, for these, writes positions and sort indexes identical to Zotero's.
* In KOReader's engine (Linux build of the same version), on the 45
  SingleFile snapshots, prepared as described: of 1760 Zotero annotations
  1730 land on their text, 30 are not placed, none lands elsewhere; of 1800
  selections made in KOReader 1759 are uploaded, 41 refused, and all 1759
  resolve in Zotero's code to the selected text (1717 written character for
  character as Zotero would have). Nearly all of the 30 and 41 are one page
  of formulas and the options of a drop-down list. On the 130 pages as they
  come from the web (scripts, `<noscript>` and all): 5040 of 5120 placed,
  4911 of 5120 uploaded, none wrong.
* The whole path in a running reader with the plugin loaded (mock server):
  download, preparation, import on opening, upload, edits and deletions in
  both directions, closed documents - on five pages, with what was uploaded
  resolved by Zotero's code.

Limits:

* Not tested against the real Zotero server or apps, nor on the device.
  Zotero's desktop reader runs on Firefox's engine; the reference here is
  Chromium. The two parse HTML by the same standard, but this is the largest
  untested assumption.
* Highlights and underlines only. Zotero's note and image annotations on
  snapshots have no counterpart in KOReader and are left alone.
* Text the two readers do not share cannot be annotated across: formulas
  (KOReader typesets MathML itself), the options of drop-down lists, text a
  page hides in a browser but KOReader shows (or the reverse), `<noscript>`
  text (Zotero removes it; rare in snapshots, which are saved without
  scripts). A highlight may run across such text; it cannot begin or end in
  it.
* A passage that repeats in the page (menus, lists of links) is placed only
  if its surroundings tell the occurrences apart; otherwise it is refused
  rather than put on the wrong one.
* Pages that are not UTF-8: Zotero's reader decodes every snapshot as UTF-8,
  KOReader honours the page's own declaration, so non-ASCII text differs.
  ASCII passages still sync. (SingleFile saves UTF-8; this concerns old
  snapshots.)
* A page with a `<template shadowrootmode>` is read differently by older
  and newer browser engines; the plugin reads such positions both ways and
  writes them in the form that means the same in both (offsets from the
  start of the page).
* Framesets and pages using `<plaintext>` are refused.
* The reading position of snapshots is not synced (Zotero stores a scroll
  offset in pixels of its own layout).
* As for EPUBs, Zotero positions for new KOReader highlights are worked out
  while the page is open (at closing time at the latest); highlights made
  before this version in a page that has not been opened since are uploaded
  after it has been opened once.

## v0.8.1

* **Entries with a link among their attachments.** Tapping an entry opened
  its first PDF, or else its *last* attachment by name, whatever that was.
  With a "Google Books Link" (or any other link to a web page) sorting last,
  the answer was an error although an EPUB or a snapshot was there. Now the
  entry opens its file: PDF before EPUB before web snapshot; links are never
  candidates. If it has several files of the best kind (two PDFs), a short
  list asks which. An entry with links only says so.
* Links are no longer tried by the offline-collection download (they showed
  up as "Attachment download errors" after every sync).
* The entry details (long-press) label links as links, and no longer fail
  for entries without an abstract (standalone notes).
* Web snapshots made of several files (older snapshots), which Zotero stores
  as a zip, are unpacked after the download. Zip archives are now unpacked
  with KOReader's own library; the WebDAV download relied on an `unzip`
  program that Android devices do not have.
* **Sync that seems to wait for a touch.** While a sync runs, the plugin now
  asks Android to keep the screen on (the user's screen timeout is put back
  afterwards). Onyx devices are known to put the processor to sleep when
  nothing is touched, which stops timers and network traffic. Whether this
  flag is enough on a given Boox cannot be tested here; if not, the Boox's own
  power settings for KOReader are the place to look.

## v0.8 — reading position

Zotero remembers where each attachment was last read and syncs that between
its own apps: a setting per attachment (`lastPageIndex_u_<key>`), holding the
page index for a PDF and a position inside the chapter (a CFI) for an EPUB.
It has a version but no time stamp; whoever wrote last is where the document
opens. The plugin now reads and writes the same setting.

* **Zotero → KOReader.** A sync downloads the positions that changed. When a
  document is opened (or at once, if it is open during the sync) and Zotero's
  position is one this device has not seen yet, the reader goes there, says so
  ("Zotero: continued on page N"), and keeps the place it came from on
  KOReader's location stack: "Go back to previous location" returns. A
  position is applied once; after that the reader's own place counts again.
* **KOReader → Zotero.** Only with a sync you start ("Synchronize" for all
  documents on the device, "Sync document annotations" for the open one):
  the place reached here is sent if it changed since the last sync and
  Zotero's did not. If both changed, Zotero's is applied (see above) and
  nothing is overwritten; going back and syncing again sends yours.
* **First contact.** A document that was already read here and also has a
  position in Zotero keeps its place here, and Zotero keeps its own, until
  one of them moves. A document read here that has no position in Zotero
  sends its place with the first sync (one small request per document, so
  that sync takes a little longer once).
* **EPUB.** KOReader's place is a pointer into its own document tree and can
  only be translated while the book is open, so it is worked out when the
  book is closed and sent by the next sync. A book that was last closed
  before this version sends nothing until it has been opened once. Positions
  are exact to the text (or picture) at the top of the page; the two readers
  paginate differently, so "the same page" does not exist. A place that
  cannot be translated with certainty (formula-heavy chapters, chapters
  without text) is not sent. If only the
  chapter of a Zotero position can be found (another edition of the file),
  the reader goes to the chapter's beginning, unless it is in that chapter.
* Opening a document from the plugin's annotation search goes to the
  annotation, not to Zotero's position.
* Switch: Zotero Atelier → Settings → "Sync the reading position" (on).
* Also fixed: the short notice after opening a Zotero document ("3
  annotations added from Zotero") was only shown when KOReader's notification
  level happened to allow it. It is always shown now.

Zotero side, read in its source code (desktop app): the position is written
whenever the page changes and synced with the rest of the library; a document
that is already open in a Zotero tab does not move, the new position is used
the next time it is opened.

Tested here: 113 checks of the sync logic for closed documents and of the
settings requests (stand-in server written from Zotero's server code:
versions, 412, 428, value types); 159 checks in the reader for PDF and EPUB
(opening, back, both syncs, closed documents, unusable positions).

EPUB positions were checked against Zotero's own reader code on 23 books (5
purpose-built, 18 public samples), comparing the text that follows the point:

* Zotero → KOReader, 12,475 positions written by Zotero's code: 11,811 land
  on their text or picture; 628 reach only the chapter (all in one maths
  textbook typeset with MathJax, whose chapters the plugin does not map); 34
  sit at formulas whose text the two engines render differently, so there is
  nothing to compare; 2 are in a sentence KOReader's engine does not load
  (malformed test file) and land next to it. None in a wrong place.
* KOReader → Zotero, the top of 1,653 pages: 1,604 converted, 49 refused (40
  in the maths textbook, the rest in chapters without text) and therefore
  not sent. Of the 1,604, Zotero's code resolves 1,591 to the same text or
  picture; 12 are at formulas (nothing to compare), 1 is in a chapter Zotero
  cannot display. None in a wrong place.
* A position is matched between the two readers by the text around it and is
  accepted only if that text occurs exactly once in the chapter; otherwise it
  is refused. Pictures are matched by their place in the text.

Not tested: the real Zotero server and apps, and the device.

## v0.7.1

* Fixed: tapping a colour in Settings → Highlight colours crashed KOReader
  (a loop variable hid the translation function). The same kind of mistake
  sat in two older places and is fixed there too: long-pressing an entry of
  the plugin's "Document annotations" list, and of "View search root folders".
* Red, blue, purple and magenta are darker by default (50 %), orange 36 %.
* Clearer names in the colour menu.

## v0.7 — highlight colours

KOReader draws a coloured highlight by tinting the page with one fixed colour
per name. On a grey e-ink screen only the brightness of that colour is left:
its yellow is almost white (invisible), its blue, purple, red and green are so
dark that the text is hard to read. And its colour list does not match
Zotero's (no magenta; olive and cyan instead).

* **Zotero's colours in the reader's colour menu**: yellow, red, green, blue,
  purple, magenta, orange, gray, in Zotero's order. Magenta is now a colour of
  its own in both directions (it used to arrive as purple; such highlights are
  renamed at the next sync, nothing is uploaded for that).
* **Readable grey tints** on screens without colour: every colour is drawn as a
  grey of a set darkness. Defaults: yellow 14 %, green 28 %, orange 36 %, red,
  blue, purple and magenta 50 %. Each can be changed. Gray keeps following the
  reader's own "Gray highlight opacity".
* Menu: Zotero Atelier → Settings → Highlight colours. Both parts can be turned
  off; KOReader's own list and colours are then back. Tints are on
  automatically when the device has no colour screen; on a colour screen
  Zotero's real colours are used instead.
* How: the reader's colour list and palette are plain tables that it looks up
  whenever it shows the menu or draws a highlight. The plugin replaces their
  contents while KOReader runs. No file of KOReader is changed, annotations
  keep their colour *name*, sync is not affected. It applies to every book.
* Olive and cyan highlights that exist stay as they are (also in Zotero) and
  are drawn like green and blue; they are just not offered for new highlights.
* Known side effect: with "Write highlights into PDF files" turned on, the
  colour written into the PDF is the tint, not the colour.

## v0.6.1

* The one-time check of the library after the update no longer downloads the
  library again. The versions of the items stored on the device are compared
  with the server's (two small requests); only items that differ are fetched,
  and items found in Zotero's trash are removed. The existing `zotero.db` is
  used as it is. If the first sync with v0.6 was stopped half-way, v0.6.1
  continues from what is stored.
* Progress messages say that tapping them stops the sync.
* A sync that changes nothing in a closed document no longer rewrites its
  settings file (it sometimes did).

## v0.6 — two-way annotation sync, rebuilt

### What was wrong in v0.5

1. **Zotero annotations in the wrong place or missing (PDF).** KOReader does not
   draw stored rectangles. It keeps two points and highlights the words between
   them. v0.5 converted Zotero's rectangles with the page height alone (no
   CropBox origin, no `/Rotate`, no `/UserUnit`) and put the two points one
   point inside the corners of the first and last rectangle. Whenever a corner
   did not fall inside the right word, the reader highlighted other words.
2. **Zotero annotations missing (EPUB).** They were written into EPUB sidecars in
   the PDF format. KOReader cannot show those, and when such an entry came first
   it set the whole list aside, hiding the reader's own highlights as well.
3. **Uploads refused.** Annotations were uploaded before the library was
   downloaded, and every upload carried `If-Unmodified-Since-Version` with the
   stored library version. If anything at all had changed in the library since
   the last sync (in the log: stored version 41448, server at 41495), the server
   refused the whole request with 412, every time. On top of that: an upper-case
   colour value for blue (rejected by the server), JSON `null` treated as data,
   and the error in the log (`annotations.lua:161: attempt to perform arithmetic
   on local 'page'`), which aborted the document's sync.
4. **"Rebuilding local index" on every sync.** The full index rebuild ran after
   every download, however little had changed. It also wiped the record of
   which attachments are on the device.
5. **Changes made in Zotero could be skipped for good.** The stored library
   version was moved forward by the plugin's own uploads, and to the highest
   version seen while paging. Items in Zotero's trash were never noticed.

### How it works now

* **PDF, Zotero → KOReader.** Rectangles are converted with the page's real
  transform (page boxes read from the file, cross-checked against MuPDF), the
  words under them are found, and the two points are put on the first and last
  of those words. The result is compared with the annotation's text; if they
  disagree the passage is located by its text. An annotation that cannot be
  placed verifiably is not written at all (and reported).
* **PDF, KOReader → Zotero.** Rectangles are built from the selected words and
  converted back with the same transform; page label and sort index as Zotero
  computes them.
* **EPUB, both directions.** Zotero addresses EPUB text by a CFI into the
  chapter's XHTML as its reader builds it; KOReader by an XPointer into
  crengine's tree. `zotero_epub.lua` models both trees and maps between them,
  and checks every result against the open book. Positions can only be
  converted while the book is open: Zotero annotations of a closed EPUB appear
  when it is opened; a new EPUB highlight gets its Zotero position when the
  book is closed and is uploaded by the next sync.
* **Merge.** Each synced annotation remembers what it looked like on both sides
  when they last agreed (`zoteroSync`). Per field: changed in Zotero → applied
  here; changed here → uploaded; changed on both sides → notes are joined,
  everything else goes to the later edit.
* **Uploads** carry key and version per annotation and no library-version
  precondition. New annotations get their key on the device, saved before the
  request is sent: a repeated or half-answered upload cannot create duplicates,
  and an edit made in Zotero meanwhile is never overwritten.
* **Deletions.** Nothing is deleted because it is absent. A local annotation is
  removed only when Zotero's delete log (or trash) names it, and not if it was
  edited here since the last sync (then it is kept and sent again). A Zotero
  annotation is deleted only when its highlight was deleted in the reader, which
  is recorded at that moment in the document's settings.
* **Library download.** Incremental: only changed items are stored and indexed.
  The stored library version is the lowest one the server reported during a
  download, so nothing can slip through. Trashed items and restores are followed.
* **Files and attachments.** A file is treated as an attachment's only when
  there is no doubt (its storage folder is named after the attachment's key, or
  a linked attachment names exactly this file, or the name is unique). Two
  attachments with the same file name are never mixed up.

### What you will notice

* The **first sync after installing checks the whole stored library against
  the server**, once: item versions are compared and only what differs is
  downloaded (the existing database, offline collections and downloaded files
  are kept). After that, sync is incremental.
* On that first sync, highlights made in KOReader that never reached Zotero are
  uploaded, misplaced imports are moved to their passage, and annotations that
  were deleted in Zotero disappear from the documents.
* Opening a Zotero document brings its annotations up to date from the local
  library copy. No network, no upload.
* "Synchronize" = library, then annotations of all documents on the device, then
  offline attachments. "Sync document annotations" = the open document only.
* Tapping the progress message offers "Stop"; the sync then ends after the
  piece of work in hand. (There is no button: KOReader's progress message is
  plain text, the tap is the control.)
* "Write highlights into PDF files" is off for Zotero documents unless turned on
  in the plugin's settings.

### Not synced (by design or by Zotero's rules)

* Zotero's note, image, ink and text annotations (KOReader has no counterpart;
  they are counted in the sync message and left alone).
* KOReader page bookmarks, and highlights without text.
* The drawing style of an existing annotation (Zotero does not allow an
  annotation's type to change).
* EPUB highlights that run across two chapters (Zotero cannot store them).
* Chapters Zotero itself cannot annotate reliably: MathJax-typeset chapters,
  text inside CDATA sections, spine items that are not XHTML.

### Tested here, and what that covers

The plugin was run inside the KOReader 2026.07 runtime (real ReaderUI, MuPDF,
crengine, SQLite; plugin loaded by KOReader's own plugin loader):

* PDF placement: 372 Zotero annotations over 16 PDFs (cropped, rotated, shifted
  boxes, `/UserUnit`, object streams, encrypted) land on exactly their text;
  225 positions created here were checked independently with PyMuPDF.
* EPUB: Zotero's own reader code (its epub.js fork and CFI code) was run to
  produce and to resolve reference positions. Four purpose-built test books
  and 11 public sample books (among them Hebrew and Arabic): no wrong
  placement in either direction; what cannot be converted is refused with a
  reason. A Japanese book with ruby text passed the import direction and the
  round trip; the independent check of its upload direction did not finish in
  the test environment. The tree model was compared with Zotero's node by node
  on 16 sample books, including a MathML textbook (about 615,000 text nodes,
  no difference).
* Sync logic: 402 checks against a stand-in for the Zotero server written from
  the server's source code (versions, 412/404/428 answers, trash, delete log,
  validation, paging, throttling), covering the upgrade from v0.5, lost
  answers, interrupted batches, conflicts, deletions and restores, read-only
  keys, and files with identical names.
* In the reader: 220 checks (open, import, highlight, delete, sync, close,
  reopen, for PDF and EPUB; stop; errors; a conflicting second plugin).

**Not tested:** the real Zotero server (not reachable from the build
environment), WebDAV, and the device itself (Android, e-ink, your library).
A second, independent code review was started and did not finish.
The first run on the device is the real test; `crash.log` lines starting with
`Zotero` say what was done.

### Unchanged from v0.5

Browser, search, item info, WebDAV and linked-file settings, offline
collections. (The top level of the browser still lists child attachments next
to the collections, as in v0.5.)

---

## Earlier versions

### v0.5 safety changes
- HTML/snapshot annotation sync disabled; only PDF and EPUB are accepted.
- Remote Zotero annotation deletion disabled (local absence is not a safe tombstone).
- Automatic outbound sync on document open/close disabled; writes are manual.
- Global annotation sync isolates per-file errors and skips unsupported attachments.

### v0.4
- Progress while rebuilding the local index; rebuild in a single SQLite transaction.

### v0.3
- Fixed initial collection sync abort (`fetchCollectionSize()` returned headers in the error slot).

### v0.2
- Readable sync statuses and errors; hardened JSON response handling; sync stage markers.

### v0.1
- Fixed the Lua syntax error in `annotation_panel.lua`, the initial-sync SQLite
  username write, deprecated `_meta.lua` field, author formatting, `os.delete`.
