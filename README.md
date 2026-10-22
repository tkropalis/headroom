# Headroom

A menu bar app that keeps enough free space on this Mac's internal disk. It shows free space, warns before it runs low, notices folders that grow fast, and cleans known caches and build output when you ask. Nothing is deleted without a confirmation that names what will happen, and every cleanup reports the space it actually freed.

Design context: [PRODUCT.md](PRODUCT.md), [docs/design-brief.md](docs/design-brief.md), prototype source in `docs/prototype`.

## Build and install

```bash
scripts/build-app.sh --install
```

This builds `Headroom.app` into `~/Applications` and the `headroom` command into `~/.local/bin`. Open the app once; turn on **Open Headroom at login** in Settings.

Requires macOS 26 or later and Xcode 26.

## Command line

```bash
headroom status                 # free space
headroom scan                   # what can be cleaned, by group
headroom clean --dry-run        # the plan for the Ready group, without cleaning
headroom clean npm-cache gradle # clean specific items (ids from `headroom scan`)
headroom history                # past cleanups and measured space freed
headroom growth --record        # take today's folder-size snapshot
```

## How it works

- `Sources/HeadroomCore` holds everything that isn't UI: disk status, folder sizing, the catalogue of known caches, the project finder, the scanner, the cleaner, growth tracking and stored history. The app and the command share it.
- **Sizes.** Folders are measured like `du`, and also with APFS's per-file *private size*, which leaves out blocks shared with clones. When the two differ a lot, the size is shown as "up to". The real gain is measured from free space before and after each item.
- **Groups.** *Ready to clean* (caches, build output: nothing lost), *Rebuilds on use* (Gradle, Docker images, simulator caches), *Your call* (moved to the Bin), *Dormant projects* (dependencies of projects with no commit or edit in 90 days).
- **Safety.** Caches of running apps are cleaned only after the app quits, with your confirmation. Build folders of projects with a running dev server are skipped. A fixed list of folders (home, Library, Documents and others) can never be deleted, whatever the catalogue says.
- **Data.** Settings live in the app's defaults. Scan results, snapshots and history are JSON in `~/Library/Application Support/Headroom`.

## Development

```bash
swift test                                  # core tests
swift build --product HeadroomApp           # debug build of the app
.build/debug/HeadroomApp --preview review   # open one screen in a window: main, main-alert, review, review-yourcall, result, growth, settings
```

The app's build product is `HeadroomApp`, not `Headroom`: on a case-insensitive disk it would overwrite the `headroom` command.
