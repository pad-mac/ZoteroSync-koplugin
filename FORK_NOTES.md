# Zotero Atelier — fixed test fork

Source project: https://github.com/Atelier-Recherche/zoteroatelier.koplugin
Snapshot prepared 2026-10-02 for KOReader testing.

This is a test fork of the GPL-3.0 Zotero Atelier plugin. It keeps the upstream UI,
annotation conversion, EPUB/PDF support, local-file handling and annotation search,
with a repaired API layer for the current KOReader runtime.

## Fixes in this build

- Fixed the Lua syntax error in `annotation_panel.lua` (`ui.paging:onGotoPage` used as a value).
- Fixed the initial-sync SQLite username write by using bound parameters rather than
  interpolating the Zotero username into SQL.
- Removed deprecated `_meta.lua` `name` field (the `.koplugin` folder name identifies the plugin).
- Hardened author formatting for one-field/corporate Zotero creators.
- Replaced the non-standard `os.delete` reset fallback with `os.remove`.
- Reworked the Zotero API/database layer to retain the public API used by the Atelier UI,
  including library/collection sync, attachment opening/downloading, WebDAV, local/linked
  file resolution, offline collections, PDF/EPUB annotation create/update/delete, and
  annotation search.

## Test status

All Lua runtime files pass a `loadfile()` syntax compile using Lua (texlua) in the build
environment. The plugin has not been executed inside KOReader here; the Boox test is the
runtime validation step.


## v0.2 — 2026-10-02
- Added safe formatting for table-valued sync statuses/errors so KOReader no longer displays `table: 0x...`.
- Hardened Zotero JSON response handling; undecodable/empty responses now produce a readable error and log the endpoint/stage.
- Added sync stage markers for access, collections, items, annotations, and offline attachments.
- No feature behavior intentionally changed beyond diagnostics/error handling.


## v0.3 (2026-10-02)
- Fixed initial collection sync abort: `fetchCollectionSize()` accidentally returned successful HTTP response headers in the error slot.
- Zotero HEAD responses such as `total-results: 118` are now treated as successful collection-size results.

## v0.4 (2026-10-02)
- Show progress while rebuilding local collection/attachment/annotation indexes after item download reaches 100%.
- Wrap the relationship-index rebuild in a single SQLite transaction to avoid thousands of individual disk syncs on Android/e-ink devices.
- Remove a redundant second attachment/annotation relationship write after the full rebuild.


## v0.5 safety changes
- HTML/snapshot annotation sync disabled; only PDF and EPUB are accepted.
- Remote Zotero annotation deletion disabled (local absence is not a safe tombstone).
- Existing Zotero PDF annotation geometry is preserved verbatim on updates.
- Automatic outbound sync on document open/close disabled; writes are manual.
- Global annotation sync isolates per-file errors and skips unsupported attachments.
- Per-document sync reports failed operations instead of always claiming success.
