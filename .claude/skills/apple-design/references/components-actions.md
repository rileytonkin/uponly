# Components: Menus and actions + Selection and input (23 HIG pages)

One section per HIG page. Tags per the skill's strength model; quoted sentences are Apple's. X-vs-Y decisions live in component-chooser.md.

# Menus and actions

## Buttons

A button combines style (size, color, shape), content (symbol, label, or both), and role (semantic meaning).
- [HARD] "A button needs a hit region of at least 44x44 pt — in visionOS, 60x60 pt."
- [ALWAYS] "Always include a press state for a custom button. Without a press state, a button can feel unresponsive."
- [ALWAYS] "Keep the number of prominent buttons to one or two per view. Presenting too many prominent buttons increases cognitive load."
- [ALWAYS] "Use style — not size — to visually distinguish the preferred choice." Same-size buttons read as a coherent set; mixed sizes read as confusion. The preferred option gets a more prominent style.
- [PREFER] Enough space around a button to distinguish and hit it.
- [PREFER] Familiar actions get familiar icons; text when a short label is clearer; verb-first labels per Apple Style Guide ("Add to Cart").
- [PREFER] On colorful content backgrounds, keep button labels monochromatic rather than color-on-color.
- Roles: normal, primary (default, gets accent color, responds to Return, can auto-close temporary views), cancel, destructive (system red).
- [ALWAYS] Primary role goes to the most likely choice; [NEVER] "Don't assign the primary role to a button that performs a destructive action, even if that action is the most likely choice": visual prominence gets clicked unread.
- iOS/iPadOS: a button can show an inline activity indicator (with an alternate label like "Checking out…") for actions that do not complete instantly.
- macOS extras: push buttons (default type; ellipsis when the button opens another window/view; flexible-height only for tall content), square/gradient buttons (symbol-only, view-adjacent, never in toolbars), help buttons (one per window, standard placement table), image buttons (~10 px padding inside the clickable edge).
- visionOS: circular for icon-only, capsule for text; centers 60 pt apart; white-fill-black-text is reserved for the toggled state.
- watchOS: full-width capsule buttons for primary actions; equal heights in stacks.

## Context menus

- [PREFER] Relevance over completeness: the commands people most likely need for this item, not advanced or rare ones. Small item count.
- [ALWAYS] Consistency: if some items have context menus and others do not, the feature reads as broken.
- [ALWAYS] "Always make context menu items available in the main interface, too." Hidden-by-default means the menu can never be the only route.
- [ALWAYS] Hide unavailable items, do not dim them (opposite of regular menus; macOS Cut/Copy/Paste excepted).
- [ALWAYS] Destructive items (iOS/iPadOS/visionOS): last in the menu, marked destructive (red).
- Submenus at most one level, intuitively titled. No keyboard shortcuts shown (they belong in main menus).
- iOS/iPadOS: an item gets a context menu or an edit menu, never both; previews should clarify the target and animate cleanly (clipping path matches the preview shape).

## Menus (the general rules all menu types inherit)

- Labels: verbs or verb phrases; title-style capitalization; drop articles; ellipsis when more input is needed; dimmed (not hidden) when unavailable, and a menu with all items unavailable still opens.
- Icons: standard concepts for common actions; use them "sparingly and with purpose"; within one group, icons on all items or none.
- Organization: important/frequent items first; separators for logical groups; related commands stay in one group even at mixed frequencies (Paste and Match Style next to Paste); split or submenu overly long menus, except user-generated menus (History, Bookmarks) which may scroll.
- Submenus: sparingly, one level, roughly five items maximum; the repeated term becomes the item label ("Sort by" → submenu Date/Score/Time); [PREFER] a submenu over indentation.
- Toggled items: a changeable label describing the current state (Show Map / Hide Map); add verbs when a bare state label is ambiguous (Turn HDR On); checkmarks for attributes in effect; consider one item that clears multiple attributes ("Plain").
- iOS/iPadOS menu layouts: small (4 unlabeled symbol items in a top row), medium (3 items with short labels), large (default list). Small only for tightly related sets everyone recognizes (Bold/Italic/Underline).

## Pop-up buttons

- A pop-up button presents "a flat list of mutually exclusive options or states": it is a *choice*, and its label shows the current selection.
- [PREFER] A useful default selection; a way to predict the options without opening (intro label); a Custom option instead of extra controls for the occasional case.

## Pull-down buttons

- A pull-down button presents "commands or items that are directly related to the button's action": it does *things*.
- [NEVER] "Avoid putting all of a view's actions in one pull-down button." Primary actions stay discoverable.
- [PREFER] At least three items (fewer wants plain buttons or toggles); not so many that finding one is slow.
- [ALWAYS] Destructive menu items get the red treatment and a confirmation (action sheet / popover).

## Edit menus

- [PREFER] The system-provided edit menu; custom copies of standard commands confuse.
- [ALWAYS] Standard reveal interactions (touch and hold, secondary click); no custom gestures for a standard task.
- [ALWAYS] Context-relevant commands only: no Copy without a selection, no Paste with an empty pasteboard.
- [PREFER] Let people select and copy noneditable content text (captions, statuses); not control labels.

## Activity views (share sheets)

- [ALWAYS] The Share button is the one route to the activity view; no duplicate custom paths.
- [ALWAYS] No duplicates of system actions; an app-specific variant gets a distinguishing title ("Print Transaction").
- Exclude inapplicable system tasks; long operations continue in the app (the sheet dismisses immediately), with no "it finished" notification for routine completions.

## Dock menus (macOS)

- [ALWAYS] Custom Dock items must exist elsewhere too (menu bar or UI); high-value items only (open windows, compose-new).

## Home Screen quick actions (iOS/iPadOS)

- Icon-plus-title actions on app-icon long-press; dynamic actions are fine but [ALWAYS] change predictably.

## The menu bar (macOS)

- [ALWAYS] Support the standard menus in their standard order; the system implements much of it.
- [ALWAYS] "Always show the same set of menu items": dim unavailable ones, never hide, so the menu bar remains the app's complete command inventory.
- [ALWAYS] Standard keyboard shortcuts for standard items.
- [PREFER] One-word menu titles; About first in the app menu with a separator; a View menu even for a subset (full screen alone); show/hide titles reflect current state.

## Ornaments (visionOS)

- Controls that float at a window's edge; the system renders toolbars and tab bars as ornaments automatically. [PREFER] For frequently needed controls in a consistent spot; width no more than the window; borderless buttons on the glass background.

## Toolbars

- Toolbar = title + navigation (back, search) + actions, in leading / center / trailing groupings. A tab bar navigates between app areas; a toolbar acts on the current view.
- [ALWAYS] "Choose items deliberately to avoid overcrowding"; the system supplies the overflow menu, never build one; a More menu only when genuinely needed.
- [PREFER] Reduce custom toolbar backgrounds and tints; let the content layer inform appearance, with a scroll edge effect separating bar from content.
- [ALWAYS] Standard Back and Close symbols, not text labels, consistent everywhere.
- [PREFER] Symbols for actions (text for un-symbolable ones like Edit); the `.prominent` style on exactly one primary action (Done/Submit), trailing side.
- [PREFER] Group by function and frequency; at most ~3 groups; fixed space between adjacent text-labeled buttons so they do not read as one.
- iOS: only the essentials in the bar; large title collapsing to standard on scroll for orientation.
- iPadOS/macOS: user-customizable toolbars for large action sets; macOS requires every toolbar item to also exist in the menu bar (toolbars can be hidden).
- watchOS: corner toolbar buttons stay visible over scrolling content; a scrolling toolbar button (hidden until scroll-to-top) suits an important non-primary action (Mail's compose above the inbox).

# Selection and input

## Color wells

- [PREFER] The system color picker: consistent, and people's saved colors follow them across apps.

## Combo boxes (macOS)

- Text field + pull-down in one: type a custom value or pick a predefined one (custom values are not added to the list). Intro label with a colon; list items no wider than the field.

## Digit entry views (tvOS)

- Full-screen PIN entry; [ALWAYS] secure (asterisked) for sensitive digits.

## Image wells (macOS)

- An editable image drop target; if it supports copy/paste, the standard menu items and shortcuts must work.

## Pickers

- [PREFER] A picker for medium-to-long lists; a pull-down button for short lists (a picker over-weights them); a list/table for very large sets (height-flexible, indexable).
- [ALWAYS] "Use predictable and logically ordered values": hidden values must be guessable (alphabetized countries).
- [ALWAYS] Show the picker in context (near the field, bottom of window, popover); "avoid switching views to show a picker."
- Date pickers: compact style (a button opening a modal calendar) when space is constrained; consider coarser minute intervals (0/15/30/45).

## Segmented controls

- A linear set of 2+ segments, each a button; single choice (or multi-choice on macOS), or a momentary action set.
- [ALWAYS] "Keep control types consistent within a single segmented control": never mix action segments with selection segments.
- [PREFER] Equal-width segments; text or images, never both in one control; noun labels in title case; no introductory label for text segments.
- [PREFER] For switching closely related subviews (Calendar's Event/Reminder); a tab bar for separate app sections.

## Sliders

- Continuous value on a track; [ALWAYS] standard directionality (minimum leading/bottom, maximum trailing/top).
- [PREFER] Live feedback while dragging; a paired text field + stepper for wide ranges; icons illustrating the extremes; tick marks (with labels at least at the extremes) for scale.

## Steppers

- Increment/decrement control; shows no value itself, so [ALWAYS] the affected value sits visibly next to it; pair with a text field when large changes are likely.

## Text fields

- For "small, specific pieces of text"; text views for anything longer.
- [ALWAYS] Hint/placeholder shows the format ("name@example.com") plus a persistent label (placeholders vanish on typing).
- [ALWAYS] Secure fields for sensitive data.
- [PREFER] Logical tab order; number formatters for numeric data (locale-aware); a Clear button at the trailing end; leading-end images to signal purpose.
- [ALWAYS] Match the virtual keyboard type to the content.

## Toggles

- A pair of opposing states, always state, never actions ("a toggle always lets people manage the state of something").
- [ALWAYS] State differences must be obvious and never carried by color alone.
- [ALWAYS] The switch style lives only in list rows (the row content is its label).
- [PREFER] Keep the default green switch unless the accent color genuinely contrasts.
- macOS adds checkboxes and radio buttons; all belong in the window body, never toolbars or status bars.

## Virtual keyboards

- [ALWAYS] Choose the keyboard type matching the content; semantic content types improve autofill and corrections.
- [PREFER] Customize the Return key when it clarifies (Search).
- Custom input views must justify themselves; custom keyboards need an obvious Globe-style switch back and must not duplicate system keys.
