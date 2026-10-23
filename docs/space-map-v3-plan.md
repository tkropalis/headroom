# Space Map v3 and Ollie: implementation plan

Status: written 23 Oct 2026, waiting for a go-ahead. Implements [space-map-v3.md](space-map-v3.md). Previews: [browse](prototype/space-map-browse.png), [plan](prototype/space-map-plan.png).

## 1. Ground rules

- Nothing changes on disk without a review that names what happens. Planning, targets, Ollie and the question field only ever show or suggest.
- `PathSafety.isDeletable` and `Offloader.canOffload` stay the only gates for moving anything. Personal folders (`Explainer.privacyBlocker`) are never sent to Claude, whatever the feature.
- Every phase builds, passes `swift test`, gets a `--preview` screenshot check against the previews, and is installed and tried before the next starts. Each phase is its own commit, made with the commit skill when you ask. Nothing is pushed.
- The popover keeps working throughout; the Space Map is replaced phase by phase rather than in one switch.

## 2. Architecture

Today `SpaceMapView.swift` holds the model, navigation, data loading and every view in 627 lines. It becomes a folder, and the logic that can be tested moves to the core.

**HeadroomCore (new or changed)**

| File | Holds |
| --- | --- |
| `Treemap.swift` | Squarified layout: items and a rectangle in, rectangles out; nested groups; deterministic. |
| `SpaceCost.swift` | One answer to "what does removing this cost?" for any path: `nothingLost`, `slowerNext`, `yourCall`, `yourFiles`, `system`, `unknown`. Built from scan candidates, catalog rules, learned answers, projects and personal folders. Replaces the separate mappings in the inspector, the list and `SpaceKind`. |
| `SizeCache.swift` | Measured sizes by path with the time measured; children of visible tiles are measured one level down, at most 4 at a time, and cached on disk so going back is instant. |
| `Plan.swift` | `CleanupPlan` and `PlanItem` (path, name, bytes, destination, reason, added by you or by a target), saved in `plan.json`. Destinations: Bin, drive, shared space. |
| `TargetPlanner.swift` | "Get me to N GB free": cheapest tier first (nothing lost, then slower next, then your call), largest first within a tier, skipping anything in use or that can't be moved. |
| `PlanCheck.swift` | Facts about a plan: dependencies between items (an emulator and the SDK it needs), saved data inside app data (game saves), apps that must quit, space that only returns when the Bin is emptied. Pairs and contents are declared in the catalog, not guessed. |
| `Catalog.swift` | Gains `appCleanup` (the app's own tool, such as Docker's Clean / Purge data) and `needs` (dependencies used by `PlanCheck`). |
| `NoteModel.swift` | One interface for short notes, with two writers: on-device (Foundation Models) and Claude Haiku. `QuickNotes` uses whichever is available; the cache key includes the writer. |
| `OllieTools.swift` | Read-only tools for questions: list a folder, find folders by name, the rule for a path, growth since a date. Every result passes the privacy filter. |
| `OllieAsk.swift` | Answers a question with those tools through Claude tool use; returns text plus the paths to light up. |

**HeadroomApp/SpaceMap (split from SpaceMapView.swift)**

| File | Holds |
| --- | --- |
| `SpaceMapModel.swift` | Navigation (path, history, lens), selection (several), zoom state, filters, the question and its highlights. |
| `SpaceDataSource.swift` | Snapshot sizes plus live measurements through `SizeCache`; cancels work when you navigate away. |
| `SpaceMapWindow.swift` | The window: floating glass sidebar and inspector, toolbar, map above the list, status line. |
| `TileMap.swift` | Layout from `Treemap`, keyboard movement by position, pinch and double-click to open, drag-select, drag to the tray. |
| `GlassTile.swift` | A tile: the contents impression behind it, `glassEffect` tinted by cost, icon and labels, badges (in use, growth, "?"), resting, selected and lifted states. |
| `SpaceList.swift` | The list: Can go, Changed (relative), Size; a small bar of contents for folders with mixed costs. |
| `SpaceInspector.swift` | The selected item or the folder summary, destination choice, Ollie's answer and the app's own cleanup. |
| `PlanTray.swift`, `PlanReviewSheet.swift` | The tray with the free-space meter, and the review that runs the plan. |
| `OllieMark.swift` | The owl with its states. |

## 3. Phases

### Phase 0: Foundations, no visible change

1. Split `SpaceMapView.swift` into the files above, keeping today's behaviour.
2. Add `Treemap`, `SpaceCost` and `SizeCache` to the core, with tests:
   - areas proportional to sizes within 1 pt, no overlaps, stable output for the same input
   - known paths get the expected cost (a cache is nothing lost, Gradle is slower next, Docker data is your call, Documents is your files)
   - the cache returns measured sizes without measuring again, and a newer modification date measures again
3. Point the existing inspector and list at `SpaceCost`.

Done when: the old Space Map looks and works the same, and the tests pass.

### Phase 1: The new window

1. **Real hierarchy.** Folders lens starts at Macintosh HD with Applications, your home, Library, macOS and Temporary, plus a "Not measured" row with the Full Disk Access action when it's off. Breadcrumbs follow real paths. Kinds lens keeps today's categories.
2. **Liquid Glass shell.**
   - The sidebar and inspector are floating glass panels 8 pt inside the window with 20 pt corners, and content shows blurred beneath the sidebar (`backgroundExtensionEffect`).
   - Toolbar controls are glass.
   - The status line rests on the window and shows measured, not measurable by apps, and free.
3. **List.** Can go column with cost colour, relative dates (highlighted after 6 months), the contents bar for mixed folders, real app icons for app-owned folders (`NSWorkspace` icons, cached).
4. **Filters.** All, Can go, Not used for 6 months.
5. **Inspector.** Icon, name, path, size, cost, what you lose, one main action, Show in Finder; the folder summary when nothing is selected. No disabled buttons with excuses.

Done when: the window matches the browse preview apart from the map, and every number on screen adds up.

### Phase 2: The glass map

1. Tiles laid out by `Treemap`; the dominant folder (over a third of the view) is drawn as a group with its children inside.
2. **Glass:**
   - Each tile is `glassEffect(.regular.tint(cost))` inside a `GlassEffectContainer`, over an impression of its contents drawn from `SizeCache`.
   - A selected tile uses clearer glass and labels its contents.
   - Tiles under about 40 pt get a flat tint instead of glass, to keep scrolling smooth.
3. **Corners.** Window 28, panels 20, tiles 16, groups 21, contents 9.
4. **Labels.** Icon above the name on tall tiles, inline on short ones, a name with an ellipsis on narrow ones, nothing on tiny ones (they're named in the list and on hover).
5. **Interaction:**
   - Press feedback on pointer-down.
   - Arrow keys by position, Return or double-click or pinch to open, ⌘[ to go back.
   - Space for Quick Look; context menu (Reveal in Finder, Copy Path, Ask Ollie, Never Scan This).
   - ⌘-click and drag-select.
6. **Opening a folder.** The tile grows to fill the map while its contents sharpen into the next level; going back reverses it into the same spot.
7. **In use.** Running apps and active dev servers get a pause badge and a softly pulsing rim; their tiles can't be planned and say why.
8. **Growth.** Badges from snapshot differences, with a Since control (yesterday, last week, last month); the status line gains a small free-space sparkline.

Done when: the browse preview is matched with live data, scrolling and resizing stay smooth with 100 tiles, and keyboard-only use works.

### Phase 3: The Plan

1. **Model and store.**
   - `CleanupPlan` is saved, so a plan survives closing the window.
   - Items keep their destination; the default destination comes from cost: drive for your call when a drive is connected, otherwise the Bin.
2. **Adding to the plan:**
   - Add to Plan in the inspector, A on the keyboard, the context menu, or dragging tiles into the tray.
   - The tile lifts as clear glass with a mint edge and leaves a dashed footprint.
   - Its chip travels into the tray on a spring (damping 0.8, response 0.35); removing it reverses the same path, and either can be interrupted.
   - A light trackpad haptic when it lands.
3. **Tray.** Picks with destinations, free now to free after with the warning marked, the Bin note, and what you'd lose (from `PlanCheck`).
4. **Review and run.**
   - The review sheet lists every item and its destination and asks for one confirmation that names the total.
   - It runs through the existing paths: `Cleaner` (Bin, Put Back) for the Bin, `Offloader` for drives, identical-file sharing for shared space.
   - Results come back as measured free space, as today.
5. **Safety.** Anything outside the catalog can only go to the Bin or a drive, needs its app quit first, and still passes `PathSafety`. Protected paths can't be added at all.

Tests:
- a plan saves and loads
- destinations default by cost
- `PlanCheck` finds the emulator and SDK pair and game saves
- items in use are refused
- running a plan calls the right path for each destination (with fakes)

Done when: the plan preview is matched, and a real plan with a Bin item and a drive item runs, frees the measured amount and can be put back.

### Phase 4: Targets

1. "Get me to N GB free" in the tray, typed or dragged on the meter.
2. `TargetPlanner` fills the plan across the whole disk, not only the open folder; tiles outside the view are counted in the tray and shown when you go there.
3. Each pick gets a one-line reason from its catalog cost.

Tests:
- tier order holds
- items in use are skipped
- the target is reached with the fewest tiers used
- an unreachable target says how close it gets

### Phase 5: Ollie in the Space Map

1. **On-device notes.**
   - `NoteModel` with Foundation Models, used when Apple Intelligence is available; Haiku otherwise.
   - The menu summary, growth reasons, first guesses and plan reasons all go through it.
   - Settings says which one is writing.
2. **On the map.**
   - A "?" in the glass on tiles with no rule.
   - Holding the pointer on a tile shows the saved guess.
   - The inspector shows the full answer (today's `ClaudeAnswerView`, restyled).
3. **The app's own cleanup.** Shown first in the inspector when the catalog or Ollie's answer names one. Ollie's answer format gains an `appCleanup` field.
4. **Second opinion.** Before Review, Ollie phrases `PlanCheck`'s facts in plain words. Without Ollie, the facts still show as plain lines.
5. **Questions.**
   - A field at the top of the map; `OllieAsk` answers with the read-only tools, the matching tiles light up and everything else dims.
   - Escape clears it.
   - Answers are saved like explanations.
6. **Character.**
   - `OllieMark` states: thinking (eyes look around while a request runs), a nod (once when a plan finishes), wide eyes (only when space is critical).
   - Each is brief; under Reduce Motion the drawing changes without moving.

Tests:
- the tools never return a path under a personal folder
- notes fall back to Haiku when the on-device model is unavailable
- the `appCleanup` field decodes

### Phase 6: Ollie outside the window

1. Growth notifications carry Ollie's one-line reason.
2. Finder: an "Ask Ollie" service (`NSServices` in the Info.plist) for folders; it opens the Space Map at that folder with the answer.
3. Terminal: `headroom ask "<question>"`, using `OllieAsk`; prints the answer and the folders it found.

### Phase 7: Appearance and accessibility

1. Light appearance: glass tints, contents impression, sidebar and tray tuned and checked side by side with dark.
2. Reduce Transparency (solid tints), Increase Contrast (firm outlines), Reduce Motion (cross-fades).
3. VoiceOver: each tile reads as a row, for example "Docker data, 26 GB, your call, in plan, to the Bin".
4. Empty states with flat vector illustrations, made with the local image script and kept out of the repo as scripts (the images are committed).
5. Performance pass: measuring, glass count, memory with the size cache.

## 4. Order and checkpoints

Phases 0 to 3 are the core and come first, in order. Phases 4 and 5 can swap. Phases 6 and 7 come last. I stop after each phase with screenshots and a short summary for you to try and approve before continuing.

## 5. Risks and decisions to watch

- **Foundation Models availability.** Needs Apple Intelligence turned on and a supported Mac and region; the Haiku fallback covers the rest.
- **Glass performance.** Many `glassEffect` views can be costly; the flat-tint fallback for small tiles and one `GlassEffectContainer` per map keep it bounded. If it isn't enough, glass is kept for the selected, lifted and largest tiles.
- **Measuring one level down** for every visible tile costs disk reads; it's limited to tiles big enough to show contents and cached.
- **Deleting things outside the catalog** from the map is the biggest safety question. This plan allows only the Bin or a drive for them, after quitting the owning app, behind the same review.
- **Compression** as a destination is left out for now: compressing in place safely needs its own design.
- **Snapshots are daily**, so growth badges and Since are per day, not per hour.
