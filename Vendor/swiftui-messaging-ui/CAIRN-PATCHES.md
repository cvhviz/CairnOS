# Cairn's copy of swiftui-messaging-ui

Copied on 2026-11-11 from https://github.com/bwees-forks/swiftui-messaging-ui at revision
`663d6ce9ee9ba459ef9fe3a1848a05c4acffaef8` (the revision project.yml pinned until then), without its
`.git` and `.github`. Licensed Apache-2.0 (`LICENSE`); the changed file says so in a comment where it
changed, as §4(b) asks.

## Changes

`Sources/MessagingUI/Tiled/TiledView.swift`, all marked "Cairn patch":

- **No crash when an updated message's row was a placeholder.** `.update` refilled rows with
  `reconfigureItems`, which only works when the new cell has the same reuse identifier as the old one.
  A message row that UIKit had been handed as the `.empty` placeholder (asked for while its count ran
  ahead of `items`) could not take a message cell, and UIKit stopped the app:
  `-[UICollectionView _dequeueReusableViewOfKind:withIdentifier:forIndexPath:viewCategory:]` from
  `TiledUIView.applyChange` (Xcode Organizer, Mac "Designed for iPad", Cairn 1.0 (2) to 1.5 (5)). Rows
  shown as, or last handed out as, a placeholder (`placeholderMessagePaths`) are now reloaded; the rest
  are still reconfigured.
- **The same for accessory rows** (loaders, header, typing indicator): `reconfigureAccessoryDisplayItem`
  reloads a row whose shown cell isn't the kind it would dequeue now.

## Updating

To take a newer upstream revision: copy it over this folder, then re-apply the "Cairn patch" blocks
(or drop them if upstream fixed the crash), and keep this file.
