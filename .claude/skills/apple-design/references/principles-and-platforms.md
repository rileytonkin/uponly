# Getting started: Design principles + Designing for each platform

Source pages: Design principles, Designing for iOS / iPadOS / macOS / tvOS / visionOS / watchOS / games. Reintroduced by Apple June 2026. These are the names to reason with; use them to weigh competing priorities, not as a checklist.

## Design principles

Apple: "There's no one right way to apply these principles. Instead, they're tools to help you weigh competing priorities and make key decisions on the path to a great design."

### Purpose
- **Create value.** "At every stage of development, ask what your product is for and whether the design serves that purpose."
- **Keep focused.** Prioritize the most important features by how people want to use the product; make those truly great.
- **Find new ways to solve the problem.** Investigate existing solutions and avoid re-creating them; define what sets the product apart.

### Agency
- **Stay out of the way.** "The best designs are unobtrusive and present when people need them." Get people directly to the task or content.
- **Give people the freedom to explore.** No locked flows or modes. "When a guided flow is necessary, make it easy to skip or escape."
- **Help people recover from mistakes.** Build forgiveness in; reversal must not cost time or work. This is what makes an interface inviting to explore.

### Responsibility
- **Be fully transparent** about what the product does and why. Clear rationale when asking permission; clear about what data is collected and how it is used.
- **Keep people's information safe.** Collect only what the product needs; anticipate misuse and put protections in place.

### Familiarity
- **Use concepts that people know**, from the real world and from other software.
- **Keep visuals and interactions consistent.** Once a behavior or appearance is established for an element, apply it throughout. Consistency is what lets people predict what happens next.
- **Provide clear feedback.** Show when controls are available, indicate when content changes, use system patterns for alerts and choices.

### Flexibility
- **Design for everyone.** "Treat accessibility as a priority from the start."
- **Preserve a person's context** across platforms and configurations: content and controls in consistent, predictable positions; natural animations easing transitions.
- **Consider a variety of input methods**: voice, touch, keyboard, and more.
- **Approach every platform with intention.** "Give each platform you support the same level of care."

### Simplicity
- **Include just what's necessary.** "Simplicity isn't minimalism." Keep the important things close; let the others fall away.
- **Be concise.** "Choose exactly the words you need to convey a concept or label a control."
- **Establish hierarchy.** Recognizable controls, consistent structure, so people know where they are and what comes next.

### Craft
- **Quality sets the tone.** "Every element of your design shows people how much you care." Deliberate decisions; stunning visuals, smooth animations, precise wording, thoughtful audio.
- **Experiment and iterate.** Prototype early; discard what does not work; test in real-world settings.
- **Maintain your craft.** "Shipping isn't the finish line." Keep current with platform capabilities; design is an ongoing commitment.

### Delight
- **Identify the emotion you want to inspire** and let it shape the design.
- **Create defining moments.** Every interaction, including an error message, can carry the product's character.
- **Don't mistake delight for decoration.** "Don't let pursuit of delight for its own sake get in the way of your product's core purpose."
- **Consider the whole.** Delight is the sum of freedom to act, safety to explore, familiar metaphors, and intentional care; it is not a feature.

## Designing for iOS

Device reality that drives the rules: medium-size high-resolution display, held in one or both hands, viewing distance a foot or two, sessions from a minute to over an hour, multiple apps open with frequent switching.

Best practices, Apple's emphasis:
- [PREFER] **Limit onscreen controls** so people concentrate on primary tasks and content; make secondary details and actions "discoverable with minimal interaction."
- [ALWAYS] **Adapt seamlessly to appearance changes**: device orientation, Dark Mode, and Dynamic Type. These are user choices, not edge cases.
- [PREFER] **Design for the hand.** "It tends to be easier and more comfortable for people to reach a control when it's located in the middle or bottom area of the display." Support swipe-to-go-back and swipe actions in list rows.
- [PREFER] **Use platform capabilities instead of asking for data entry** (with permission): payments, biometric auth, location.
- System features an iOS app is expected to meet people in: Widgets, Home Screen quick actions, Spotlight, Shortcuts, Activity views.

## Designing for iPadOS

Large display, held or on a stand, ~3 feet viewing distance, multiple input modes often combined (touch, keyboard, trackpad, Apple Pencil), heavy multitasking and drag-and-drop between apps.

- [PREFER] Elevate content with the large display; **minimize modal interfaces and full-screen transitions**; controls easy to reach but not in the way.
- [PREFER] Size and density follow viewing distance and input mode.
- [ALWAYS] Adapt to orientation, multitasking modes (resizable windows), Dark Mode, Dynamic Type; transition well to running in macOS.
- An iPhone app running on iPad is judged by these expectations, so a layout hardcoded to phone width reads as neglect.

## Designing for macOS

Large display(s), stationary, precision inputs, long deep-focus sessions, many apps at once.

- [PREFER] More content in fewer nested levels; less modality; comfortable information density.
- [ALWAYS] Let people resize, hide, show, and move windows; support full-screen mode.
- [ALWAYS] Menu bar carries "all the commands they need."
- [PREFER] Support pixel-precision input, keyboard shortcuts and keyboard-only work styles, and personalization (toolbars, window layouts, fonts).

## Designing for tvOS

Very large display, 8+ feet away, remote or controller input, hours-long immersion.

- [ALWAYS] Embrace the focus system; the highlighted item is the interaction model.
- [PREFER] Edge-to-edge artwork, fluid gestures on the Siri Remote, cinematic feel that stays "clear, legible, and captivating from across the room."
- [PREFER] Make sign-in easy and infrequent; switch profiles automatically for multiuser.

## Designing for visionOS

Infinite 3D space; apps launch in the Shared Space (side by side) and can move to a Full Space; passthrough keeps surroundings visible; eyes-plus-hands is the default interaction; comfort is paramount because people rely entirely on the cameras for everything they see.

- [PREFER] "For each key moment in your app, find the minimum level of immersion that suits it best — don't assume that every moment needs to be fully immersive."
- [PREFER] Use windows for contained, UI-centric experiences.
- [ALWAYS] Prioritize comfort: content within the field of view, positioned relative to the head; no overwhelming, jarring, or too-fast motion without a stationary frame of reference; interactions that work with hands resting in the lap.
- Safety note from Apple: not for use while operating vehicles or near hazards; fit for ages 13 and up.

## Designing for watchOS

Small display on the wrist, glances of under a minute, Digital Crown for vertical navigation, Always On display. "People frequently use a watchOS app's related experiences — like complications, notifications, and Siri interactions — more than they use the app itself."

- [PREFER] Quick, glanceable, single-screen interactions; a targeted action in a gesture or two.
- [PREFER] Minimize navigation depth; the Digital Crown scrolls and switches.
- [PREFER] Complications on the watch face and notifications carry more of the experience than the app; design them first-class.
- [PREFER] Anticipate needs with on-device data; make content relevant in the moment.

## Designing for games (the cross-platform distillation)

Useful beyond games; these are Apple's cross-platform floors restated:

- [PREFER] Playable within a 30-minute download; load more in the background; great defaults over settings screens; teach through play, not gated tutorials; defer permission and rating requests to the moment that explains them.
- [HARD] The text-size and control-size floors repeat here per platform (see specifications.md).
- [PREFER] Dynamic layouts over fixed; handle aspect ratios and device cutouts via safe areas; support each platform's default interaction method plus controllers.
- [ALWAYS] Perceivability: never color alone; subtitles on cutscenes; let players personalize type size, control mapping, motion intensity, sound balance.
- [ALWAYS] Avoid stereotypes in stories and characters; support the spectrum of self-identity in avatars and names.
