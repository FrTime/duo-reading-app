# App icon

Concept 5A from the icon round: a wooden shelf of book spines with a small
unfolded iPhone Duo at the end of the row.

- `AppIcon-light.svg`, `AppIcon-dark.svg`, `AppIcon-tinted.svg` are the 1024×1024
  sources for the three iOS appearances.
- `generate.py` draws every concept from that round (`shelf2(v, "a")` is the
  shipped icon). Running it writes SVGs to `svg/` and `svg5/` next to the script.

To update the shipped PNGs, render each SVG at 1024×1024, flatten it onto an
opaque background (the App Store rejects icons with alpha), and replace the files
in `DuoReader/Assets.xcassets/AppIcon.appiconset/`. The tinted PNG is grayscale.
