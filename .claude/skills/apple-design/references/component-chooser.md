# Component chooser: task → component, in Apple's own words

Every row is built from Apple's comparative guidance and names its source page. When two rows disagree for a case, the more specific page wins. Use in design-new and consult modes; the component's full rules live in the components-* references.

## "I need to interrupt with something"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| Critical problem, data-loss warning, or confirming an important action | Alert | "An alert gives people critical information they need right away" (Alerts) |
| Choices that follow from an action the person just took | Action sheet | "Use an action sheet — not an alert — to offer choices related to an intentional action... an alert is usually unexpected" (Action sheets) |
| An error | Alert, never a notification | "Use an alert — not a notification — to display an error message" (Notifications) |
| Purely informational news | Neither; put it in context | "Avoid using an alert merely to provide information" (Alerts); status integrates into the interface (Feedback) |
| Common, undoable deletion | Nothing | "Avoid displaying alerts for common, undoable actions, even when they're destructive" (Alerts) |
| Uncommon, irreversible destruction | Alert with Cancel | "Warn people when they initiate a task that can cause data loss that's unexpected and irreversible" (Feedback) |

## "I need to present a task or content over the current screen"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| A scoped task closely related to the current context (create, edit, pick) | Sheet | "A sheet helps people perform a scoped task that's closely related to their current context" (Sheets) |
| An in-depth or multistep task, or media viewing | Full-screen modal style | "For complex or prolonged user flows, consider alternatives to sheets": the full-screen modal minimizes distractions (Sheets, Modality) |
| A small amount of temporary info or functionality, anchored to a control, on iPad/Mac | Popover | "expose a small amount of information or functionality"; the arrow anchors it (Popovers) |
| The same, on iPhone or any compact width | Sheet, never a popover | "Avoid displaying popovers in compact views... use all available screen space by presenting... a sheet" (Popovers) |
| Supplementary tools that act on the main view while it stays interactive | Nonmodal sheet (iOS) / panel (macOS) / split view pane | Notes' format sheet is the example (Sheets); panels float for the active window (Panels) |
| Repeated input-and-observe cycles (find and replace) | Panel, not a sheet (macOS) | "Use a panel instead of a sheet if people need to repeatedly provide input and observe results" (Sheets) |
| Details of the current selection, live-updating | Inspector panel or split-view pane | inspectors auto-update on selection change (Panels) |
| Any of the above, at all | First ask whether modality earns its cost | "Present content modally only when there's a clear benefit" (Modality) |

## "I need to offer actions"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| One instantaneous action | Button | "A button initiates an instantaneous action" (Buttons) |
| Frequent per-item actions, as a shortcut | Context menu | "access to functionality that's directly related to an item, without cluttering the interface"; the same items must also exist in the main UI (Context menus) |
| Text-editing actions on a selection | Edit menu (system one) | "Prefer the system-provided edit menu"; an item gets a context menu or an edit menu, never both (Edit menus) |
| Commands relating to one button's purpose | Pull-down button | "commands or items that are directly related to the button's action"; three-plus items to be worth the interaction (Pull-down buttons) |
| Choices after an action needing clarification | Action sheet, not a menu | "people expect a menu to appear when they choose to reveal it"; action sheets appear because of the action (Action sheets, iOS) |
| Sharing/exporting to other apps | Activity view via the Share button | "People are accustomed to accessing system-provided activities when they choose the Share button" (Activity views) |
| Actions on the current view, persistent | Toolbar | toolbars "act on content in the view"; tab bars do not hold actions (Toolbars, Tab bars) |

## "I need a choice or a value"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| Two opposing states (on/off) | Toggle | "a toggle always lets people manage the state of something" (Toggles) |
| One choice among a short flat list | Pop-up button | "a flat list of mutually exclusive options or states" (Pop-up buttons); a picker "may add too much visual weight to a short list" (Pickers) |
| One choice among a medium-to-long list | Picker | "Consider using a picker to offer medium-to-long lists of items" (Pickers) |
| A very large set | List/table | "consider using a list... tables can include an index" (Pickers) |
| 2 to ~5 closely related options, all visible, or switching related subviews | Segmented control | segments preserve grouping and show selection at a glance; "for switching between completely separate sections of an app, use a tab bar instead" (Segmented controls) |
| A date or time | Date picker (compact style when space is tight) | (Pickers) |
| A continuous value in a range | Slider, with standard min-leading direction | (Sliders) |
| Small precise increments | Stepper next to its visible value | "Steppers work well by themselves for making small changes" (Steppers) |
| Wide-ranging numeric value | Slider + text field + stepper together | "people may appreciate seeing the exact slider value and having the ability to enter a specific value" (Sliders) |
| Free text plus likely choices (macOS) | Combo box | text field + pull-down in one (Combo boxes) |
| Choose a color | Color well opening the system picker | saved colors follow people across apps (Color wells) |

## "I need text on screen"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| Small static text | Label | "a small amount of text that people don't need to edit" (Labels) |
| Small editable text | Text field | (Text fields) |
| Long or styled text, editable or not | Text view | "text that's long, editable, or in a special format" (Text views) |
| Sensitive input | Secure field, never prepopulated | (Entering data, Text fields) |
| Embedded web content | Web view, with back/forward when multi-page | "avoid using a web view to build a web browser" (Web views) |

## "I need to structure or navigate content"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| Top-level app sections | Tab bar (iPhone) / tab bar-sidebar adaptable (iPad) | "Use a tab bar to support navigation" (Tab bars); the adaptable style covers both (Sidebars) |
| Rows of text, scannable | List/table | "the row-based format is especially well suited to making text easy to scan" (Lists and tables) |
| Image-heavy or widely varying item sizes | Collection | (Lists and tables) |
| Hierarchical data (macOS) | Outline view | "use a table instead of an outline view to present data that's not hierarchical": and the converse (Outline views) |
| Deep hierarchy with frequent level-hopping (macOS) | Column view | (Column views) |
| Sidebar + content + detail | Split view, selections persistently highlighted | (Split views) |
| Closely related panes in one area | Tab view, at most six tabs | (Tab views) |
| An ordered flat set of pages | Page control | "page controls don't represent hierarchical or nonsequential page relationships" (Page controls) |
| Row navigation into a hierarchy | Disclosure indicator (chevron), not an info button | the info button "doesn't support navigation" (Lists and tables) |
| Hide advanced options until relevant | Disclosure control | "hide details until they're relevant" (Disclosure controls) |
| Group related controls visually | Box, or spacing/materials | negative space first; nested boxes read as busy (Boxes, Layout) |

## "I need to show status or ongoing state"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| Known-duration work | Determinate progress indicator | "when possible, use a determinate progress indicator" (Progress indicators) |
| Unknown duration | Indeterminate, switching to determinate when knowable | (Progress indicators) |
| Manual content refresh in a list | Refresh control | (Progress indicators) |
| A value within a range, glanceable | Gauge | (Gauges) |
| Ranking | Rating indicator | (Rating indicators) |

## "I need to reach people outside the app"

| Situation | Use | Apple's reason (source) |
| --- | --- | --- |
| Timely event worth an interruption | Notification, with an honest interruption level | "build trust by accurately representing the urgency" (Managing notifications) |
| Glanceable info that changes through the day | Widget | "timely, glanceable content"; not real-time (Widgets) |
| Real-time progress of a bounded event (under 8 hours) | Live Activity | "tasks and events that have a defined beginning and end" (Live Activities) |
| A frequent task runnable by voice or Action button | App Shortcut | (App Shortcuts) |
| A feature reachable from Control Center / Lock Screen | Control | actions that pay off "without having to launch your app" (Controls) |
| Routine background completion | Nothing | "avoid sending an unnecessary notification; instead, let people check on the task" (Multitasking) |
| Unread count | The app icon badge, only for that | "use a badge only to show people how many unread notifications they have" (Notifications) |

## When no system component fits

Apple's Familiarity principle: a custom control must name the requirement a system component cannot meet. If one is built, it inherits the system component's obligations anyway: the platform's minimum target (44 pt iOS, 20 pt minimum and 28 pt default on macOS), press state, focus/VoiceOver support, Dynamic Type, RTL, both appearances (Buttons, Accessibility, Gestures).
