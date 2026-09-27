# Inputs (13 HIG pages)

One section per HIG page. Tags per the skill's strength model; quoted sentences are Apple's. Standard gesture vocabulary lives in specifications.md.

## Gestures

- [ALWAYS] "Give people more than one way to interact with your app." Voice, keyboard, Switch Control; never assume a specific gesture is available to everyone.
- [ALWAYS] Standard gestures do standard things everywhere: [NEVER] a familiar gesture repurposed for an app-unique action, and [NEVER] a unique gesture for a standard action.
- [ALWAYS] Respond immediately and continuously; feedback during the gesture predicts the result.
- [ALWAYS] "Indicate when a gesture isn't available": a silent non-response reads as a frozen app (a locked object that will not drag, an unavailable button whose state looks identical).
- Custom gestures: only for frequent specialized tasks (games, drawing); must be discoverable, easy to perform, distinct, and [ALWAYS] never the only route to an important action. Shortcut gestures supplement standard controls, never replace them (the Back button stays even when edge-swipe exists).
- [ALWAYS] Do not collide with system gestures (edge swipes, Home indicator).
- iOS/iPadOS extras people expect: three-finger swipe undo/redo, three-finger pinch copy/paste, four-finger app switch (iPad), shake undo.
- visionOS: indirect (look + pinch) is the default and comfortable at any distance; direct touch for near objects and short periods; never require specific body movements.

## Keyboards (hardware)

- [PREFER] Support Full Keyboard Access (iOS, iPadOS, macOS, visionOS): full navigation by keyboard alone.
- [ALWAYS] Modifier keys behave conventionally (Option-drag duplicates, Shift constrains).
- Shortcuts: list the upper character, not Shift-plus-lower (Command-? not Shift-Command-/); [NEVER] a modifier added to a famous shortcut for an unrelated command (Shift-Command-Z is redo, nothing else); let the system localize and RTL-mirror shortcuts.

## Apple Pencil and Scribble

- [ALWAYS] Mark on contact; no mode or button first. The pencil mirrors a real marking tool.
- [ALWAYS] Controls respond to Pencil too; a Pencil-dead button reads as a malfunction.
- [PREFER] Respond to force/tilt/azimuth for continuous properties (opacity, brush size); hover previews the mark; design for both hands; Scribble means handwriting into any text field works.

## Action button (iPhone, Apple Watch)

- [PREFER] Essential, frequently repeated functions; no "open the app" action (the system covers that).
- [PREFER] Complete without leaving context: a Live Activity or snippet, not an app launch.
- Secondary press advances the action, never stops it (people press without looking); at most one secondary function.

## Camera Control (iPhone)

- Overlay controls during capture: SF Symbols only (no custom), short Dynamic-Type labels, units on slider values, common controls centered, UI kept clear of the overlay area; a locked-camera extension lets the button launch the app's camera from anywhere.

## Digital Crown (watchOS)

- The primary scroll/navigate input; also great for inspecting data (World Clock scrubs time).
- [ALWAYS] Visual feedback for every turn; an unresponsive Crown reads as broken. Haptic detents on by default; disable or switch to linear when they fight the animation or row heights.

## Eyes (visionOS)

- Look targets, hover effects confirm; [PREFER] standard components (consistent hover behavior).
- [HARD] 16 pt margin around interactive items or centers 60 pt apart; crowded targets fight the eye's micro-movements.
- [ALWAYS] Multiple ways to interact (accessibility); avoid field-filling repeating patterns (false depth); draw attention with subtle cues (center placement, gentle motion, contrast), never flash.

## Focus and selection (tvOS, keyboard navigation)

- [ALWAYS] "Avoid changing focus without people's interaction." The focus indicator is where people are; moving it silently strands them. Exception: a focused item disappearing under discrete directional input moves focus to a neighbor; otherwise hide the indicator.
- Focus moves in reading order through focus groups; custom stacks may need explicit grouping.
- [NEVER] A pointer on tvOS; focus is the navigation model. Focused items scale up: supply larger assets and leave room.

## Game controls

- [HARD] Frequent virtual controls at least 44x44 pt; secondary at least 28x28 pt.
- [ALWAYS] Visible and tactile press states (glow that survives a covering finger, plus sound and haptics).
- [PREFER] Action-depicting artwork over abstract A/X/R1 labels; show/hide controls with context; controller support always has a default-input fallback; symbols over text for controller buttons.

## Gyroscope and accelerometer

- Motion data enables shake, orientation, and movement-driven features; motion input needs alternatives (accessibility) and permission-appropriate handling. (Page is brief; its substance lives in Gestures and Privacy.)

## Nearby interactions (UWB)

- Ground tasks in physical-world intuition (bring devices together to transfer); feedback continuous and proximity-graded (arrow to pulsing circle); combine visual, audio, haptic; [ALWAYS] never the only way to perform the task; the sensor has a camera-like field of view (direction data drops outside it).

## Pointing devices (trackpad, mouse; iPadOS pointer)

- [NEVER] Redefine systemwide trackpad gestures.
- [ALWAYS] Consistent behavior across input modes; a modifier-drag does the same thing via touch and pointer.
- Pointer reveals auto-hidden controls on hover; band selection for multi-select; pointer accessories are small, simple images, with transitions signaling state changes (plus to circle.slash).

## Remotes (tvOS)

- [PREFER] Standard gestures for standard actions outside gameplay.
- [ALWAYS] Play/Pause does exactly that during media; Menu steps back and eventually to the Home Screen; feedback shows what gestures will do (thumb-rest hints).
