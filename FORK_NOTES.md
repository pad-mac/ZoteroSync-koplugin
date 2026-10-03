# Zotero Atelier — fork notes

Source project: https://github.com/Atelier-Recherche/zoteroatelier.koplugin
This fork: v0.8.1, 2026-10-03 (GPL-3.0, like the original).

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
