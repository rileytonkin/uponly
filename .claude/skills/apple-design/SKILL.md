---
name: apple-design
description: Apply Apple's Human Interface Guidelines to this repository's macOS app (menu bar extras, popovers, sheets, windows): redesign plans, screen audits, new designs, UI diff reviews and HIG questions. Web work uses apple-design-web.
---

# Apple Design (Human Interface Guidelines)

This skill carries Apple's Human Interface Guidelines as distilled reference files plus the procedures that make them land on real screens. Every rule in the references was extracted from Apple's published HIG (developer.apple.com/design/human-interface-guidelines, June 2026 content), keeping Apple's own imperatives and numbers. Where a reference quotes, it quotes Apple. Nothing in the references is invented guidance.

The skill exists because generic advice fails. "Use system text styles, respect the standard margins" helps nobody. What helps is: a screenshot of the real popover in the relevant state, a count of the hardcoded font sizes in that view, the Apple sentence that makes each one a finding, and a severity-ordered plan with file and line. The procedures below produce that second thing.

The apps this skill serves are small SwiftUI macOS menu bar apps: a status item in the menu bar, a popover or window-style `MenuBarExtra` under it, sheets inside that, and sometimes a Settings window or a regular window. Read every rule through that lens. iOS-only guidance (tab bars, Dynamic Type scaling, safe areas, haptics) binds only when the app also ships on iOS.

## Step 0, for every mode: read the repository's own guidance first

Before any mode below, read the repository's `AGENTS.md`, `CLAUDE.md` and `README.md` (and any file they point to for design, such as a design tokens file). They tell you:

- **Deliberate departures from the HIG.** Any departure recorded there is a decided trade, not a finding. Reporting one as a violation wastes a round; "fixing" one destroys a decision. If you believe a departure itself is wrong, say so separately as a question for the owner, never as a finding.
- **The house design system**, if there is one: colors for light and dark, spacing, radii, type. A value that matches the house tokens is not a hardcoded-value finding; a value that bypasses them is.
- **Copy rules** the repo holds that are stricter than Apple's (for example, no dashes in user-facing copy).
- **Where the app may be built, run and captured.** Some repositories forbid running anything on the owner's Mac beyond documented steps; others name the machine and tool to verify with. Those rules bind every capture step below.

## Capture route (only for work needing real screen evidence)

HIG questions use the relevant references; they do not need the app running. For screen audits, design verification or before/after captures, follow the repository's own guidance for where the app may be run and captured:

- Some repositories forbid running the app on the owner's Mac except for documented install steps. There, ask the owner before running or capturing anything on that Mac.
- claude-switch verifies UI with FlowDeck on the MacBook Pro, with background actions.
- A repository may offer launch options that put the app into a given state (for example, a scenario, an appearance and an open popover from the command line). Prefer those to clicking through.

Never take the owner's cursor or focus to get a capture. Save screenshots under `.context/` and never move them through gists, pastebins or other outside services. If the app cannot be run, say which capture rows were not captured and why, and do not report findings about those states.

## The reference shelf

Load only what the task needs. Each file keeps one heading per HIG page, with Apple's section names underneath, so grep lands.

| File | Holds |
| --- | --- |
| `references/specifications.md` | Every hard number Apple states: control sizes and hit targets, contrast ratios, text sizes for custom type, the macOS text styles (fixed sizes, no Dynamic Type), the iOS Dynamic Type scale, app icon sizes, widget sizes, standard gestures. Apple publishes no numeric side margin |
| `references/component-chooser.md` | Task to component decision tables, built from Apple's own X-versus-Y guidance, each row cited |
| `references/principles-and-platforms.md` | Design principles + Designing for iOS / iPadOS / macOS / tvOS / visionOS / watchOS / games |
| `references/foundations.md` | Accessibility, App icons, Branding, Color, Dark Mode, Icons, Images, Immersive experiences, Inclusion, Layout, Materials, Motion, Privacy, Right to left, SF Symbols, Spatial layout, Typography, Writing |
| `references/patterns.md` | All 25 Patterns pages: Charting data, Collaboration and sharing, Drag and drop, Entering data, Feedback, File management, Going full screen, Launching, Live-viewing apps, Loading, Managing accounts, Managing notifications, Modality, Multitasking, Offering help, Onboarding, Playing audio, Playing haptics, Playing video, Printing, Ratings and reviews, Searching, Settings, Undo and redo, Workouts |
| `references/components-actions.md` | Menus and actions (Activity views, Buttons, Context menus, Dock menus, Edit menus, Home Screen quick actions, Menus, Ornaments, Pop-up buttons, Pull-down buttons, The menu bar, Toolbars) + Selection and input (Color wells, Combo boxes, Digit entry views, Image wells, Pickers, Segmented controls, Sliders, Steppers, Text fields, Toggles, Virtual keyboards) |
| `references/components-structure.md` | Layout and organization (Boxes, Collections, Column views, Disclosure controls, Labels, Lists and tables, Lockups, Outline views, Split views, Tab views) + Navigation and search (Path controls, Search fields, Sidebars, Tab bars, Token fields) + Content (Charts, Image views, Text views, Web views) |
| `references/components-presentation.md` | Presentation (Action sheets, Alerts, Page controls, Panels, Popovers, Scroll views, Sheets, Windows) + Status (Activity rings, Gauges, Progress indicators, Rating indicators) + System experiences (App Shortcuts, Complications, Controls, Live Activities, Notifications, Snippets, Status bars, Top Shelf, Watch faces, Widgets) |
| `references/inputs.md` | Action button, Apple Pencil and Scribble, Camera Control, Digital Crown, Eyes, Focus and selection, Game controls, Gestures, Gyroscope and accelerometer, Keyboards, Nearby interactions, Pointing devices, Remotes |
| `references/technologies.md` | In-app purchase, Sign in with Apple, iCloud, Generative AI, Machine learning, Photo editing, Live Photos, Siri. Plus the list of 20 technologies deliberately not distilled |

One gap to know about: `references/components-actions.md` → The menu bar covers the app menus, not menu bar extras (status items). For a question about the status item itself, re-extract The menu bar page (see Provenance) and quote its Menu bar extras section rather than answering from memory.

## Rule strength, straight from Apple's verb

Every rule line in the references carries a tag derived from how Apple wrote it. The tag is Apple's signal, not this skill's opinion:

- `[HARD]`: a stated number or absolute requirement. 20x20 pt minimum control size on macOS. 4.5:1. These are never judgment calls.
- `[ALWAYS]` / `[NEVER]`: Apple wrote "Always", "Never", "Avoid", "Don't".
- `[PREFER]`: Apple wrote "Consider", "Prefer", "In general", "Try to". Guidance, weighable.

Severity for findings and review comments maps mechanically:

| Tag | Priority |
| --- | --- |
| `[HARD]` broken | P1 (P0 when the screen looks broken by eye: unreadable text, overlapping or clipped content, a control you cannot hit) |
| `[ALWAYS]` / `[NEVER]` broken | P2 |
| `[PREFER]` ignored | P3, or skip it as a nitpick unless the fix is trivial and clearly better |

This ordering means a generated plan is prioritized by Apple, not by taste.

---

## Mode 1: Redesign an existing screen the way Apple would (the default)

The prompt shape: "take a look at the popover and come up with a plan to improve it based on Apple's design guidelines."

**Read the job right.** The goal is to put an Apple designer onto the task and redesign the screen the way Apple would. So the deliverable is a **redesign with reasons**, not a list of rule violations. The rules are the floor. A screen can pass every `[HARD]` check in this skill and still be a mediocre screen, and reporting "12 findings, all P2" on a mediocre screen is a failed audit even when every finding is true.

An Apple designer does four things in order, and only the fourth is rule-checking:

1. **Decides what the screen is for**, in one sentence, and what its single most important element is.
2. **Ranks everything else** against that. First, second, third, and what should not be here at all.
3. **Makes type, space and weight express that ranking.** This is the bulk of the work and it is what §"The layout pass" below measures.
4. **Checks the result against the rules** and fixes what it broke.

Steps 5 and 6 below are where 1 to 3 happen. Do not skip to the sweep; a sweep is step 4's tool and it cannot tell you a screen has no hierarchy.

Run the steps in order. Skipping the captures or the layout pass produces the generic-advice failure this skill exists to prevent.

**0. Repository guidance.** As above. Note which recorded departures touch this surface.

**1. Drive the real screen. Do not settle for a screenshot.** Where the repository allows the app to run (see Capture route), open it, put the screen into each state below, and look at it closely. A default capture of the freshly opened popover is one cell of the matrix, not the audit.

**This step is why the skill exists, and skipping it produces the generic-advice failure.** Three ways a static capture lies:
- **Scroll position zero hides every finding that is about scrolling.** "Content passes behind the pinned footer with no edge effect" cannot be seen from the top of the list.
- **One record is one data shape.** A capture with a typical row cannot show the empty state, the missing-field fallback, a very long name, a hundred rows, or an error.
- **A component that was never read can sit in the frame.** Grepping the feature directory for files misses views composed from elsewhere; the screen is the inventory.

**The capture matrix.** Every row gets looked at, and the report names any row that was not captured and why.

| Axis | States |
| --- | --- |
| Scroll | top, mid-scroll, bottom. Inspect the final content-to-footer gap; fixed spacers can leave excessive clearance even when nothing clips |
| Data | empty, minimal (no optional fields), typical, maximal (long names, large numbers, many rows) |
| Mode | every layout toggle and transient mode the screen has (tabs, search active, selection, editing, a sheet open, a confirmation showing) |
| Container | the status item in the menu bar (light and dark menu bar, with any badge or count); the popover or window at its fixed size; for resizable windows, minimum and a large size |
| System | light and dark; Increase Contrast; Reduce Transparency wherever materials sit behind text; Reduce Motion wherever something animates |
| State | loading, error, offline or signed-out, whichever the app has |

Read functional state (values, toggles, labels, what is actually on screen) from the accessibility tree if the capture tool offers one; use screenshots for visual judgement only, and read every screenshot back before judging it.

When done, restore any system setting you changed (appearance, Increase Contrast, Reduce Transparency, Reduce Motion) so the next task does not inherit it.

**2. Read the code** for the surface. All of it, not the first file.

**3. Route.** Classify the surface with the router below and load only the reference sections that bind. A menu bar popover with a scrolling list and an add sheet loads: Layout, Typography, Color, Materials, Motion, Accessibility, Writing, Icons from foundations; Lists and tables, Search fields from structure; Popovers, Sheets, Scroll views from presentation; Buttons, Context menus, Menus, The menu bar from actions; Feedback, Loading, Modality from patterns.

**4. Measure the layout.** Run the layout pass below. This is the core of the work, not a formality, and it comes BEFORE the sweep because the sweep cannot see a hierarchy problem.

**5. Decide the redesign.** With the captures and the measurements in front of you, answer these four in writing before proposing anything. Each answer is one or two sentences.

- **What is this screen for?** One sentence. "See today's portfolio total and what moved it." If you cannot write it, the screen has no job and that is the finding.
- **What is the single most important element?** Name it. Then check whether the layout agrees: is it the largest, the first, the one with the most space around it? If it turns out to be a settings button in the corner, say so.
- **What is the ranking below it?** First, second, third. Everything unranked is a candidate for deletion or deferral.
- **What should not be here?** The most Apple move is removal, then deferral behind a click, a menu or a disclosure (Layout: progressive disclosure). Propose at least one thing to cut or defer, and be willing to conclude that nothing should go.

**6. Run the mechanical sweep** (below), scoped to the surface's directory. Record the counts. Counts are evidence; "looks fine" is not. This is the compliance floor, and it is the supporting material for the redesign, not the headline.

**7. Write the proposal. Do not start editing.** Lead with the redesign: what the screen should be, the type ramp, the spacing ramp, what moves, what goes. Then the compliance findings, severity-ordered by the tag mapping, in the finding format below. The owner decides what ships.

---

## The layout pass (the centre of the work)

Apple's Layout page is a set of judgements about grouping and emphasis. Judgements need numbers under them: "feels cramped" is not actionable, "every block is 24pt apart so nothing is grouped" is a fix. Measure first, then judge.

```bash
python3 .claude/skills/apple-design/scripts/measure_layout.py <capture.png>
```

It prints the content bands top to bottom in points, the gap between each, and the distinct gap values. By default it measures the whole image and assumes a Retina capture (2 px per pt); pass `--scale 1` for a non-Retina capture, `--width-pt` if you know the view's width in points, and `--frame x0,y0,x1,y1` to crop to the popover or window when the capture includes the desktop or menu bar. It does not measure margins; read left edges from the cropped capture. Read its docstring for the one trap: a full-bleed band (a chart, an edge-to-edge image or filled card) defeats its ink detection, so the band can vanish or merge with its neighbours. That is the tool failing, not the app. Sanity-check any surprising band or gap against the capture before reporting it.

Then judge these five.

**1. The spacing ramp.** Count the distinct gaps. A screen wants roughly three: a tight one inside a group, a medium one between groups, a large one before a new kind of thing. **One value used everywhere means negative space is grouping nothing**, which is the exact failure Apple's "Group related items... use negative space" warns about. The typical symptom: a title sits as far from its own subtitle as the button row sits from the list below it, so nothing reads as belonging to anything.

**2. The type ramp.** List every font size on the screen with its weight. A hierarchy needs separation: Apple's macOS text styles step 10, 11, 12, 13, 15, 17, 22, 26 (`references/specifications.md` → macOS built-in text styles). **Sizes within 1pt of each other cannot encode rank**, they just look inconsistent. The typical symptom: 11, 11.5, 12 and 12.5 all in use at the bottom, then a jump to 22 with nothing between. On macOS, weight does more of the ranking than on iOS (Headline is Body's size in Bold), so list weights too.

**3. Margin consistency.** Everything in a popover or window sits at one side margin unless it has a reason. Apple publishes no number ("system-defined margins"); the repo's own spacing tokens, if it has them, are the standard. Measure each element's left edge and name any element that quietly breaks the grid the rest of the screen keeps.

**4. Does the hero read as the hero?** Compare the most important element's size and surrounding space against everything else. If the number the screen exists to show is set in Body while a section header is Title 2, the ranking is upside down. Decide it deliberately rather than inheriting it.

**5. Alignment and reading order.** Apple: "Align components; alignment communicates organization." Check every left edge lines up, that optical centres agree with mathematical ones, and that the top-to-bottom order matches the ranking from step 5. A control that appears before the content it acts on is out of order. macOS: critical controls do not belong at a window's bottom edge (Layout).

**Report the numbers.** A layout finding without a measurement is an opinion, and the ask is design work, not opinions dressed as rules.

## Mode 2: Design something new

The prompt shape: "add a settings screen", "design the empty state", "design the delete-account flow."

Apple gets consulted before the first line of code, because component choice is the decision everything else hangs off.

1. **Repository guidance** (step 0).
2. **Classify what is being designed**: a full flow, a single screen, a single component, or a system surface (the status item, a notification, a widget, an App Shortcut).
   - A flow loads the relevant Patterns pages first: Onboarding, Settings, Entering data, Managing accounts, Feedback, Modality.
   - A screen or component goes to `references/component-chooser.md`.
   - A system surface goes to its page in `references/components-presentation.md` plus its spec table in `references/specifications.md`.
3. **Choose components with the chooser**, and record Apple's cited reason for each choice. "Sheet, because this is a self-contained task that people complete and dismiss" is a defensible spec line; "sheet, felt right" is not. In a menu bar app, remember the popover already is the transient surface: a sheet on it, a second window, or a panel each need their reason.
4. **Start from the starting-values card** (below). Deviations from a starting value get a written reason.
5. **Inventory the states before the layout.** Every screen ships five: default, empty, loading, error, offline. Apple's Loading and Feedback pages govern the last three. Empty states are the most commonly omitted screen in new designs; the inventory makes the omission impossible.
6. **Write the design spec**: screens and hierarchy, chosen components with citations, type roles from the macOS text styles, copy (through the repo's copy rules and Apple's Writing page), keyboard shortcuts, both appearance modes and Increase Contrast, and what will be verified on the running app after implementation. The spec is the deliverable. Implementation starts after the owner's taste call.

## Mode 3: Answer a design question

The prompt shape: "should this be a sheet or a separate window?", "is a 22pt button OK here?", "does Apple allow us to prompt for a rating here?"

1. **Route** with the question-shape index:
   - "How big / how far / how many / what size" → `references/specifications.md`
   - "X or Y" → `references/component-chooser.md`
   - "Is it OK to / can we / does Apple allow" → the relevant page's Best practices in its reference file
   - "How does it behave on Mac / iPad / watch" → that page's Platform considerations
   - "What is this called" → the page headings themselves; Apple's terms are preserved (scroll edge effect, prominent style, push button, lockup)
2. **Quote Apple's exact sentence**, naming the HIG page it came from. The authority is the point; a paraphrase throws it away.
3. **Check the repository's guidance.** The repo may already deviate on purpose. Say so if it does.
4. **Apply to the specific case and recommend.** An answer that stops at the quote is half an answer.
5. **If Apple is silent, say so.** "The HIG does not address this; here is my recommendation and why" beats an invented rule wearing Apple's name.

Example, done right: "Is an 18pt icon button OK in the popover header?" → Specifications, control sizes: macOS default control size 28x28 pt, minimum 20x20 pt. An 18pt hit region fails a `[HARD]` floor. The glyph can stay 18pt if the hit region is padded to at least 20 (better 28) with `.frame(minWidth:minHeight:)` and `.contentShape(Rectangle())`.

## Mode 4: Review a UI diff

For wrap-up's independent reviewers, or a direct "check this PR against the HIG." Written to be handed to a reviewer as a self-contained lens; the reviewer needs this file, the references it names, and the diff.

- **Scope is added lines only.** Pre-existing violations are out of scope. Run each sweep pattern as:
  ```bash
  git diff origin/main... -- '<app source dir>/*' | grep '^+' | grep -c '<pattern>'
  ```
  `<app source dir>` is the directory holding the app's Swift sources (for example `UpOnly`, `mac/Saves`, or the menu bar app's directory). A nonzero count means the diff introduces new instances; read the hits to confirm before reporting (a count of false positives is still wrong).
- **Recorded departures still apply.** A diff that follows a departure recorded in the repo's guidance is not a finding.
- **Severity** maps through the tag table above onto the repo's P0 to P3 ladder.
- **Finding format** is the repo's review table plus one extra column naming the HIG page:

  | # | Line | Code | Issue | HIG page | Solution |

- Report one comment per unique issue; if the same issue repeats across files, one finding with a note. High-signal only: `[PREFER]`-level observations are nitpicks unless trivially fixable.

## Mode 5: Legibility and layout robustness pass

The prompt shape: "is this readable in light mode", "check this with Increase Contrast", "does this hold up with long names".

This mode is about whether the screen still LOOKS right under conditions the user controls. Contrast and control sizes are in scope, because unreadable text looks broken and a button you miss feels cheap. VoiceOver labels, Full Keyboard Access, the hearing and cognitive sections, and localization or right-to-left checks are out of scope unless asked for; `references/foundations.md` still carries Apple's full text if a specific question needs it.

**macOS and text size.** Per the references, macOS text styles are fixed sizes and "macOS has no Dynamic Type" (`references/foundations.md` → Typography; `references/specifications.md` → macOS built-in text styles). So the iOS "check at AX5" pass does not apply. What does apply on macOS: custom text sits at or above the platform minimum of 10pt (default 13pt, `references/specifications.md` → Text sizes for custom type), text survives the longest real string at the popover's fixed width, and resizable windows hold up at their minimum size.

**Route:** Typography + Color (contrast) + Dark Mode (Increase Contrast, Reduce Transparency) + Materials (text over vibrancy and materials) + Layout + Buttons (control sizes) from the references.

**Static sweep:**

```bash
grep -rn '\.font(\.system(size:' <path>          # hardcoded sizes: check each against the 10pt floor and the text styles
grep -rn 'lineLimit(1)' <path>                    # truncation with long strings; verify each
grep -rn 'minimumScaleFactor' <path>              # text shrunk below its style's size
grep -rn 'Color.primary\|Color.white' <path>      # adaptive or fixed text over unknown media or materials
```

**Contrast:** for suspect text/background pairs, compute the WCAG ratio from the hex values in code (formula in `references/specifications.md`). Apple's floors, quoted exactly from Accessibility's table: text up to 17pt needs **4.5:1**; text 18pt and larger needs **3:1**; bold text needs **3:1** at any size. On macOS nearly all text is under 18pt, so 4.5:1 is the working floor. Two traps:
- **Dimmed text over a material.** Popovers and menu bar windows sit on materials that let the desktop show through; the material changes the backdrop and eats contrast a solid background would keep. Compute against the worst realistic backdrop, and check Reduce Transparency.
- **A background layer fixed to the view rather than to the content.** A decorative gradient outside the `ScrollView` sits under everything that scrolls past it, so a ratio computed against the flat background colour is not the ratio anyone sees. Compute against the blended value.

**Running-app half** (where the repository allows it):
- Light and dark, both. A colour that reads on one can vanish on the other.
- Increase Contrast on, in both appearances. Apple: "ensure it at least provides a higher contrast color scheme when the system setting Increase Contrast is turned on."
- Reduce Transparency on, for every surface with a material behind text.
- The longest real data you can seed: long names, large numbers, many rows.
- **Restore every setting before you finish.** A setting left on makes the next task's captures look like a regression.

## Mode 6: System surfaces

The status item, notifications, widgets, App Shortcuts, Controls. For a menu bar app the status item is the most important system surface: it is the app's only permanent presence.

- **The status item.** Judge it in both menu bar appearances and next to the system's own items: a template image so the system tints it, legible at menu bar size, any count or badge readable at a glance, and a right-click menu (if the app has one) that follows Menus. As noted under the reference shelf, re-extract The menu bar page for Apple's Menu bar extras guidance before citing it.
- Each other surface has a full page in `references/components-presentation.md` under System experiences, and its numbers in `references/specifications.md`.
- Notification copy goes through Managing notifications (patterns) + Writing (foundations) + the repo's copy rules. The system truncates; never pre-truncate. Apple: avoid sending an unnecessary notification for routine background completion.
- Widgets are not mini-apps: one idea, glanceable, clickable into the app. The Widgets page is the second-largest in the HIG and the reference keeps its rules at full depth.

---

## Surface router

Classify the surface, load the listed sections. Foundations' core six (Layout, Typography, Color, Materials, Motion, Accessibility) bind every visible surface and are assumed on top of each row.

| Surface | Load |
| --- | --- |
| Menu bar popover / window-style MenuBarExtra | Popovers, Windows, Scroll views, The menu bar (re-extract for menu bar extras), Menus; Modality |
| Status item and its right-click menu | The menu bar (re-extract), Menus, Context menus, Icons, SF Symbols |
| Scrolling list / feed | Lists and tables, Collections, Scroll views, Labels; Loading, Feedback |
| Form / input | Text fields, Pickers, Toggles, Combo boxes; Entering data; Keyboards |
| Settings window or pane | Settings (pattern), Windows, Toggles, Pop-up buttons, Tab views |
| Modal task (create, edit, confirm) | Modality, Sheets, Alerts vs Action sheets (chooser), Buttons, Panels |
| Search | Search fields, Searching |
| Onboarding / first run / auth | Onboarding, Launching, Managing accounts, Sign in with Apple |
| Purchase | In-app purchase, Buttons, Writing |
| Empty / error / progress states | Feedback, Loading, Progress indicators, Writing |
| Chart / stats / numbers screen | Charting data, Charts, Gauges |
| Notification | Notifications, Managing notifications, Writing |
| Widget | Widgets, its specs |
| App Shortcut / Siri | App Shortcuts, Siri |
| Keyboard-driven UI | Keyboards, Focus and selection, The menu bar (shortcuts), Offering help (tooltips) |
| Legibility / contrast | the Mode 5 route |
| App icon | App icons, its specs |

## The mechanical sweep

Run scoped to the surface directory for an audit, the whole app source directory for a full pass, added-lines-only for a diff review (Mode 4). No baseline counts are recorded here; on a first full pass, record the counts in your report so the next pass has a baseline. A row that returns zero on a surface you know violates it is a broken check, not a clean result. A count is a set of candidates: read the hits before reporting, some are legitimate (and some match the repo's own design tokens, which is compliance with the house system, not a finding).

Commands live in a code block rather than a table because some of them contain a regex `|`, which a markdown table cell cannot hold. Escaping it as `\|` produces a literal pipe under `grep -E` and silently matches nothing, which is exactly the failure this block exists to avoid.

```bash
P=<path>          # the surface's directory, or the app's source directory for a full pass

# Typography [PREFER] built-in text styles; a hardcoded size opts out of the system ramp
grep -rn '\.font(\.system(size:' "$P"

# Buttons [ALWAYS] include a press state
grep -rn 'buttonStyle(.plain)' "$P"

# Specifications [HARD] macOS minimum control size 20x20pt (interactive elements only; read every hit)
grep -rEn '\.frame\((width|height): ([0-9]|1[0-9])(\.[0-9]+)?[,)]' "$P"
# ...and below the 28x28pt default: weigh each, a reason is needed
grep -rEn '\.frame\((width|height): 2[0-7](\.[0-9]+)?[,)]' "$P"

# Motion [ALWAYS] make motion optional: compare the two counts
grep -rn 'repeatForever' "$P"
grep -rn 'accessibilityReduceMotion' "$P"

# Materials / Dark Mode [ALWAYS] test with Reduce Transparency: compare the two counts
grep -rEn '(ultraThin|thin|regular|thick|ultraThick|bar)Material|NSVisualEffectView' "$P"
grep -rn 'accessibilityReduceTransparency' "$P"

# Dark Mode [ALWAYS] avoid an app-specific appearance setting
grep -rn 'preferredColorScheme' "$P"

# Color [PREFER] avoid hard-coding; needs light/dark/increased-contrast variants
grep -rEn 'Color\(red:|Color\(hex|NSColor\(red:|NSColor\(calibratedRed:' "$P"

# Offering help: icon-only buttons want a tooltip; compare against the icon buttons you find
grep -rn '\.help(' "$P"

# The menu bar / Keyboards: commands want standard shortcuts; list what exists
grep -rn 'keyboardShortcut' "$P"

# Typography/Layout: text must survive long strings at a fixed popover width
grep -rn 'lineLimit(1)' "$P"
grep -rn 'minimumScaleFactor' "$P"

# Layout [NEVER] full-width buttons; check hits that sit on a Button
grep -rn 'maxWidth: .infinity' "$P"

# Writing: only if the repo bans dashes in user-facing copy (en, em and horizontal bar dashes inside string literals)
grep -rnP '"[^"\n]*[\x{2013}\x{2014}\x{2015}][^"\n]*"' "$P"
```

Read-checks that no grep can do (do them in the judgment pass): material stacked on material, hierarchy carried by more than color, one scroll edge effect per view, a pinned header or footer separated from scrolling content by an edge effect or material rather than only a color fade, at most three label opacity tiers, one or two prominent buttons per view, a popover arrow pointing at the status item and not covering it, one popover at a time, enter/exit along the same path, same-orientation nested scroll views, alert used for routine information, primary role on a destructive action, a status item that is a template image, empty state existence.

## Starting values (design-new mode)

- Type: build the hierarchy from the macOS text styles (Large Title 26, Title 1 22, Title 2 17, Title 3 15, Headline 13 Bold, Body 13, Callout 12, Subheadline 11, Footnote 10, Caption 1 10, Caption 2 10 Medium). Five or six styles is a full hierarchy. Regular through Bold weights; avoid lighter. Custom sizes never below 10pt.
- Margins: Apple publishes no number ("system-defined margins"), so do not cite the HIG for one. Use the repo's spacing tokens where they exist, one side margin throughout, and system container padding otherwise.
- Controls: macOS default control size 28x28pt, minimum 20x20pt hit region on everything interactive; Apple's Buttons page asks for 44x44pt, so give custom and icon-only buttons more than the floor where space allows.
- Buttons: one or two prominent per view; style, not size, distinguishes the preferred choice; verb labels; an ellipsis when a button opens another window or view.
- Icons: SF Symbols, sized with their text style, unless the repo records a departure.
- Color: system or semantic colors, or asset-catalog colors with light, dark, and increased-contrast variants; never meaning by color alone; the accent color only for what is interactive.
- Materials: popovers and menu bar windows already sit on a system material; do not stack another behind text. Check Reduce Transparency.
- Motion: purposeful, brief, interruptible, and gated on Reduce Motion when it loops.
- Keyboard: every command reachable by keyboard, standard shortcuts for standard actions, Escape closes transient UI.
- Components: system components first; a custom control names the requirement that justified it (Apple's Familiarity principle).
- States: default, empty, loading, error, offline, designed before layout polish.

## Finding format

Every finding, in every mode:

```
[P1 | HARD | Specifications] Sub-20pt hit region
<app source dir>/Features/Holdings/HoldingsHeader.swift:214
Now: refresh button frame is 16x16 with no contentShape padding.
Apple: macOS minimum control size 20x20 pt; default 28x28 pt (Specifications, from Accessibility and Buttons).
Fix: keep the 16pt glyph, pad the hit region with .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()).
```

Tag, severity, HIG page, file:line, current state, Apple's sentence or number, concrete fix. A finding missing the file:line or the citation is not done.

## Anti-patterns (each of these is a failed audit, not a style choice)

- **Compliance instead of hierarchy.** Every HIG rule can pass on a screen where the most important thing is not the biggest thing. On a screen that exists to show one number or one offer, name the ONE element that must win the screen before touching anything else, then make it win by SIZE, not by colour or a badge. Repeated rejections on one axis ("make X more prominent") are a missing rule, not taste; the fix is a real size ratio between the hero and the rest.
- **Judging your own output from a tree instead of an image.** Reading the accessibility tree tells you what exists, never whether it looks good, and it reads as verification in a transcript. Every design claim needs the screenshot read back and looked at. The tree is for finding elements to act on; the image is the only evidence about appearance.
- Delivering a violations list when the ask was a redesign. Every rule can pass on a screen with no hierarchy. Lead with what the screen should be.
- A layout claim with no measurement. "Feels cramped" is an opinion; "four blocks all 24pt apart, so nothing is grouped" is a fix.
- Proposing nothing to remove. Deletion and deferral are the most Apple moves available; if the honest answer is that nothing should go, say that explicitly rather than skipping the question.
- Advice with no file:line. "Consider using text styles" is not a finding.
- A rule cited without the code checked. The count comes first.
- Static captures standing in for driving the screen. The capture matrix in Mode 1 is the bar; a default screenshot is one cell of it.
- Reporting a finding about a state you never put the screen into. Anything about scrolling needs a mid-scroll capture; anything about an empty, maximal or error state needs that state seeded. If you could not reach it, say so instead of inferring it.
- Calling a screen audited when a component visible in the frame was never opened. Grepping the feature directory is not an inventory; the screen is.
- Applying iOS numbers to a Mac app: 17pt body text, Dynamic Type AX sizes, or 44pt as the floor for standard Mac controls. Use the macOS rows of the specification tables (and see the note under control sizes there).
- A finding that is actually a departure recorded in the repo's guidance. Read step 0.
- Running or capturing the app somewhere the repository's guidance does not allow. Ask first.
- Skipping the empty/error/offline states because the default state looks finished.
- Starting to edit code in audit mode. The plan is the deliverable.

## Worked example (synthetic screen, so it cannot go stale)

Prompt: "improve the reminders popover based on Apple's guidelines." The screen is a menu bar popover with a scrolling list, an add button in the header and an edit sheet.

1. Repository guidance read; no departures touch this surface.
2. Captures in light, dark and Increase Contrast, top and mid-scroll, empty and a 60-row list; the row titles truncate at the popover width (`lineLimit(1)`) and secondary text over the popover material measures 3.1:1 in light.
3. Code read: one 480-line view file.
4. Router: popover row + list row + modal row.
5. Sweep on the directory: 31 hardcoded fonts (four of them 9pt), 4 `lineLimit(1)`, 2 `buttonStyle(.plain)`, add button frame 16x16, 0 `accessibilityReduceMotion` against 1 `repeatForever` pulse.
6. Findings, ordered:
   - [P0 | HARD | Accessibility] secondary text 3.1:1 over the material in light appearance `file:12` ... fix: use the secondary label color on a non-vibrant background or raise contrast.
   - [P1 | HARD | Specifications] add button 16x16 hit region `file:301` ... pad to 28.
   - [P1 | HARD | Specifications] 9pt text below the macOS 10pt minimum `file:140` ... use Footnote or Caption.
   - [P1 | ALWAYS | Motion] pulse animation ignores Reduce Motion `file:88` ... gate it.
   - [P2 | ALWAYS | Buttons] plain buttonStyle rows have no press state `file:45` ... add a pressed style.
   - [P3 | PREFER | Typography] 27 other hardcoded sizes bypass the text styles `file:many` ... migrate opportunistically, top of screen first.
7. Plan delivered; no edits made.

## Provenance and refresh

Extracted from Apple's HIG via its DocC JSON API (no browser needed):

```
https://developer.apple.com/tutorials/data/index/design--human-interface-guidelines      # index of every page
https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<slug>.json # one page
```

All 172 pages were read for this distillation. 137 are distilled here (Getting started 8, Foundations 18, Patterns 25, Components 64, Inputs 13, Technologies 9); 20 technologies are deliberately dismissed with reasons in `references/technologies.md`; the remaining 15 are section and group index pages, folded into the reference shelf and the surface router. 137 + 20 + 15 = 172.

When re-fetching, diff the set you got against the index in BOTH directions before trusting it. The first fetch for this distillation silently dropped one page and 171 looked plausible; `comm -13` against the index list is what caught it. Apple ships HIG updates continuously and each page carries a change log; when guidance here conflicts with the live site, the live site wins, and the fix is to re-extract the page, not to patch from memory.
