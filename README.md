# Kokomga-Bookshelf Bridge (`kokomga-bookshelf-bridge.koplugin`)

A non-invasive integration plugin for KOReader that connects Kokomga and Bookshelf, sharing authentication profiles, cover caches, and server health checks, while adding document-aware AutoRTL.

## My Use Case

I use Kokomga to sync with my Komga media server and Bookshelf to manage and display my library on my e-ink device. I wanted seamless interoperability without modifying the source code of either upstream plugin.

My setup encountered three major issues:
- Kokomga and Bookshelf maintained isolated configurations. Setting up server addresses, credentials, and network profiles had to be repeated, and cover image caches were duplicated.
- Kokomga's default AutoRTL setting forced right-to-left reading direction across all documents, which broke reading flow for my Light Novels (EPUBs and text-dense PDFs) where left-to-right paging is required.
- When my Komga server was unreachable or offline, automated network operations (such as auto-downloads) would hang, causing Android ANR ("Application Not Responding") errors.

I developed this bridge plugin to solve these problems cleanly:
- It hooks both plugins at runtime to share server profiles, credentials, and cached cover images.
- It introduces an "AutoRTL Advanced" setting that analyzes documents on load: Manga (CBZ, CBR, archive scans, and image PDFs) is set to right-to-left reading order, while Light Novels (EPUBs and PDFs with more than 20 words per page) are preserved or reverted to standard left-to-right order.
- It adds lightweight, fast-fail health checks with short socket timeouts to eliminate ANR dialogs when the server is offline.

## General Use Case

This plugin acts as a coordination layer between Kokomga and Bookshelf in KOReader without requiring forks or code modifications to either plugin.

Key features include:
- Unified credential and network profile management between Kokomga and Bookshelf.
- Shared cover cache mapping, preventing redundant image downloads and decoding.
- AutoRTL Advanced: intelligent document classification that applies right-to-left page turning only to Manga, keeping Light Novels, EPUBs, and text PDFs left-to-right.
- Non-blocking server reachability checks to guard against UI lockups and Android ANRs.
- Extensible API for other plugins to check server status or classify documents.

## Dependencies

- [KOReader](https://github.com/koreader/koreader): Document viewer for e-ink devices and Android.
- [Kokomga](https://github.com/zenf/kokomga): Komga client plugin for KOReader.
- [Bookshelf](https://github.com/koreader/koreader): Visual bookshelf plugin for KOReader.

### Related Plugins

- [bookshelf-hybrid.koplugin](https://github.com/oauei/bookshelf-hybrid.koplugin): Hybrid shelf source that benefits from this bridge's profile switching and offline safety checks.
- [boox-cover-sync.koplugin](https://github.com/oauei/boox-cover-sync.koplugin): Screensaver cover sync plugin that can share this bridge's document classification logic.

## Installation

Clone this repository into your KOReader plugins directory:

```bash
cd <koreader-directory>/plugins/
git clone https://github.com/oauei/kokomga-bookshelf-bridge.koplugin.git
```

Restart KOReader. The bridge will automatically detect Kokomga and Bookshelf if they are present. To use AutoRTL Advanced, disable standard AutoRTL in Kokomga settings and enable AutoRTL Advanced in the bridge menu.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
