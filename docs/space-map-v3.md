# Space Map v3: design decisions

Status: agreed direction, 23 Oct 2026. Replaces the Space Map in [design-brief-v2.md](design-brief-v2.md). No code yet; the detailed design and SwiftUI plan come next.

Previews, rendered from this Mac's real sizes and app icons: [browse](prototype/space-map-browse.png) and [plan](prototype/space-map-plan.png).

## 1. Decisions so far

- **Direction A.** A map of the current folder above a list of the same items. Tiles are sized by space and tinted by what removing them costs, in the menu's colours: green loses nothing, blue makes the next build slower, orange is your call, sand is your own files.
- **Glass slabs.** Each tile is frosted glass. Behind it sits that folder's own contents, measured one level down, so you see a soft impression of what's inside. The rim catches light at the top left.
- **Glass shows state.** Resting tiles are frosted. A selected tile clears and labels its contents. Tiles picked up into the plan become clear, bright glass, lifted off the map, leaving a dashed footprint.
- **Concentric corners.** Window 28 pt; floating sidebar, inspector and Plan tray 20 pt (inset 8); tiles 16 pt; the Library group 21 pt (tiles plus a 5 pt gap); shapes inside a tile 9 pt (inset 7).
- **Glass only where something floats.** Sidebar, inspector, toolbar controls, the Plan tray and lifted tiles. The status line and the list rest on the window.
- **Real imagery.** App icons from the Mac on tiles, rows and the sidebar. Generated art only for illustrations such as empty states.
- **Honest totals.** One line: measured, not measurable by apps, and free, adding up to the disk.

## 2. The Plan

The Space Map's job is to build a plan, not to delete things one at a time.

- **Add to Plan** is the main action on any tile. Each item goes where its cost sends it: the Bin (Put Back works), a drive (kept, can be copied back), compression, or shared space for identical copies. The inspector lets you change the destination.
- **The tray** lists the picks with their destinations and fills a bar from free now to free after, with the warning level marked. It says when space only returns once the Bin is emptied. Nothing happens until Review Plan.
- **Aim for a target.** "Get me to 50 GB free" fills the plan cheapest first: nothing lost, then slower next build, then your call. Plain rules, with a one-line reason per pick.
- **What you'd lose.** Before Review, the tray lists the consequences in words, not only sizes.

## 3. The map

- **Zoom clears the glass.** Opening a tile (double-click, pinch, scroll or Return) grows it to fill the map while its contents sharpen into the next level of tiles. Back frosts them again into the same spot.
- **In use, shown on the tile.** Running apps and active dev servers get a pause badge and a softly pulsing rim. Planning one explains why it has to wait.
- **Growth on the map.** Tiles that grew since the last snapshot carry an "↑ 9.1 GB this week" badge. A "Since…" control replays free space over time.

## 4. Interaction

- Space for Quick Look; a context menu with Reveal in Finder, Copy Path, Ask Ollie and Never Scan This.
- Arrow keys move between tiles by position, Return opens, A adds to the plan; ⌘-click and drag-select pick several.
- Feedback on pointer-down; the rim highlight follows the pointer.
- Adding lifts the tile on a spring (damping 0.8, response 0.35) and its chip travels into the tray; removing reverses the same path. Every move can be interrupted mid-flight.
- Dragging a tile into the tray also adds it; a quick throw toward the tray counts. A light trackpad haptic when it lands.
- Reduce Motion: cross-fades instead of travel. Reduce Transparency: solid tints. Increase Contrast: firm outlines.

## 5. Ollie

His rules don't change: he never cleans anything himself, never sends the names or contents of your own files, and every answer is saved and visible.

- **On the map.** Tiles Headroom has no rule for show a small "?" in the glass. Holding the pointer on a tile shows his saved guess; the inspector holds his full answer. In a target plan, each pick has his one-line reason.
- **Asking questions on the map.** A field in the Space Map takes questions such as "show me everything Android" or "what can go that I haven't opened in a year?". He answers from Headroom's own data through read-only tools (folder sizes, rules, snapshots) and the matching tiles light up. He can show, not act: adding to the plan stays with you.
- **A second opinion on the plan.** Before Review, he reads the plan and names risky combinations, for example an emulator and the SDK it needs both in the plan, or saved game worlds inside an app's data. The facts come from Headroom's rules; he puts them into words.
- **The app's own cleanup first.** When an app has a safer built-in tool (Docker's Clean / Purge data, Xcode's Settings › Components, Steam's per-game uninstall), he says so before suggesting a delete. Saved per app.
- **Growth notifications** carry his one-line reason.
- **Outside the window.** "Ask Ollie" in Finder's right-click menu for any folder, and `headroom ask "…"` in the terminal.
- **Notes written on the Mac.** The short notes (the menu summary, growth reasons, first guesses, plan reasons) come from Apple's on-device model (Foundation Models, macOS 26) where it's available: free, private and offline. Claude stays for detailed answers that need web search, and is the fallback for notes when the on-device model isn't available.
- **Character.** His owl drawing has a few states, each brief: looking around while he's thinking, a small nod when a plan finishes, wide eyes only when space is critical. Under Reduce Motion the states change without movement.

## 6. Still to design

- Light appearance for the glass and tints.
- Empty states ("This folder is tidy").
- The question field's placement and how its answers and highlighted tiles clear.
- SwiftUI approach: `glassEffect` with per-tile tint inside a `GlassEffectContainer`, cached child measurements per visible tile, and the split into navigation model, data source and views.

## 7. Later

Plans that wait for items in use or run tonight; a receipt after the plan runs; free space and unmeasured space as tiles on the disk view; Kinds as an animated rearrangement; search that lights matches across the disk; links between identical copies; drag-select; hover peek; the plan in the menu; Shortcuts ("Free up 10 GB", always opening the plan for review); a desktop widget.

For Ollie: remembering items you keep taking out of plans; an optional weekly note; suggesting a rule after explaining the same kind of folder several times; a monthly spending cap shown in Settings; a read-only Headroom MCP server for coding agents; Siri.
