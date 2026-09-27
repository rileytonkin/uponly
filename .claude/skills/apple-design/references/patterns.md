# Patterns (25 HIG pages)

One section per HIG page. Tags per the skill's strength model; quoted sentences are Apple's.

## Charting data

- [PREFER] A chart only when you want to highlight information about data; plain lists/tables when people just need the data.
- [PREFER] "Keep a chart simple, letting people choose when they want additional details." Progressive levels beat packed density.
- [ALWAYS] Every chart is accessible: accessibility labels describing values and components, plus elements for interaction. A descriptive headline ("Chance of light rain in the next hour") aids everyone but does not replace labels.
- [PREFER] Common chart types (bar, line); a novel form needs to teach itself (Activity animates its rings apart on first pairing).
- [PREFER] Consistency across charts of the same data: same type, colors, annotations, layout, so learning transfers and the dataset reads as one.

## Collaboration and sharing

- [PREFER] Put the Share button somewhere conventional (toolbar); use the system share sheet / ShareLink so people get familiar destinations and permissions UI.
- [PREFER] Permission summaries as succinct phrases ("Only invited people can edit"); minimal custom sharing options, grouped for glanceability.
- [PREFER] Show the system Collaboration button prominently once collaboration starts, next to Share; keep custom items in its popover to the essentials.

## Drag and drop

- [ALWAYS] "Offer alternative ways to accomplish drag-and-drop actions" (menu commands, buttons); a drag must never be the only route.
- [PREFER] Multi-item drag where it makes sense; undo for drops (or confirmation when a drop is irreversible).
- Feedback mechanics: show a translucent drag image after ~3 pt of movement; show whether a destination can accept (highlight/insertion point, or `circle.slash` when not); animate failed drops back or fade them out; progress indication for slow transfers.
- [PREFER] Offer dragged content in multiple fidelities, richest first; accept the richest version you can.

## Entering data

- [ALWAYS] "Get information from the system whenever possible." Never ask people to type what settings, permissions, or the platform can supply.
- [PREFER] Choices over typing: pickers, menus, selection controls. Support paste and drag-in.
- [ALWAYS] Be clear about the needed data: labels, placeholder examples, prefilled sensible defaults.
- [ALWAYS] Secure fields for sensitive input; [NEVER] "Never prepopulate a password field."
- [ALWAYS] "Dynamically validate field values": errors surface as people type, not after the form. Number formatters constrain numeric fields.
- [PREFER] Gate Continue/Next on required fields being filled, so the requirement is visible before the mistake.

## Feedback

- Feedback kinds: current status, success/failure of a task, warning before consequences, opportunity to correct. "Match the significance of the information to the way it's delivered": passive display for status, interruption only for danger.
- [ALWAYS] Feedback is accessible: color plus text plus sound plus haptics, so it lands whichever channel is available.
- [PREFER] Integrate status into the interface near what it describes (Mail's unread count in the toolbar), instead of interrupting.
- [ALWAYS] Alerts only for critical, ideally actionable information; overuse kills their force.
- [ALWAYS] Warn on unexpected, irreversible data loss; [NEVER] warn when loss is the expected result (Finder does not confirm every file deletion).
- [PREFER] Confirm completion only for significant actions (a payment); people assume success and mostly need to hear about failure.
- [ALWAYS] When a command cannot run, say so and say why.
- watchOS: [NEVER] indeterminate spinners; promise a notification instead.

## File management

- [ALWAYS] "Help people be confident that their work is always preserved unless they cancel or delete it." Autosave; no explicit save step.
- [PREFER] System open/save interfaces; Quick Look previews for files the app cannot open; a file provider extension filtered to context-appropriate documents.

## Going full screen

- [PREFER] Full-screen mode for concentration and immersion: games, media, deep tasks.
- [ALWAYS] "Let people choose when to exit full-screen mode"; never end it for them.
- iOS: keep the standard one-swipe Home indicator behavior; defer system gestures (two swipes) only when accidental exits are a real, observed problem.
- macOS: use the system full-screen support (it handles the camera housing); adjust proportions in full screen but do not programmatically resize the window.

## Launching

- [HARD] "Launch instantly." A couple of seconds is the tolerance.
- Launch screen (iOS/iPadOS/tvOS): its sole job is perceived speed. [ALWAYS] Nearly identical to the app's first screen; [NEVER] text on it (unlocalizable); [NEVER] logos or advertising ("the launch screen isn't a branding opportunity").
- [ALWAYS] "Restore the previous state when your app restarts" down to scroll position and window arrangement; nobody retraces steps.
- [PREFER] Launch in the device's current orientation.
- A splash screen, if one exists at all, belongs at the start of onboarding, shown just long enough to absorb at a glance.

## Live-viewing apps

- [PREFER] One tap or zero to playback ("Watch Now" over featured content); mark live content visibly (badge/sash); show progress through in-progress content; consistent ordering of secondary actions (Watch, Start Over, Record, Favorite).

## Loading

- "The best content-loading experience finishes before people become aware of it."
- [ALWAYS] "Show something as soon as possible": placeholder text, graphics, or animations that content replaces. A blank wait reads as breakage.
- [PREFER] Load in the background while people do other things; long unavoidable loads get something worth viewing (tips, hints).
- Determinate progress when duration is known, indeterminate when not (see Progress indicators).
- watchOS: content immediately; a loading indicator only beats a blank screen.

## Managing accounts

- [ALWAYS] Require an account only if core functionality requires it; explain the benefit in the sign-in view.
- [ALWAYS] "Delay sign-in for as long as possible." People abandon apps that demand sign-in before value (browse first, sign in to buy).
- [PREFER] Sign in with Apple or passkeys; two-factor if passwords persist; name the auth method on the button ("Sign In with Face ID"); reference only methods the device has; no app-level biometrics opt-in setting; never the word "passcode" for an app account.
- Deletion (App Store requirement, not advice): [HARD] in-app account deletion, not deactivation, discoverable, not buried in policy pages; consistent between app and web; tell people when deletion completes and notify when finished; explain how subscription billing continues through Apple until cancelled. Scheduling deletion for later is allowed alongside an immediate option.

## Managing notifications

- Permission is prerequisite; people can silence everything. Focus filters and scheduled summaries mediate delivery.
- Interruption levels for noncommunication notifications: passive (leisure), active (default), time-sensitive (breaks through Focus and scheduling), critical (entitlement-gated, overrides silence).
- [ALWAYS] "Build trust by accurately representing the urgency of each notification." Inflated urgency is how people turn everything off.
- [HARD] Time Sensitive only for events happening now or within the hour; the system audits it with users.
- Marketing: [HARD] explicit opt-in before any promotional notification, an in-app setting to change the choice, and [NEVER] Time Sensitive for marketing.

## Modality

- Modality's legitimate jobs: critical information requiring action; confirming or modifying the last action; a distinct narrow task without losing context; immersion.
- [ALWAYS] "Present content modally only when there's a clear benefit."
- [ALWAYS] "Aim to keep modal tasks simple, short, and streamlined"; a modal hierarchy risks "an app within your app": if subviews are unavoidable, one path through, and no buttons mistakable for dismiss.
- [PREFER] Full-screen modal style for in-depth content or multistep tasks (photo editing, camera, video).
- [ALWAYS] An obvious dismiss, matching platform convention (top-bar button or swipe-down on iOS/watchOS).
- [ALWAYS] Confirm before closing if closing loses user-generated content (an action sheet with save/discard).
- [ALWAYS] Title the modal's task; people return from context switches and need their place.
- [ALWAYS] One modal at a time; [NEVER] more than one alert at the same time, ever.

## Multitasking

- [PREFER] Notify only for important or time-sensitive completions the person left mid-task; routine background completions wait to be discovered.
- iPadOS windowed apps resize like macOS; visionOS masks unfocused windows itself (do not restyle window edges).

## Offering help

- [PREFER] Help matched to the task's size: inline hints for one/two-step tasks, tutorials only for genuinely complex flows; always dismissible and avoidable.
- Tips (TipKit): for features describable in one or two sentences and at most ~3 actions. [ALWAYS] Action-oriented, non-promotional, eligibility-ruled so people who used the feature never see its tip, frequency-capped (~one per 24h).
- Tooltips (macOS/visionOS): describe the one control, start with a verb, ~60 to 75 characters, sentence case, no repeating the control's name.
- [ALWAYS] Never explain standard platform components; explain what they do in this app.

## Onboarding

- "Design a flow that's fast, fun, and optional." Onboarding follows launch; it is not part of it.
- [PREFER] "Teach through interactivity": doing beats reading; context-specific tips often beat a single upfront flow.
- [ALWAYS] Skippable tutorials never re-present on later launches, but stay findable (help/settings).
- [ALWAYS] Teach the app, not the system or device.
- [ALWAYS] Postpone nonessential setup; good defaults over configuration.
- Permission requests inside onboarding only when the app cannot function without them; otherwise at first use of the feature (see foundations → Privacy).
- [PREFER] "Prefer letting people experience your app or game before prompting them for ratings or purchases."

## Playing audio

- [PREFER] System volume view; [NEVER] repurpose audio controls or respond to controls you do not support.
- Custom players only for commands the system lacks; flag temporary interruptions so other apps resume.

## Playing haptics

- [ALWAYS] Use system haptic patterns per their documented meanings; a standard pattern re-purposed confuses learned associations.
- [ALWAYS] Consistent cause-and-effect: one pattern, one meaning; never the failure haptic for success.
- [PREFER] Haptics complement visuals and audio in matched intensity and sharpness, synchronized.
- [ALWAYS] "Avoid overusing haptics... the best haptic experience is one that people may not be conscious of, but miss when it's turned off."
- [ALWAYS] "Make haptics optional" and fully enjoyable without them.

## Playing video

- [PREFER] The system video player; a custom player must mirror system behaviors or habitual interactions break.
- [ALWAYS] Original aspect ratio, no embedded letterbox padding (it defeats system scaling and PiP).
- [ALWAYS] Space bar plays/pauses on any connected keyboard, every platform.
- [PREFER] Resume automatically at the previous stopping point without asking.

## Printing

- [PREFER] Print action in standard places (File menu, toolbar action sheet); hidden or dimmed when nothing can print; system print panel for options.

## Ratings and reviews

- [ALWAYS] Ask "only after people have demonstrated engagement"; [NEVER] on first launch or during onboarding.
- [ALWAYS] Ask at natural stopping points, never mid-task.
- [ALWAYS] No pestering: a week or two minimum between asks, after further engagement.
- [PREFER] The system prompt (RequestReviewAction): consistent, dismissible in one tap, and [HARD] system-capped at three displays per app per 365 days. A custom rating UI spends goodwill the system prompt protects.

## Searching

- [PREFER] If search matters, give it a primary position (dedicated tab, or the toolbar).
- [PREFER] One clearly identified search location covering the app's content; local scoped search only for clearly distinct sections.
- [ALWAYS] Show the current scope (placeholder text, scope bar, or title).
- [PREFER] Recents and suggestions to reduce typing; a way to clear search history (privacy).
- Spotlight indexing makes content findable without opening the app.

## Settings

- [ALWAYS] "Aim to provide default settings that give the best experience to the largest number of people." Detect instead of asking.
- [ALWAYS] "Minimize the number of settings you offer."
- [NEVER] Duplicate systemwide settings (appearance, accessibility, authentication) as custom app settings; it implies the system ones might not apply. (This is the HIG's own case against an in-app dark-mode toggle.)
- Placement ladder: task-specific options live in the task's own screen; general infrequent options in the app's settings area; only the rarest in the system Settings app (with a direct link from the app if used).
- watchOS: no custom settings in the system app; a few essentials at the bottom of the main view.

## Undo and redo

- [ALWAYS] Help people predict what will be undone (name it: "Undo Typing") and show the result (scroll to the restored paragraph); an invisible undo gets repeated until damage is done.
- [ALWAYS] Multiple undos; no arbitrary depth limits.
- [PREFER] Batch-revert for incremental adjustments.
- [NEVER] Redefine the standard gestures (three-finger swipe, shake); dedicated buttons only when necessary, with standard symbols, in a toolbar.

## Workouts (watchOS)

- [PREFER] During a session: only relevant information, a visually distinct active state, easy pause/resume/stop, a summary screen at the end; legible-in-motion text (large sizes, high contrast).
- [HARD] Activity rings only for their documented purpose, never decorative.
