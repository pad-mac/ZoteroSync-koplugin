# ZoteroSync for KOReader (Zotero Atelier fork)

A KOReader plugin that keeps your Zotero library and KOReader in step:

- **Annotations both ways** for PDFs, EPUBs and web snapshots: highlights and
  underlines with their colours and comments, edits and deletions. Nothing is
  sent to Zotero without a sync you start.
- **Reading position**: a document opens where Zotero last was; a sync sends
  the place reached in KOReader.
- **Collection browser** with the download state of every file, offline
  collections, search.
- Zotero's highlight colours in the reader, readable on grey e-ink screens;
  a "Discard" button in the colour popup after a selection; a KOReader
  profile per kind of document.
- **Updates itself** from the releases of this repository.

What changed in each version, what was tested and what the limits are:
[FORK_NOTES.md](FORK_NOTES.md).

## Install

1. Download `zoteroatelier.koplugin.zip` from the
   [latest release](https://github.com/pad-mac/ZoteroSync-koplugin/releases/latest).
2. Unpack it into KOReader's `plugins` folder, so that there is a folder
   `koreader/plugins/zoteroatelier.koplugin`. If an older copy is there,
   replace it (your settings and downloaded files are kept elsewhere).
3. Restart KOReader. The plugin is in the top menu, in the search tab (the
   magnifying glass) and under Tools: Zotero Atelier.
4. Zotero Atelier > Settings > Configure Zotero account: your Zotero user ID
   and an API key with write access (both at https://www.zotero.org/settings/keys).

## Updates

After a sync, at most once a day, the plugin looks for a newer release and
installs it; the new version runs after KOReader has been restarted. Zotero
Atelier > Updates has "Check for updates", the switch for automatic updates
and "Restore the previous version". An update is checked completely
(checksum, files, version) before anything is replaced.

If an update ever leaves the plugin unable to start, install the release you
want by hand as described above.

## Publishing a version (for the maintainer)

1. Set the version in `zoteroapi.lua` (`fork v0.13 (date)`) and add a
   `## v0.13 …` section at the top of `FORK_NOTES.md`.
2. Commit, then tag and push: `git tag v0.13 && git push origin main v0.13`.
3. The workflow in `.github/workflows/release.yml` checks the version and
   that every Lua file compiles, and publishes the release with the zip.
   Devices pick it up after their next sync.

## Credits and licence

Based on [Zotero Atelier](https://github.com/Atelier-Recherche/zoteroatelier.koplugin),
itself a continuation of the community Zotero plugin for KOReader.
GPL-3.0, like the original: see [LICENSE](LICENSE).
