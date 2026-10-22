# Product

## Register

product

## Platform

macos

## Users

One person: Tommy, a developer working on a MacBook with a 228 GB internal disk. The disk holds about twenty active web and mobile projects (Next.js, Laravel, Expo and React Native, native iOS and Android), plus Docker, Xcode, Android Studio and Claude. He glances at the menu bar while working and acts when something needs attention. He does not want to think about disk space until it matters.

## Product Purpose

Headroom keeps enough free space on the internal disk to work, without losing projects or tools. It watches free space, notices when something grows unusually fast, knows which folders are caches and build output, and cleans them on request.

Success looks like this: free space never runs low without a warning first, a cleanup decision takes under a minute, and every number Headroom shows matches what the disk actually gains.

## Positioning

Headroom tells you what you would really get back, and never touches what you are using.

## Brand Personality

A calm gauge. Quiet and glanceable, like a fuel gauge: it speaks up only when space runs low or something grows fast. Native to macOS in look and behaviour.

## Anti-references

Not a DaisyDisk-style sunburst as the main view. A sunburst is good for exploring a disk and poor for deciding what to delete; Headroom's main view is a decision, so it leads with lists of actions and their sizes.

## Design Principles

1. **Measured, not estimated.** Freed space is shown as the change in free disk space, not as a sum of folder sizes. Sizes that can't be trusted (cloned files) are marked as such.
2. **Always ask.** Nothing is deleted, and no app is quit, without an explicit confirmation that names what will happen.
3. **Never touch what is in use.** Caches of running apps and build folders of running dev servers are skipped and explained.
4. **Quiet until it matters.** The default state is one number in the menu bar. Colour, alerts and badges appear only when something needs attention.
5. **Name the cost.** Every cleanable item says what you lose by removing it: nothing, a slower next build, history, or an app.
6. **Keep before delete.** When something is still wanted, offer a way to keep it and still get space back: share space between identical copies, offload it to a drive, or compress it. Deleting is one choice among these, not the only one.

## Accessibility & Inclusion

Basics for now: follow the macOS Reduce Motion setting, and keep text contrast readable in light and dark appearance.
