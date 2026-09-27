# Components: Layout and organization + Navigation and search + Content (19 HIG pages)

One section per HIG page. Tags per the skill's strength model; quoted sentences are Apple's.

# Layout and organization

## Boxes

- A box groups logically related information. [PREFER] Small relative to its container; a near-window-size box separates nothing and crowds everything.
- [PREFER] Padding and alignment for subgroups; nested boxes read as busy and constrained.
- Title only when it clarifies; brief phrase, sentence case, no ending punctuation (colon only in settings panes).

## Collections

- [PREFER] "Use the standard row or grid layout whenever possible"; custom layouts confuse and draw attention to themselves.
- [PREFER] A table over a collection for text; collections earn their keep for images and widely varying item sizes.
- [ALWAYS] Easy item selection: adequate padding so focus/hover effects read and content does not overlap.
- [PREFER] Standard insert/delete/reorder animations for feedback; [ALWAYS] avoid layout changes while people are interacting unless they asked for them.

## Column views (macOS)

- A browser of vertical columns for deep hierarchies with frequent back-and-forth; root level always in the first column; show a preview/info column for leaf selections; resizable columns.

## Disclosure controls

- [PREFER] "Use a disclosure control to hide details until they're relevant." Most-used controls at the top level, advanced ones behind the disclosure. This is Apple's progressive-disclosure control.
- Disclosure triangle (lists/hierarchies): points leading when closed, down when open; [ALWAYS] a descriptive label ("Advanced Options").
- Disclosure button (a single control's extra options, e.g. the Save dialog expander): [HARD] at most one per view.

## Labels

- Static, readable, often copyable, never editable (editable small text = text field; long text = text view).
- [PREFER] System fonts (Dynamic Type free); system label colors (label/secondary/tertiary/quaternary) to encode importance.
- [PREFER] Make useful label text selectable: error messages, addresses, identifiers.

## Lists and tables

- [PREFER] Row-based format for text; a collection when sizes vary widely or images dominate.
- [PREFER] Editable (at least reorderable) when it makes sense; iOS requires an edit mode for selection.
- [ALWAYS] Selection feedback matches meaning: persistent highlight for navigation rows, brief highlight plus checkmark for option rows.
- [PREFER] Succinct row text; titles-only rows with detail views instead of giant rows; mid-text ellipsis can preserve both ends of clipped content.
- Styles carry semantics: grouped (headers/footers/spacing) on iOS, bordered alternating rows on macOS, elliptical on watchOS.
- iOS/iPadOS/visionOS: an info (detail disclosure) button reveals more about the row and [NEVER] navigates; navigation uses the disclosure indicator chevron. No index on tables whose rows have trailing controls (they collide).
- macOS: sortable resizable columns, alternating row colors on wide tables; hierarchy wants an outline view.
- watchOS: prefer short lists; long lists show the most relevant plus "view more"; short detail views enable vertical page-based navigation.

## Lockups (tvOS)

- Focus-expanding content units (image + text). Space them so focus expansion cannot overlap; consistent sizes per row; people-images over initials.

## Outline views (macOS)

- Hierarchical rows with disclosure triangles, optionally more columns. [ALWAYS] Column headings on multi-column views (nouns, title case, no punctuation); sortable and resizable columns; Option-click expands all children.

## Split views

- Adjacent panes (sidebar / content list / detail). [ALWAYS] Persistently highlight the current selection in every pane leading to the detail; the highlight is the map.
- [PREFER] Regular width environments only; compact width wants navigation instead.
- [PREFER] Hideable panes with multiple ways to restore them; drag-and-drop between panes; the thin (1 pt) divider.

## Tab views (the in-content tabbed control, distinct from tab bars)

- [PREFER] For closely related panes of content in one area; panes are self-contained ([ALWAYS] controls in a pane affect only that pane).
- [ALWAYS] Labels predict pane contents; nouns, title case.
- [NEVER] More than six tabs; too many wants a pop-up button instead.

# Navigation and search

## Path controls (macOS)

- Shows a file's path; window body only, never toolbars or status bars.

## Search fields

- Search icon + Clear button + placeholder; scope bars and tokens refine.
- [PREFER] Placeholder text that teaches what can be searched.
- [PREFER] "If possible, start search immediately when a person types."
- [PREFER] Recents before typing, predictive suggestions during; scope bars for category filters; tokens for term filters (pair tokens with suggestions so they are discoverable).

## Token fields (macOS)

- A text field that converts typed text into selectable, manipulable tokens (Mail's recipient chips); a token can carry its own contextual menu.
- [PREFER] Extra shortcuts beyond the default comma for making a token (Return, for instance).
- [PREFER] Tune the suggestion delay: immediate suggestions can distract while someone is still typing.
- The iOS/iPadOS equivalent inside search is Search fields' tokens, above.

## Sidebars

- Top-level navigation on the leading side; costs a lot of space, so compact contexts want a tab bar (or the adaptable tab bar that converts).
- [PREFER] User-customizable contents and order; hideable via platform-standard interactions but [NEVER] hidden by default.
- [PREFER] At most two hierarchy levels; deeper data wants a split view with a content list.
- Sidebar icon color follows the accent color (and the user's macOS accent choice); fixed colors only as deliberate signals (Mail's VIP yellow).

## Tab bars

- [ALWAYS] "Use a tab bar to support navigation, not to provide actions." Actions belong in a toolbar.
- [ALWAYS] Keep the tab bar visible everywhere in the app; hiding it strands people. The one exception is a modal (temporary, self-contained).
- [PREFER] Few tabs; ease of navigation shrinks with count. Complex structures want the sidebar-adaptable tab bar.
- [ALWAYS] Avoid the overflow More tab; content behind it is unreachable in practice.
- [NEVER] "Don't disable or hide tab bar buttons, even when their content is unavailable." Empty sections explain themselves instead.
- [ALWAYS] Single-word labels under every icon; filled-style icons.
- [PREFER] Badges only for critical information; routine badging dilutes them.
- iOS: floats at the bottom on glass, content peeking through; can minimize on scroll with an attached accessory (Music's MiniPlayer); optional dedicated search tab at the trailing end.
- iPadOS: near the top; fixed or convertible to a sidebar; user-customizable tab sets (default five or fewer).
- visionOS: vertical on the leading side, expands on look; keep labels short. watchOS: unsupported.

# Content

## Charts

- Anatomy: marks (bar, line, point...) in a plot area, scales mapping values to position/color/height, axes with ticks and grid lines.
- [PREFER] Mark type follows the information (trend → line; comparison → bar); combining marks (points on a line) when it adds clarity.
- Design-level rules live in patterns.md → Charting data.

## Image views

- For display, not interaction: [PREFER] an image button when the image must be clickable; an image well when editable.
- [PREFER] Symbols/interface icons over image views for iconography.
- Animated sequences: consistent prescaled sizes for performance.

## Text views

- Multiline styled text, optionally editable; label or text field for small amounts.
- [ALWAYS] Legibility above styling creativity; adopt Dynamic Type; test with bold text and accessibility settings.
- [PREFER] Selectable useful text; the right keyboard type when editable.

## Web views

- Embedded web content in-app.
- [PREFER] Forward/back controls when people will visit multiple pages.
- [NEVER] "Avoid using a web view to build a web browser." Brief in-context web access is the use case; Safari is the browser.
