# Up Only artwork

The SVG files are the editable logo masters. The app loads the corresponding vector PDFs, which contain paths rather than embedded bitmaps. The menu mark has a 26 × 16 point canvas; the welcome wordmarks have a 92 × 73 point canvas. AppKit applies the menu bar's template tint, and the welcome screen selects the appropriate light or dark lettering.

The supplied artwork was cleaned with the built-in imagegen tool, then converted into smooth vector contours. The green letter is an exact rectangle. The original attachments remain unchanged.

Regenerate a bundled PDF after editing its SVG using librsvg:

```sh
rsvg-convert -f pdf -o UpOnlyStatus.pdf UpOnlyStatus.svg
rsvg-convert -f pdf -o UpOnlyWordmark.pdf UpOnlyWordmark.svg
rsvg-convert -f pdf -o UpOnlyWordmarkLight.pdf UpOnlyWordmarkLight.svg
```

Check the actual menu at its native size in both appearances using the fixture options in the project README.
