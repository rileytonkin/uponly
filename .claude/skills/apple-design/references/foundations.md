# Foundations (18 HIG pages)

One section per HIG page. Tags per the skill's strength model; quoted sentences are Apple's. Numbers live in specifications.md; a section here repeats a number only when the rule is unreadable without it.

## Accessibility

Apple's frame: an accessible interface is **intuitive** (familiar, consistent interactions), **perceivable** (no single method carries information; sight, hearing, speech, or touch all work), **adaptable** (supports system accessibility features and personalization). Audit with Accessibility Inspector; App Store listings carry Accessibility Nutrition Labels.

Vision:
- [ALWAYS] Support larger text sizes; "give people the option to enlarge text by at least 200 percent (or 140 percent in watchOS apps)". Dynamic Type is the sanctioned route.
- [HARD] Custom type follows the per-platform default/minimum sizes (specifications.md). Thin custom weights need larger sizes still.
- [HARD] Contrast floors: up to 17 pt 4.5:1; 18 pt+ 3:1; bold 3:1. Provide a higher-contrast scheme under Increase Contrast if the default misses; check both appearances.
- [PREFER] System-defined colors; they carry accessible variants automatically.
- [ALWAYS] "Convey information with more than color alone." Shapes, icons, or labels alongside color; red-green and blue-orange pairs are the classic failures.
- [ALWAYS] Describe interface and content for VoiceOver (see technologies.md → VoiceOver).

Hearing:
- [ALWAYS] Dialogue and crucial information never through audio alone. The four text equivalents, each for its context: captions (synced text for AV), subtitles (dialogue in preferred language), audio descriptions (narrated visual info), transcripts (complete text for long-form).
- [PREFER] Pair audio cues with haptics; augment audio cues with visual cues pointing at off-screen action.

Mobility:
- [ALWAYS] "Offer alternatives to gestures." Core functionality reachable by more than one physical interaction; a swipe-to-dismiss also gets a button.
- [HARD] Control sizes per the platform table (specifications.md); ~12 pt padding around bezeled elements, ~24 pt around bezel-less ones.
- [PREFER] Support Voice Control, Full Keyboard Access, Switch Control; label elements so voice targeting works. Siri/Shortcuts integration lets tasks run by voice alone.
- [PREFER] "Use the simplest gesture possible — avoid custom multifinger and multihand gestures" for frequent interactions.

Cognitive:
- [PREFER] System gestures over custom ones people must learn and retain.
- [ALWAYS] "Minimize use of time-boxed interface elements." Auto-dismissing views punish people who process slowly or use assistive tech; prefer explicit dismissal.
- [ALWAYS] No autoplaying audio/video without discoverable stop controls; respect Dim Flashing Lights for video.
- [ALWAYS] Under Reduce Motion, reduce automatic and repetitive animations: tighten springs to remove bounce, track gestures directly, avoid z-axis depth animation, replace positional transitions with fades, avoid animating into and out of blurs.
- [PREFER] For Assistive Access: strip to core functionality, one interaction per screen, confirm twice on hard-to-recover actions.

## App icons

- The icon is layered artwork now: background layer plus foreground layers, composed in Icon Composer, with the system applying Liquid Glass effects (specular highlights, refraction, translucency) that adapt per platform and size.
- [PREFER] "Embrace simplicity." One core idea, minimal shapes, simple background (solid or gradient). Fine detail dies at small sizes and fights the system's own effects.
- [ALWAYS] Visually consistent icon across every platform the app supports; people must not mistake it for a different app per device.
- [PREFER] Filled, overlapping shapes with varied layer opacity for depth; clearly defined (not feathered) edges so system highlights land well; vector layers (SVG/PDF).
- [ALWAYS] Text only when essential to the brand; never words like "New" or instructions; text does not localize inside an icon.
- [ALWAYS] Prefer illustration to photography; never replicate app UI or screenshots in the icon; never Apple hardware (copyrighted).
- [ALWAYS] "Let the system handle blurring and other visual effects": no baked-in shadows, bevels, glows; they conflict with the dynamic system effects.
- Appearances: default, dark, clear (light/dark), tinted (light/dark). [ALWAYS] Keep core features consistent across appearances; base the dark icon on the light one. The system generates variants you skip, so an unconsidered dark icon is what users may actually see.
- Alternate icons are allowed (chosen in-app); each needs its own full variant set and app review.
- Shapes and canvas sizes per platform: specifications.md.

## Branding

- [ALWAYS] "Ensure branding always defers to content." Screen space spent on a brand asset is space taken from what people came for.
- [ALWAYS] "Resist the temptation to display your logo throughout your app." People know which app they are in.
- [ALWAYS] Never use the launch screen as a branding moment; it disappears too fast to convey anything. A welcome or onboarding screen is the sanctioned place.
- [PREFER] Express brand through an accent color and voice/tone rather than chrome. A custom font is acceptable for headlines with system fonts for body, because system fonts are tuned for small-size legibility.
- [PREFER] Even a stylized interface keeps standard patterns: components in expected places, standard symbols for common actions.
- [HARD] Apple trademarks never appear in app names or images.

## Color

- [ALWAYS] "Avoid using the same color to mean different things." If the brand color signals interactivity, that color on non-interactive text is a lie.
- [ALWAYS] Every color works in light, dark, and Increased Contrast. Custom colors ship light + dark + increased-contrast variants in the asset catalog, "even if your app ships in a single appearance mode."
- [ALWAYS] "Avoid relying solely on color to differentiate between objects, indicate interactivity, or communicate essential information."
- [ALWAYS] "Avoid hard-coding system color values": the actual values fluctuate release to release; use the semantic APIs.
- [ALWAYS] "Avoid redefining the semantic meanings of dynamic system colors." Separator color is not a text color; secondaryLabel is not a background.
- [PREFER] Test under real conditions: sunlight mutes color, dark rooms saturate it, True Tone shifts the white point, translucency shifts anything behind it.
- [PREFER] Consider cultural readings (red is danger in some cultures, luck in others).
- iOS hierarchy machinery: two background sets (system and grouped), each with primary/secondary/tertiary; foreground dynamic colors label, secondaryLabel, tertiaryLabel, quaternaryLabel, placeholderText, separator, opaqueSeparator, link. Use grouped backgrounds for grouped-table screens.
- Liquid Glass color: glass has no inherent color; [PREFER] apply color sparingly, to the background of the one primary action (how the system styles prominent buttons), not to many controls and not to symbols/text when emphasis is the goal. On colorful content, prefer monochromatic toolbar/tab-bar labels.
- Wide color: use Display P3 (16 bpc, PNG) where richness matters; provide sRGB fallbacks when two P3 colors are too close to distinguish on sRGB displays.

## Dark Mode

- [ALWAYS] "Avoid offering an app-specific appearance setting." People set appearance once, systemwide; an app-level toggle makes the app look broken when it disagrees. (The HIG's own "in rare cases" exception: immersive contexts may be permanently dark.)
- [ALWAYS] Look good in both modes; people run Auto, which flips mid-session.
- [ALWAYS] Test dark appearance with Increase Contrast and Reduce Transparency, separately and together.
- Dark Mode is not inversion: some colors flip, some do not. [PREFER] Semantic colors and Color Set assets with both variants; never hardcoded values.
- [HARD] Minimum 4.5:1 in dark mode too; [PREFER] aim 7:1 for custom small text.
- [PREFER] Soften pure-white content backgrounds in dark contexts (a white image background glows).
- iOS depth machinery: base and elevated background color sets; elevated is brighter and marks foreground layers (sheets, popovers). [PREFER] System backgrounds so this depth signaling works; custom backgrounds erase it.
- Text: use system label colors and system text views; they handle vibrancy automatically.

## Icons (interface icons / glyphs)

- [PREFER] "Create a recognizable, highly simplified design" on a familiar visual metaphor.
- [ALWAYS] Consistency across the whole icon set: same size, detail level, stroke weight, perspective. Mixed sets read as carelessness.
- [PREFER] Match icon weight to adjacent text weight; add padding for optical (not geometric) centering of asymmetric glyphs.
- No selected-state variants needed for standard components; the system handles selection appearance.
- [ALWAYS] Vector formats (PDF/SVG) for custom icons; PNG needs every resolution by hand.
- [ALWAYS] "Provide alternative text labels for custom interface icons": they are invisible but VoiceOver depends on them.
- [PREFER] Gender-neutral figures; no Apple hardware replicas; text inside an icon only when the text is the concept (and then localized, with an RTL flip).
- The page's Standard-icons table maps common actions to conventional glyph concepts (share = box with up arrow, trash = delete, plus = add, ellipsis = more, magnifying glass = search...).

## Images

- Point vs pixel: points are the abstract unit; scale factors @1x/@2x/@3x map them to pixels. [HARD] iOS needs @2x and @3x bitmap assets; iPadOS/watchOS @2x; macOS/tvOS @1x and @2x.
- Formats: de-interlaced PNG for raster UI art; 8-bit palette when 24-bit is unneeded; JPEG/HEIC for photos; PDF/SVG for flat scalable art.
- [ALWAYS] Embed a color profile in every image.
- [ALWAYS] Test on real devices; design-time art can ship pixelated, stretched, or compressed.
- [PREFER] Design at the lowest resolution with control points on whole values, then scale up.
- tvOS: focusable images want layered images (2 to 5 layers) for the parallax effect; background layer opaque; keep essential content in a safe zone against focus cropping; text in the foreground layer.

## Immersive experiences (visionOS)

Retained for completeness; binds only an app that ships on visionOS.
- Immersion styles: mixed (content with passthrough), progressive (a portal that widens), full. [PREFER] Launch in the Shared Space or mixed; "find the minimum level of immersion" per moment.
- [ALWAYS] Let people choose when to enter or exit immersion; smooth, predictable transitions; a clear exit.
- [ALWAYS] Comfort: content in the field of view, no head-anchored content, minimal peripheral motion, a stationary frame of reference, no forced movement.
- Custom environments: ground plane mesh so people do not float; subtle looping-free Spatial Audio; gentle animation only.
- Virtual hands match the person's real hand positions; oversized hands feel clumsy and occlude content.

## Inclusion

- Inclusive design is proactive, not the absence of offense: "an inoffensive app or game isn't necessarily an inclusive one."
- [PREFER] Address people as "you/your"; never "the user". Reserve "we" for the company, and prefer avoiding it (see Writing).
- [ALWAYS] Plain language over specialized terms, colloquialisms, and humor; all three exclude and none translate. Some colloquialisms carry oppressive histories.
- [PREFER] Avoid unnecessary gender references in copy, avatars, glyphs; plural constructions dodge gendered pronouns and survive localization. If gender must be collected, offer nonbinary, self-identify, and decline-to-state; consider letting people state pronouns.
- [PREFER] Depict a range of human characteristics; avoid stereotyped occupations, families, and affluence levels; prefer settings "familiar and relatable to most people".
- [PREFER] Security-question-style prompts must reference universal experiences, not culture-specific ones (college, cars, rainbows all exclude someone).
- Every disability is a spectrum, and everyone experiences temporary and situational disability; accessibility support is the floor of inclusion.

## Layout

- [PREFER] "Group related items" with negative space, background shapes, colors, materials, or separators, keeping content and controls clearly distinct.
- [ALWAYS] "Make essential information easy to find by giving it sufficient space... don't obscure it by crowding it with nonessential details."
- [ALWAYS] Extend content to the edges: backgrounds full-bleed, scrollable layouts continuing to the bottom and sides, because bars and sidebars float on top of content, not beside it. Background extension views fill behind the control layer when content is narrower.
- [ALWAYS] "Differentiate controls from content" via the material system; "instead of a background, use a scroll edge effect to provide a transition between content and the control area."
- [PREFER] Place items by importance along reading order (top to bottom, leading to trailing) and remember reading order flips in RTL.
- [PREFER] Align components; alignment communicates organization and makes scanning possible.
- [PREFER] Progressive disclosure: show partial content at an edge to signal more (the peeking-card pattern), or a disclosure control.
- [ALWAYS] Adapt to: screen sizes and resolutions, orientation, Dynamic Island and camera features, external displays and resizable windows, Dynamic Type changes, and locale (RTL, formats, text length). Respect safe areas, margins, and guides.
- [ALWAYS] "Be prepared for text-size changes." Preview at the largest and smallest layouts first.
- [PREFER] Scale artwork on aspect-ratio changes rather than stretching; never change the artwork's aspect ratio.
- iOS: [PREFER] support both orientations; [NEVER] full-width buttons ("buttons feel at home in iOS when they respect system-defined margins and are inset from the edges"; a rare full-width one must harmonize with hardware curvature and safe areas); [PREFER] keep the status bar unless full-screen media/games earn hiding it.
- iPadOS: windows resize freely; design full-size first and "defer switching to a compact view for as long as possible"; test at halves, thirds, quadrants; consider the convertible tab bar (tab bar that becomes a sidebar).
- macOS: [NEVER] critical controls at the window bottom (people push it off screen); avoid the camera-housing area.
- tvOS: same interface on every TV; the 60/80 pt safe zone; padding for focus expansion; grid column specs on the page.
- visionOS: center important content; keep content inside window bounds (system controls live just outside); ornaments for extra controls; 60 pt between button centers.
- watchOS: edge-to-edge content (the bezel is the padding); at most 3 glyph buttons or 2 text buttons in a row; autorotation for show-someone views.

## Materials

Two material systems, with a bright-line rule between them:
- **Liquid Glass** is the floating functional layer for controls and navigation (tab bars, sidebars, toolbars). [NEVER] "Don't use Liquid Glass in the content layer." Content-layer elements use standard materials. Exception: transient interactive elements in content (sliders, toggles) take on glass while being manipulated.
- [PREFER] "Use Liquid Glass effects sparingly" on custom controls; system components pick it up automatically, and glass everywhere distracts from content.
- Regular vs clear glass: regular blurs and adjusts luminosity for legibility (use for text-heavy elements: alerts, sidebars, popovers); clear is highly translucent for media backdrops, and over bright content wants a ~35% opacity dimming layer.
- **Standard materials** (iOS/iPadOS): ultra-thin, thin, regular, thick. Choose by semantic purpose, never by apparent color. Thicker = more opaque = better text contrast; thinner = more context showing through.
- [ALWAYS] Vibrant colors on top of materials for legibility; the vibrancy ladder is label / secondaryLabel / tertiaryLabel / quaternaryLabel (and fill / secondaryFill / tertiaryFill; one separator level). [NEVER] quaternary on thin or ultraThin: "the contrast is too low."
- visionOS windows use system glass; prefer translucency to opaque areas. watchOS: keep the default material backgrounds on modal sheets; they orient people.

## Motion

- [ALWAYS] "Add motion purposefully... Gratuitous or excessive animation can distract people and may make them feel disconnected or physically uncomfortable."
- [ALWAYS] "Make motion optional." Never the only channel for important information; supplement with haptics and audio. Under Reduce Motion, see the Accessibility list (tighter springs, fades over movement, no blur animation).
- [PREFER] Feedback motion follows the gesture and expectations: a view revealed by sliding down does not dismiss sideways.
- [PREFER] "Aim for brevity and precision." Brief, precise feedback beats prominent animation.
- [PREFER] "In apps, generally avoid adding motion to UI interactions that occur frequently." The system already animates standard elements; a custom flourish on every tap taxes attention.
- [ALWAYS] "Let people cancel motion." Never make someone wait out an animation, especially a repeated one.
- visionOS additions: no peripheral-edge motion; translucency/lower contrast on large moving objects; fades for relocation; never rotate the world; a stationary frame of reference; no sustained oscillation near 0.2 Hz.
- watchOS: layout/appearance animations carry non-removable built-in easing.

## Privacy

- [ALWAYS] "Request access only to data that you actually need", as specifically as possible, at the moment of interest, not at launch (unless the app cannot function without it).
- [ALWAYS] Purpose strings are complete, specific sentences: "The app records during the night to detect snoring sounds." Not passive-vague ("Microphone access is needed for a better experience") and not imperative ("Turn on microphone access").
- Pre-alert screens: [HARD] exactly one button, titled "Continue" or "Next" (never "Allow"), no way to bypass the system alert, no imitations of the alert, no incentives, no annotations pointing at the alert. These are App Review rejection causes, not style advice.
- [PREFER] Process on device where possible; adopt system protections (CloudKit encryption, keychain).
- [NEVER] "Never store passwords or other secure content in plain-text files."
- [PREFER] Passkeys over passwords; two-factor if passwords stay; biometrics for re-auth; no custom authentication schemes.
- The Location button pattern: one-time location permission at the moment of need, customizable within system-enforced legibility limits.

## Right to left

Binds any app that ships a right-to-left language.
- System components flip automatically; hand-rolled layout and manual `.offset(x:)` motion do not.
- [ALWAYS] One- and two-line text follows the interface direction; "align a paragraph based on its language, not on the current context" (3+ lines).
- [NEVER] Reverse digits within a number; phone and card numbers keep their order everywhere.
- [ALWAYS] Reverse the order of numerals showing progress or counting direction along a flipped control; never flip the numerals themselves.
- [ALWAYS] Flip: progress controls and their endpoint glyphs, back/next navigation, icons representing text or reading direction, icons showing forward/backward motion (the speaker's sound waves).
- [NEVER] Flip: controls pointing at real directions or screen areas, photographs and artwork, logos, universal signs (checkmark), clocks, right-handed tools.
- [PREFER] Arabic/Hebrew next to all-caps Latin often wants ~2 pt more size (no uppercase exists to balance).
- Badged/complex icons: judge each component; a slash keeps its direction, a badge that depicts UI flips with the UI.

## SF Symbols

- Four rendering modes: monochrome, hierarchical, palette, multicolor; gradients from SF Symbols 7; variable color to show a changing value ("use variable color to communicate change — don't use it to communicate depth").
- Nine weights matching San Francisco; three scales relative to cap height, so symbols track text styles automatically.
- Variants: outline (default, toolbar/list company), fill (more emphasis: tab bars, swipe actions, selection), slash (unavailable), enclosed (small-size legibility). Views often choose for you (tab bars prefer fill, toolbars outline).
- Language variants exist for many scripts and adapt automatically; custom symbols can declare RTL behavior.

## Spatial layout (visionOS)

- Field of view: keep content inside it; wide beats tall (eyes move sideways more comfortably than up and down).
- [NEVER] Anchor content to the wearer's head; it feels confining and blocks assistive pointer tech.
- Depth communicates hierarchy (a sheet pushes its window back); [PREFER] use depth for large structural separations, not small elements, and not so often that eyes must refocus constantly.
- Dynamic scale keeps windows legible as they move nearer or farther; fixed scale only for noninteractive true-to-life objects.
- [PREFER] Few windows; too many obscure surroundings and feel constricting.

## Typography

- [HARD] Follow the per-platform default and minimum text sizes (specifications.md).
- [ALWAYS] "In general, avoid light font weights." Regular, Medium, Semibold, Bold; not Ultralight, Thin, Light.
- [PREFER] "Minimize the number of typefaces... Mixing too many different typefaces can obscure your information hierarchy."
- [PREFER] "Consider using the built-in text styles." Text styles are the Dynamic Type mechanism; a hardcoded size opts that text out of the user's setting. Modify with symbolic traits (bold, leading adjustments) rather than abandoning styles. Tight leading only under height constraint, and [NEVER] for 3+ lines of text.
- [PREFER] Prioritize content when responding to size changes: people enlarging text want the content bigger, "they don't always want to increase the size of every word on the screen" (tab titles, transient values can stay).
- System fonts: San Francisco (SF Pro / Compact / Arabic / Armenian / Georgian / Hebrew / Mono, plus rounded variants) and New York (serif). Variable-format with dynamic optical sizing: tracking and glyph structure adapt continuously to point size. Access via APIs, never embedded copies.
- Custom fonts: [ALWAYS] must stay legible at the platform minimums and must implement Dynamic Type and respond to accessibility settings (Bold Text); the system does this for free, custom fonts by work.
- Dynamic Type support in practice:
  - [ALWAYS] "Make sure your app's layout adapts to all font sizes"; verify at Larger Accessibility sizes.
  - [ALWAYS] "Keep text truncation to a minimum as font size increases": show as much useful text at AX sizes as at standard ones; let labels wrap ("configure it to use as many lines as needed").
  - [PREFER] Icons that carry meaning scale with the text.
  - [PREFER] Change layout at AX sizes: stack inline items above/below text instead of beside it; reduce column counts.
  - [ALWAYS] Keep the information hierarchy stable regardless of size; primary elements stay at the top.
- macOS has no Dynamic Type; visionOS bolds body/title styles and adds Extra Large Titles; watchOS uses SF Compact (Rounded in complications).
- visionOS text: prefer 2D text, white default for contrast, bold if floating without a background, billboard labels to face the viewer.

## Writing

- [PREFER] Determine the app's voice (vocabulary, feeling) and vary tone by situation; a goal reached and a payment error do not sound the same.
- [ALWAYS] "Be clear... If you can use fewer words, do so. When in doubt, read your writing out loud."
- [ALWAYS] "Be action oriented." Verb labels on buttons: "it's almost always best to use a verb"; "Send" beats "Let's do it!". Links say what they open, never "Click here".
- [ALWAYS] "Adopt capitalization rules that align with your app's style, then apply them consistently": one choice per UI element type (title case reads formal, sentence case casual).
- [PREFER] Multistep flows: consistent step labels ("Get Started" opens, "Continue"/"Next" advances, "Done" closes).
- [PREFER] "Use possessive pronouns sparingly": "Favorites" over "Your Favorites". [ALWAYS] "Avoid using we altogether": "Unable to load content" over "We're having trouble loading this content".
- [ALWAYS] Device-correct verbs: "tap" on touch devices, "click" on Mac.
- [ALWAYS] Empty states guide: welcome, explain, and give a next action with a button; never park crucial information in a state that disappears.
- [ALWAYS] Error messages: near the problem, no blame, say the fix ("Choose a password with at least 8 characters" over "That password is too short"); no "oops!" interjections. "If you find that language alone can't address an error that's likely to affect many people, use that as an opportunity to rethink the interaction."
- [PREFER] Settings labels practical and short; describe the on state and let people infer the off state; link directly to a setting rather than describing its location.
- [ALWAYS] Text fields: clear labels, hint text with a format example, errors next to the field phrased as instructions ("Use only letters for your name") not prohibitions or robot-speak ("Invalid name").
- Delivery method follows urgency: notification vs alert vs action sheet (see the chooser).
