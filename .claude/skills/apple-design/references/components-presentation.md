# Components: Presentation + Status + System experiences (22 HIG pages)

One section per HIG page. Tags per the skill's strength model; quoted sentences are Apple's. Widget/Live Activity dimensions live in specifications.md.

# Presentation

## Action sheets

- "Use an action sheet — not an alert — to offer choices related to an intentional action." An alert is unexpected news; an action sheet is choices about something the person just did (Mail's delete draft / save draft on cancel).
- [PREFER] Sparingly; it interrupts. Single-line titles; a message only when the title plus context is not enough.
- [ALWAYS] A Cancel button when a choice might destroy data, at the bottom (top-left corner on watchOS).
- [ALWAYS] Destructive choices styled destructive and placed at the top.
- iOS: an action sheet, not a menu, after an action needing clarification (menus appear when *requested*); avoid scrolling sheets.
- watchOS: at most four buttons including Cancel.

## Alerts

- "An alert gives people critical information they need right away." Problem, data-loss warning, or confirmation of an important initiated action.
- [ALWAYS] Sparingly; [NEVER] merely informational alerts (surface info in context instead); [NEVER] alerts for common undoable actions even when destructive; [NEVER] an alert at app startup.
- Content: title + optional message + up to three buttons (text field where supported). Titles specific and complete ("Error" and "Error 329347 occurred" are the named anti-examples), at most two lines; messages short, complete sentences.
- Buttons:
  - One or two words, verb phrases describing the result ("View All", "Reply", "Ignore"). "OK" only for purely informational acceptance; never "Yes"/"No".
  - [ALWAYS] "Cancel" titles the cancel action, exactly.
  - Placement: most-likely and default on the trailing side (or top of a stack); Cancel leading (or bottom).
  - Destructive style for destructive actions people did NOT deliberately choose (deliberately chosen Empty Trash stays plain, so Return confirms intent). [ALWAYS] A destructive action gets a Cancel button; the Cancel button is never the default; make no button the default when people must actually read the alert.
  - Escape and Command-period cancel; single-button informational alerts use "Done" not "Cancel".
- [NEVER] More than one alert at once (Modality).

## Page controls

- Indicator dots for an ordered, flat list of pages; not for hierarchy (use sidebar/split view).
- [PREFER] Simple custom indicator images if any; at most two distinct images (one special page like Weather's location); never colored (system handles contrast); no animated transitions while scrubbing.

## Panels (macOS)

- A floating supplementary surface for the active window/selection; inspectors are the classic use (auto-updating on selection change; a static Info window is a regular window instead).
- [PREFER] Simple direct controls (sliders, steppers) over typing; panels hide when the app deactivates; no minimize button; not in the Window menu's document list.

## Popovers

- A transient view anchored to what revealed it. [PREFER] For a small amount of temporarily needed information or functionality; it saves the permanent space a sidebar/panel costs.
- [ALWAYS] The arrow points at the revealing element; the popover does not cover it.
- Close buttons only when they add clarity (save vs discard); tap-outside dismissal is the norm, but multi-selection popovers stay open until explicit dismissal. [ALWAYS] Save work when a nonmodal popover auto-closes; discard only on explicit Cancel.
- [ALWAYS] One popover at a time; never a cascade; nothing over a popover except an alert.
- [NEVER] A popover as a warning (missable); alerts warn.
- [HARD] iPhone/compact widths do not get popovers; use a sheet. Popovers are a regular-width (iPad/Mac) pattern.

## Scroll views

- [ALWAYS] Default scrolling gestures, keyboard shortcuts, and elastic indicator behavior; people expect the systemwide feel everywhere.
- [ALWAYS] "Make it apparent when content is scrollable... displaying partial content at the edge of a view indicates that there's more content in that direction."
- [NEVER] "Avoid putting a scroll view inside another scroll view with the same orientation." Cross-orientation nesting is fine.
- Automatic scrolling only to keep people oriented (search result found, insertion point off-screen), and only as far as needed.
- Scroll edge effects: [PREFER] the automatic style; [ALWAYS] "only use a scroll edge effect when a scroll view is behind floating interface elements. Scroll edge effects aren't decorative"; [HARD] one per view (per pane in split views, height-matched).
- iOS paging: show a page control, and not a scroll indicator on the same axis.
- watchOS: prefer vertical scrolling (Digital Crown); tab views for page-by-page; single-screen pages read as glanceable.

## Sheets

- "A sheet helps people perform a scoped task that's closely related to their current context."
- [PREFER] For complex or prolonged flows use alternatives: iOS full-screen modal style, a macOS window, full-screen mode.
- [HARD] One sheet at a time from the main interface; a sheet-triggered sheet replaces its parent rather than stacking.
- Buttons: Cancel/Close (discard) leading, Done (commit) trailing, Back for multistep. [ALWAYS] Never Done alone (it implies completing is the only exit); [NEVER] all three of Cancel, Done, Back together.
- iOS resizable sheets: detents (large = full, medium = about half, custom allowed); [PREFER] the medium detent for progressive disclosure (share sheet) but full-only for composition (Messages, Mail); [ALWAYS] a grabber on resizable sheets (visible affordance + VoiceOver resize); [ALWAYS] swipe-to-dismiss, with an action sheet confirming when unsaved changes would be lost.
- Nonmodal sheets (iOS/iPadOS) let the parent stay interactive (Notes' format sheet) for supplementary tools.
- macOS: sheet is a card on a dimmed parent window; other windows stay reachable; a panel beats a sheet for repeated input-observe cycles (find and replace).

## Windows

- [PREFER] Open new windows at moments that aid multitasking (Mail compose) and offer view-in-new-window as an option, but [NEVER] as default behavior everywhere; clutter confuses.
- [NEVER] Custom window frames or controls; imperfect replicas read as broken.
- The user-facing word is "window" (never "scene").

# Status

## Activity rings

- [HARD] Move/Exercise/Stand only, one person only, visual appearance never modified, never replicated for other data, "never show Move, Exercise, and Stand progress in another ring-like element."

## Gauges

- A value within a range on a circular or linear path; capacity style fills to the value. Gradients can encode meaning (red-hot to blue-cold). macOS level indicators: continuous style for large ranges; fill color changes at significant thresholds.

## Progress indicators

- [PREFER] Determinate over indeterminate whenever duration is knowable; switch from indeterminate to determinate the moment it becomes knowable.
- [ALWAYS] "Keep progress indicators moving": a stationary indicator reads as a frozen app; a stalled process gets an explanation.
- Descriptions add context only when accurate and specific; "loading" and "authenticating" are the named useless words.
- [PREFER] A Cancel (and Pause when interruption loses progress) on long tasks; warn when cancelling loses progress.
- Refresh control (iOS): drag-down manual reload in scrolling views, hidden by default.

## Rating indicators (macOS)

- Whole symbols only (values round); stars unless a custom symbol is unmistakably a rating; inline rank editing.

# System experiences

## App Shortcuts

- [PREFER] The app's most common tasks, completable without leaving context; discoverable via in-app tips.
- Phrases: brief, memorable, include the app name, with natural variants ("Create a Keynote"); complicated-to-say means too complicated. Extra parameters get asked in a follow-up step, not packed into the phrase.
- Audio-only devices (AirPods, HomePod) need all critical info in the spoken dialogue.

## Complications (watchOS)

- [PREFER] Support all families (fall back to an app-icon image where data does not fit) and multiple complications per family; shareable watch faces are the discovery surface.
- Always-On makes the face visible to others: privacy-sensitive data stays off it.
- [PREFER] Ring/gauge layouts for changing numeric values; line widths 2 pt+; tinted-mode-safe images; static placeholder images per complication.

## Controls (Control Center / Lock Screen / Action button)

- A button or toggle reaching an app feature from outside the app. [PREFER] Actions that pay off without launching the app (starting a Live Activity is Apple's example).
- [ALWAYS] Keep the control's state truthful: update on interaction, completion, or push.
- Symbols carry the meaning (title may be hidden): descriptive, with distinct on/off symbols for toggles; animate state changes and in-progress actions.
- Action button: verb hint text; configurable controls prompt for setup on add.

## Live Activities

- Presentations: compact (leading + trailing around the Dynamic Island), minimal (when multiple are active), expanded (touch and hold), Lock Screen (also the banner form on non-Island devices).
- [HARD] "Tasks and events that have a defined beginning and end... that don't exceed eight hours." Not a widget, not a notification stream.
- [ALWAYS] No sensitive information; Lock Screen and Always-On are visible to bystanders; innocuous summary with detail behind a tap.
- Design: match the app's aesthetic in both appearances; logo mark without a container and never the full app icon; medium-weight-plus text, legible at a glance; concentric corner radii and even margins inside the Island's rounded shape; bold color on the Island's black background for identity.
- [ALWAYS] Tap opens the app at the exact related place. Buttons/toggles for respond-able updates (contact the driver).
- [ALWAYS] Update only when content actually changes; one Live Activity rotating through events beats several parallel ones.
- [ALWAYS] End immediately when the event ends; custom dismissal keeps the summary visible ~15 to 30 minutes on surfaces that retain it (Lock Screen retains up to 4 hours by default).
- [PREFER] An App Shortcut that starts the Live Activity (Action button integration).

## Notifications

- [ALWAYS] Concise and valuable; complete sentences, sentence case; [NEVER] pre-truncate (the system truncates).
- [NEVER] Multiple notifications for the same thing; that is how an app's notifications get turned off entirely.
- [NEVER] Notifications that instruct people to do tasks in the app; offer notification actions instead.
- [ALWAYS] Errors are alerts, not notifications.
- [ALWAYS] No sensitive/private content; anyone may see the screen. Provide the hidden-previews placeholder text ("Friend request", "New comment").
- [NEVER] The app name or icon in the content; the system shows both.
- Actions: common time-saving tasks, short title-case labels, no action that merely opens the app, prefer nondestructive (destructive get distinct styling), an icon per action.
- Badges: [HARD] only the unread-notification count, never other numbers; keep current (zeroing clears Notification Center); never the only channel for important information; never fake a badge with custom UI.
- Sounds optional, short, professional, never the only carrier of meaning.

## Snippets (Siri results)

- Concise results/confirmation views, max 400 pt tall; legible on the system background in both appearances; primary button named for the action ("Order", not "OK"/"Proceed").

## Status bars (iOS)

- [PREFER] Keep it visible (it carries time/battery/connectivity people check); temporarily hide for full-screen media with an obvious gesture to restore; [NEVER] permanently hidden.

## Top Shelf (tvOS)

- Full-screen showcase above the app in the Dock. Lead people straight into content (primary playback button + More Info); dynamic layered content over static; no ads or price-forward displays; titles for the current content.

## Watch faces

- Shareable preconfigured faces featuring the app's complications are a discovery channel; preview images; cover the device generations.

## Widgets

- "Quick access to essential information and focused interactions... timely, glanceable content."
- [PREFER] One simple idea tied to the app's main purpose; a widget that replicates the app icon earns no home-screen space.
- [PREFER] Dynamic content that visibly changes through the day; static widgets get removed.
- [PREFER] Offer the sizes that fit the content, not every size; bigger sizes add depth on the same purpose, never just scaled-up smallness.
- [ALWAYS] Deep links land on the exact related content; interactive elements (buttons, toggles, links) stay glanceable, never app-like layouts; comfortable tap targets.
- Brand: colors, typeface, glyphs yes; logo rarely (small, top-right, only when sources are mixed); [NEVER] an in-app element that looks like the widget but behaves differently.
- Signed-out states say what signing in adds ("Sign in to view reservations").
- Updates: frequency budgeted by the system; system-refreshed dates/times; no stale data behind placeholders; content-update animations up to 2 seconds.
- Text: system font and text styles; [HARD] no text under 11 pt; [NEVER] rasterized text (breaks scaling and VoiceOver).
- Appearances: full-color, accented/tinted, clear; support light and dark via semantic colors; vibrant/tinted modes desaturate full-color images (reserve full color for genuine media like album art); light-gray-on-transparent hierarchy for Lock Screen vibrancy; StandBy wants no background color and scaled-up text; Always-On needs contrast at reduced luminance.
- Gallery: realistic preview data; placeholder skeletons (shape stand-ins) while loading.
- Real-time is not the widget's job: "Widgets don't show real-time information. If your app allows people to track the progress of a task or event... consider offering Live Activities." Build the two together; they share frameworks.
