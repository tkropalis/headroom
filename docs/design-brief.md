# Headroom: design brief

Status: confirmed 22 Oct 2026. No app code has been written yet.

## 1. Summary

Headroom is a macOS menu bar app that shows how much free space the internal disk has, warns before it runs low, flags folders that grow unusually fast, and cleans known caches and build output when asked. It is built for one developer whose disk fills with tool caches, Docker data and project dependencies. A shared Swift core does the scanning and cleaning so a command-line tool can use it later.

## 2. Primary user action

Glance at the menu bar and know whether space is fine. When it isn't, review what can go and clean it in one confirmed step.

## 3. Design direction

- **Colour strategy: Restrained.** System colours only. The accent is the user's macOS accent colour, used for the primary button and selection. Status uses the system green, orange and red, always paired with a word or symbol so colour is never the only signal.
- **Scene:** Tommy at his desk, mid-build in VS Code, glances at the menu bar for half a second, in daylight or late at night. The app follows the system's light or dark appearance like every built-in menu.
- **Anchors:**
  - The macOS **Battery menu**: one status line on top, then the few things using the resource, then a link to settings.
  - **System Settings › General › Storage**: one capacity bar split by category, then categories with sizes and a way to act on each.
  - The **Time Machine menu**: quiet status, last run time, a single action.
- **Material: glass, by request (22 Oct 2026).** The popover, menu bar, settings window and notifications are translucent glass in the macOS 26 style: strong background blur, a bright top edge, capsule-shaped buttons and larger corner radii. Elements inside a glass surface use plain fills, never a second layer of glass, so text stays readable. In the app this is the system's Liquid Glass (`glassEffect`) and materials, not a custom blur. When Reduce Transparency is on, surfaces become solid.
- **Type:** SF Pro, the system font, at the system's own sizes. Sizes and figures use tabular numbers so columns line up.
- **Motion:** only state changes move. The capacity bar glides to its new value with a critically damped spring (about 0.35 s, no bounce) after a scan or cleanup. With Reduce Motion on, it changes instantly.

Image generation isn't available in this environment, so the visual probe step is skipped. The clickable prototype takes its place.

## 4. Scope

- **Fidelity:** high-fidelity clickable prototype in the browser, drawn to look like macOS 26.
- **Breadth:** menu bar item, popover in its main states, cleanup review and result, growth alert, notifications, settings window, cleanup history.
- **Interactivity:** click through the main flows with sample data from today's scan.
- **Time intent:** settle the design, then build the real app from it.

## 5. Layout

### Menu bar item

The `internaldrive` symbol followed by free space, for example `29 GB`. Monochrome like other menu bar items while healthy. Below the warning level the symbol gets an orange dot; below the critical level the number turns red. Settings can switch to icon only or percentage.

### Popover (about 340 pt wide, MenuBarExtra window style)

Top to bottom, most important first:

1. **Headroom line:** `29 GB free` large, then `of 245 GB · 9 GB above your 20 GB warning` in secondary text.
2. **Capacity bar:** used space split into the categories from System Settings' storage view (Apps, Developer, Docker, Caches, Projects, System, Other), with a thin tick marking the warning level.
3. **Growth alert** (only when present): `Chrome temporary copies grew 9.1 GB since yesterday` with Review.
4. **Ready to clean:** `4.2 GB in 6 caches, nothing lost`, with a Review button. This is the one primary action.
5. **Other options, collapsed by default**, each one line with a size:
   - Rebuilds on use (Gradle, simulator caches, old VS Code workspaces, unused Docker images)
   - Your call (Claude history, games, MAMP)
   - Dormant projects (no commit or edit in 90 days, with what can be removed from each)
6. **Footer:** `Scanned 12 min ago`, Scan now, Settings…, Quit Headroom.

### Cleanup review (pushed view inside the popover)

A list with a checkbox per item, its size, and one line on what you lose. Items that can't be cleaned right now are shown but unchecked, with the reason and a fix:

- `Spotify is open. Headroom will quit it first.` (checked, quit listed in the confirm button)
- `ilov2front dev server is running. Skipped.` (disabled)

The confirm button names the outcome: `Quit Spotify and clean 4.2 GB`. A secondary `Cancel` sits to its left. No extra "Are you sure?" dialog: the review is the confirmation.

### Result

`Freed 3.9 GB. 33 GB free now.` with a per-item list showing measured gains, and any items that failed with the reason and a Retry.

### Settings window (standard macOS settings, tabs)

- **General:** open at login; menu bar shows free GB, percentage, or icon only.
- **Alerts:** warn below (default 20 GB); critical below (default 10 GB); alert when a folder grows more than (default 5 GB in a day).
- **Scanning:** the internal disk, with an exclusions list; daily scan when the Mac is idle; Full Disk Access status with a button to System Settings.
- **Caches:** the catalogue of known caches, each with a toggle and its cleanup method; add a custom folder.
- **History:** every cleanup with date, items and measured space freed.

### Notifications

- `Headroom is low: 14 GB free. 6 GB of caches can be cleaned without losing anything.` Action: Review.
- `Chrome temporary copies grew 9.1 GB since yesterday.` Action: Show.

## 6. Key states

| State | What the user sees |
| --- | --- |
| First launch | A short explanation of what Headroom reads, and a request for Full Disk Access with what happens without it (some folders are skipped). |
| First scan | Results fill in as folders are measured; the headroom number is shown at once from the system. No spinner over the content. |
| Healthy | Number only. Ready-to-clean still listed, without emphasis. |
| Warning / critical | Orange or red menu bar item, one notification per threshold crossing, Ready to clean promoted. |
| Nothing to clean | `Caches are already clean.` with the largest remaining categories for context. |
| Uncertain size | Sizes affected by cloned files show `up to` and a note that the real gain is measured after cleaning. |
| Blocked item | Unchecked or disabled, with the reason (app open, dev server running, needs admin password). |
| Cleaning | Each item ticks off as it finishes; Cancel stops after the current item. |
| Partial failure | Result lists failed items with a plain reason (`Permission denied on 312 files`) and a Retry that fixes permissions first. |
| Scan error | `Couldn't read 3 folders without Full Disk Access.` with a button to grant it. |

## 7. Interaction model

- Clicking the menu bar item opens the popover; Esc or clicking outside closes it.
- Everything is reachable by keyboard: Tab between controls, Return for the primary button, ⌘, for Settings.
- Apps are quit gracefully and only after the user confirms. If an app refuses (for example it has unsaved documents), its item is skipped and reported.
- Safe caches are deleted outright. Items in "Your call" go to the Bin so they can be restored.
- Nothing runs on its own. A scheduled scan only measures; it never cleans.

## 8. Content

- **Units:** decimal GB, the same as Finder and About This Mac, so numbers match what the user sees elsewhere. The disk is 245 GB in these units, and today's 27 GB free (as Terminal reports it) is 29 GB.
- **Voice:** plain, short and specific. Name the folder and the cost. No "junk", no "optimise", no exclamation marks, no scores.
- **Item description pattern:** what it is · what you lose. For example `npm download cache · nothing; npm downloads packages again when needed`.
- **Realistic ranges:** 0 to about 40 catalogue items; 0 to 3 growth alerts; 20 to 40 projects found on the disk; sizes from 50 MB to 25 GB.

## 9. References for implementation

- impeccable `interaction-design.md`, `clarify.md` and `harden.md`
- apple-design: springs, reduced motion, materials and vibrancy (glass surfaces use the system's Liquid Glass, with no glass stacked on glass)
- Apple Human Interface Guidelines: menu bar extras, settings windows, notifications

## 10. Decisions after review

- **Confirmed** on 22 Oct 2026; the clickable prototype is built from this brief.
- **Anti-reference:** no DaisyDisk-style sunburst as the main view.
- **Accessibility:** basics only for now: follow Reduce Motion and keep contrast readable in both appearances.
