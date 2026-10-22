# Headroom v2: design brief

Status: draft for review, 22 Oct 2026. Builds on [design-brief.md](design-brief.md); everything there still holds unless this brief changes it.

## 1. Summary

v1 answers "is space fine, and what can go without a cost". v2 adds three answers:

- **Where did the space go?** A Space Map window that accounts for the whole disk.
- **When will it run out?** A free-space history and a runway line.
- **What if I want to keep it?** Two ways to get space back without deleting anything: sharing space between identical files, and offloading big things you rarely use.

It also finds more to clean (developer leftovers, forgotten large files) and makes cleanup feel finished: the bar visibly drains, Bin items can be put back, everything works from the keyboard, and a first-run flow sets up Full Disk Access.

Measured on this Mac on 22 Oct 2026, so the design has real numbers: 18 GB free (below the 20 GB warning), 2 GB more that macOS can purge on its own, a 3.1 GB Android emulator, 2.3 GB of Android system images, 2.2 GB in 9 iOS simulators, 553 MB of Xcode archives and a 388 MB pnpm store.

## 2. Principles, extended

The five v1 principles stay. One is added to PRODUCT.md:

6. **Keep before delete.** When something is still wanted, offer a way to keep it and still get space back: share space between copies, offload to a drive, or compress. Deleting is one choice among these, not the only one.

## 3. Popover changes

Same order as v1, with these changes:

1. **Headroom line** gains a runway line under it, shown only when it matters (section 5):
   `18 GB free` / `of 245 GB · 2 GB below your 20 GB warning` / `Falling about 1.4 GB a day. Full in about 13 days.`
   Below the warning level, when macOS can purge more on its own, a line adds `Plus 2 GB that macOS can free on its own.` Above the warning it stays hidden: quiet until it matters.
2. **Capacity bar segments are buttons.** Clicking one, or its legend entry, opens the Space Map at that category.
3. **Other options** gains two rows, in this order after Rebuilds on use and Your call:
   - `Identical files · 3.4 GB can be shared · nothing deleted`, with its own Review (section 7.3).
   - `Forgotten files · 4.1 GB in 4 files`, items not opened in 6 months (section 7.2).
   Dormant projects stays last.
4. **Footer:** `Space Map…` above `Settings…`.
5. **Keyboard:** ↑ and ↓ move between rows, → and ← expand and collapse a group, Space ticks a checkbox in a review, Return runs the primary button, Esc goes back one screen and closes the popover from the main screen.

## 4. Space Map window

A normal macOS window (about 1000 × 640 pt, resizable), opened from the popover footer or a capacity bar segment. While it is open, Headroom shows in the Dock and the app switcher like any windowed app, and hides again when it closes.

**Not a sunburst** (v1 anti-reference). It is a ranked list you drill into, like Finder's list view sorted by size, because the question is "what is big, and what can I do about it".

- **Sidebar:** `Macintosh HD` (everything), then the capacity bar's categories with sizes (macOS, Developer, Docker, Apps, Claude, Projects, Other), then a separator and `Offloaded` (items Headroom has moved off this disk).
- **Toolbar:** back and forward, a path bar for the current folder, a search field (⌘F) that filters by name across the current level and below.
- **List:** one row per folder or file, sorted by size: name with its icon, a kind label when Headroom knows it (`Cache`, `Build output`, `Project`, `App data`, `Emulator`, `Simulator`), last opened, and size with a thin proportional bar under the number. Sizes that share space with clones read `up to 9.4 GB`. Double-click or → drills in; ← or ⌘↑ goes up.
- **Inspector** (right side, for the selected row): name, full path, size, and when it shares space, what deleting it would really give back. Then what Headroom knows about it: for a catalogue match, its description and cost, with `Clean…` opening the normal review; for a project, last commit and its removable folders. Then the actions that apply, in this order: `Clean…`, `Offload…`, `Move to Bin`, `Show in Finder`. Folders inside apps, system folders and anything in use show why an action is missing instead of a disabled button with no reason.
- **Honest totals.** The footer reads `Measured 3 min ago · 236 of 245 GB accounted for`. The rest is a row of its own, `Not measured · 9 GB`, whose inspector explains it: system data Headroom can't read, purgeable space, and folders skipped without Full Disk Access, with a button to grant access when that is the reason.
- **Measuring** reuses the v1 sizer. The map shows the last full measurement at once and refreshes the open folder in the background; numbers change in place, without a spinner over the list.

## 5. Trend and runway

- **Data:** the free-space check that already runs every 60 seconds stores the lowest free space of each hour. 90 days are kept (about 2,200 numbers).
- **Rate:** a straight-line fit over the last 7 days of used space, with Headroom's own cleanups added back so a cleanup doesn't look like the disk shrinking. Needs at least 3 days of data.
- **When it shows:**
  - Falling, and full within 30 days: `Falling about 1.4 GB a day. Full in about 13 days.` in secondary text; orange within 7 days.
  - Otherwise nothing. A steady or rising disk adds no line. Quiet until it matters.
- **Notification**, once per crossing: `At this rate the disk is full in about 6 days. 4 GB can be cleaned without losing anything.` Action: Review. Settings › Alerts gets `Warn when the disk would be full within [7] days`.
- **History tab** (Settings) leads with a 30-day chart of free space: an area chart with the warning and critical levels as lines, a marker on each Headroom cleanup with what it freed, and the projection as a dashed line when the runway shows. The cleanup table stays below it.

## 6. Cleanup feel

- **The bar drains.** The result screen shows the capacity bar. The cleaned share leaves its category segments and joins free space with a critically damped spring (about 0.4 s), and the free figure counts up to the measured value at the same time. With Reduce Motion on, both change at once.
- **Put Back.** Every item that went to the Bin has `Put Back` on the result screen and in History, for as long as it is still in the Bin. Putting back restores the original path and removes the item's freed amount from History.
- **First run** (inside the popover, three steps, each one screen):
  1. What Headroom does: measures folders, cleans only what you confirm, never touches what is in use.
  2. Full Disk Access: why it helps, `Open Privacy Settings…`, and a live check that turns into `Granted` when access arrives. `Continue without it` is always there.
  3. `Open Headroom at login` (on by default) and `Start first scan`. The main screen then fills in as folders are measured.
- **Focus** is always visible, using the system focus ring.

## 7. New capabilities

### 7.1 Developer leftovers

New catalogue entries, each in the group that matches its cost. All are measured; none are cleaned without review.

| Entry | Here today | Group | How it is cleaned | What you lose |
| --- | --- | --- | --- | --- |
| Unavailable simulators | 0 | Ready | `xcrun simctl delete unavailable` | Nothing. Their runtime is gone already. |
| Homebrew old versions and downloads | not measured | Ready | `brew cleanup` | Nothing. Rolling back needs a download. |
| pnpm store, unreferenced packages | up to 388 MB | Ready | `pnpm store prune` | Nothing. Downloaded again when needed. |
| Old simulator runtimes no device uses | 0 | Rebuilds on use | `xcrun simctl runtime delete` | Downloaded again from Xcode. |
| Android system images no emulator uses | 2.3 GB, in use by Pixel_7 so not offered | Rebuilds on use | Deletes the image folder | Downloaded again by Android Studio. |
| iOS DeviceSupport for unused iOS versions | 8 KB | Rebuilds on use | Deletes old version folders | Rebuilt the next time that device connects. |
| Simulators not booted in 90 days | 2.2 GB in 9 | Your call | `xcrun simctl delete` | Test apps and their data in that simulator. Can't be put back. |
| Android emulators not started in 60 days | 3.1 GB, Pixel_7 | Your call | Deletes the `.avd` folder and `.ini` | Its apps, data and snapshots. Offload is offered instead. |
| Xcode archives over a year old, newest per app kept | 553 MB | Your call | To the Bin | Can't symbolicate crashes from those builds. |
| Local AI models (Ollama, LM Studio) | none installed | Your call | `ollama rm` or delete the model folder | Downloaded again, often several GB. |

Time Machine local snapshots are not an entry: macOS removes them on its own when space runs low. They count towards `more macOS can free on its own`.

### 7.2 Forgotten files

- **What:** files of 500 MB or more in the home folder that haven't been opened for 6 months, going by Spotlight's last-opened date, or by the last-modified date when Spotlight has none. Plus installers (`.dmg`, `.pkg`, `.xip`, `.iso`) in Downloads older than 14 days whose app is already in Applications.
- **Skipped:** `~/Library`, app bundles and packages, iCloud files that aren't downloaded, anything inside a project.
- **Group:** Forgotten files. Each row shows the name, folder, last opened and size. The actions are Move to Bin (ticked in the review) or Offload.
- **Settings › Scanning:** the size (500 MB) and age (6 months).

### 7.3 Identical files (share space)

APFS can make two files share the same disk blocks (a clone). When one is edited, only the changed part takes new space. Headroom finds files that are byte-for-byte identical and makes the copies clones of one another. **Every file stays where it is and opens as before. Nothing is deleted.**

- **Where:** the home folder, mainly projects (the same packages in many `node_modules`), Downloads, Documents and Desktop. Skipped: `~/Library`, packages and app bundles, iCloud Drive, files under 100 KB, and anything in use.
- **Finding:** files of equal size, then a hash of the first and last 16 KB, then a full SHA-256. Files that already share their blocks (same clone ID) don't count.
- **Review** (pushed screen in the popover), grouped by set: `react-native 0.81 · 6 copies across projects · 1.2 GB`, `Screen Recording 4 Mar · in Downloads and Desktop · 640 MB`. Each set has a checkbox. The confirm button reads `Share space, 3.4 GB`.
- **Cost, stated in the review:** `Git and Time Machine see these files as changed once: git rechecks them, and the next backup copies them again.` A project with a running dev server is skipped, because its watcher would see changes.
- **Safety rules** for each copy:
  1. Compare the copy byte for byte with the keeper just before replacing it, and check its size and modified date haven't changed since the scan.
  2. Skip hard links, locked files, files open in any process, and files whose owner differs from the keeper's.
  3. Clone the keeper to a temporary file beside the copy. Copy the copy's own permissions, owner, ACLs, extended attributes, Finder tags, flags and dates onto it.
  4. Swap the two atomically, then remove the old copy. If any step fails, the original stays untouched and the temporary file is removed.
  5. Gains are measured from free space before and after, as everywhere else.
- **Later:** a copy edited afterwards stops sharing and takes space again. Clones aren't duplicates in the Space Map; sizes show `up to` as in v1.

### 7.4 Offload

Move something you want to keep, but rarely use, off the internal disk, and bring it back with one click.

- **Offered for:** Your call items that are folders (games, MAMP, Android emulators), dormant projects, forgotten files, and any folder or file in the home folder from the Space Map. Not for system folders, app bundles or anything in use.
- **Destinations,** chosen in a sheet:
  - **An external drive.** Connected APFS or Mac OS Extended drives are listed with free space. Items go to `Headroom Offload/<name>` on the drive. On exFAT or FAT drives the item is written as one Apple Archive file, so permissions and metadata survive.
  - **A compressed archive on this Mac,** in `~/Headroom Offload`. Offered only for kinds that compress well (projects, documents); the sheet gives an estimate from a sample, `about 40% smaller, measured after`. Not offered for disk images, videos, games or emulator images.
- **Steps,** shown as a checklist like cleaning: quit the app that uses it (asked first) · copy · verify every file's size and checksum · remove from this Mac. The original is removed only after verification passes, and the confirm button says so: `Offload to T7 and remove 4.6 GB from this Mac`.
- **What's left behind:** for items in Documents, Desktop, Downloads or a projects folder, a Finder alias named `<name> (offloaded)`. App data folders get no alias, because an app might follow it to the drive.
- **Restore** (Space Map › Offloaded, and History): needs the drive connected and enough free space (`Needs 4.6 GB; 18 GB free`). It copies back, verifies, then asks whether to keep the offloaded copy.
- **Failure:** drive unplugged or full mid-copy → the original is untouched, the partial copy is removed, and the result says what happened.

## 8. New states

| State | What the user sees |
| --- | --- |
| Runway falling | Secondary line under the headroom line; orange within 7 days; one notification. |
| Not enough history | No runway line. The History chart says `Free space is recorded hourly. The trend appears after 3 days.` |
| Space Map, first open | The last full measurement at once; folders refresh in place. |
| Space Map, unreadable | A `Not measured` row explaining why, with a Full Disk Access button when that is the reason. |
| Identical files, none | The row is hidden. |
| Offload, no drive | Only the compressed archive is offered, with `Connect a drive to offload to it.` |
| Offload, drive missing on restore | `Connect T7 to restore this.` The item stays listed. |
| Put Back, Bin emptied | Put Back disappears. History keeps the entry. |

## 9. Voice additions

- **Share space,** not dedupe, merge or link. `Shares space with 5 identical copies.`
- **Offload,** as on iPhone. `Offloaded to T7 on 22 Oct.`
- **Forgotten files,** not "old files" or "unused". `Not opened since 4 March.`
- The runway is an estimate, so it always says `about`, and never more precise than whole days.

## 10. Prototype scope

Changes to the clickable prototype:

- **Popover artboard:** the runway line and purgeable note, a Trend tweak (Steady, Falling), the Identical files and Forgotten files rows, the Identical files review, the result screen with the bar draining and Put Back, a First run scenario, and `Space Map…` in the footer.
- **New Space Map artboard (clickable):** sidebar, drill-down list, inspector, the Offload sheet through to done, and the Offloaded list with Restore.
- **Settings:** the History chart; the runway alert in Alerts; the forgotten-file thresholds in Scanning; the new entries in Caches.
- **Notifications:** the runway notification.

## 11. Open questions for review

1. **Offload alias.** Should an alias be left behind in user folders, or nothing at all?
2. **Identical files minimum.** 100 KB keeps the scan quick but skips many tiny `node_modules` files. Go lower?
3. **Runway thresholds.** Show within 30 days, notify within 7 days?
4. **Forgotten files.** Is 500 MB and 6 months right?
5. **Dock icon.** Headroom appears in the Dock only while the Space Map is open. Is that OK?
