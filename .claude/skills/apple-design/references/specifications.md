# Specifications: every hard number Apple states

All values extracted from the HIG's own Specifications tables (June 2026 content). Each section names its source page. These are `[HARD]` by definition.

## Control sizes and hit targets (source: Accessibility, Buttons)

| Platform | Default control size | Minimum control size |
| --- | --- | --- |
| iOS, iPadOS | 44x44 pt | 28x28 pt |
| macOS | 28x28 pt | 20x20 pt |
| tvOS | 66x66 pt | 56x56 pt |
| visionOS | 60x60 pt | 28x28 pt |
| watchOS | 44x44 pt | 28x28 pt |

Buttons, verbatim: "a button needs a hit region of at least 44x44 pt — in visionOS, 60x60 pt — to ensure that people can select it easily, whether they use a fingertip, a pointer, their eyes, or a remote." The "minimum" column is Apple's absolute floor for controls generally; buttons get the full 44. On macOS, standard system controls are drawn at the macOS row's sizes (28x28 pt default), so this skill reads the macOS row as the floor for standard Mac controls and keeps 44x44 pt as the target for custom and icon-only buttons where space allows (a reading, not an Apple sentence).

Spacing around controls (Accessibility): "about 12 points of padding around elements that include a bezel. For elements without a bezel, about 24 points of padding works well around the element's visible edges." visionOS (Layout): "place buttons so their centers are at least 60 points apart."

## Color contrast (source: Accessibility)

WCAG Level AA values, as used by Apple's own Accessibility Inspector:

| Text size | Text weight | Minimum contrast ratio |
| --- | --- | --- |
| Up to 17 pt | All | 4.5:1 |
| 18 pt and larger | All | 3:1 |
| All sizes | Bold | 3:1 |

"If your app doesn't provide this minimum contrast by default, ensure it at least provides a higher contrast color scheme when the system setting Increase Contrast is turned on. If your app supports Dark Mode, make sure to check the minimum contrast in both light and dark appearances."

WCAG relative-luminance ratio, for computing from hex pairs: ratio = (L_lighter + 0.05) / (L_darker + 0.05), where L = 0.2126 R + 0.7152 G + 0.0722 B on linearized sRGB channels (c/12.92 if c <= 0.03928 else ((c+0.055)/1.055)^2.4).

## Text sizes for custom type (source: Accessibility)

| Platform | Default size | Minimum size |
| --- | --- | --- |
| iOS, iPadOS | 17 pt | 11 pt |
| macOS | 13 pt | 10 pt |
| tvOS | 29 pt | 23 pt |
| visionOS | 17 pt | 12 pt |
| watchOS | 16 pt | 12 pt |

Support enlargement "by at least 200 percent (or 140 percent in watchOS apps)". Thin custom weights need sizes above these defaults.

## Dynamic Type: iOS and iPadOS text styles (source: Typography)

The default (Large) setting, which is what most users run:

| Style | Weight | Size (pt) | Leading (pt) | Emphasized weight |
| --- | --- | --- | --- | --- |
| Large Title | Regular | 34 | 41 | Bold |
| Title 1 | Regular | 28 | 34 | Bold |
| Title 2 | Regular | 22 | 28 | Bold |
| Title 3 | Regular | 20 | 25 | Semibold |
| Headline | Semibold | 17 | 22 | Semibold |
| Body | Regular | 17 | 22 | Semibold |
| Callout | Regular | 16 | 21 | Semibold |
| Subhead | Regular | 15 | 20 | Semibold |
| Footnote | Regular | 13 | 18 | Semibold |
| Caption 1 | Regular | 12 | 16 | Semibold |
| Caption 2 | Regular | 11 | 13 | Semibold |

The scale runs across 12 user settings: xSmall, Small, Medium, Large (default), xLarge, xxLarge, xxxLarge, then five accessibility sizes AX1 to AX5. What that range does to Body, the style most text uses:

| Setting | xSmall | Small | Medium | Large | xLarge | xxLarge | xxxLarge | AX1 | AX2 | AX3 | AX4 | AX5 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Body size (pt) | 14 | 15 | 16 | 17 | 19 | 21 | 23 | 28 | 33 | 40 | 47 | 53 |

At AX5, the largest accessibility setting:

| Style | Size (pt) | Leading (pt) |
| --- | --- | --- |
| Large Title | 60 | 70 |
| Title 1 | 58 | 68 |
| Title 2 | 56 | 66 |
| Title 3 | 55 | 65 |
| Headline / Body | 53 | 62 |
| Callout | 51 | 60 |
| Subhead | 49 | 58 |
| Footnote | 44 | 52 |
| Caption 1 | 43 | 51 |
| Caption 2 | 40 | 48 |

Body more than triples from Large to AX5 (17 to 53 pt). A layout that has not been seen at AX sizes has not been verified. The full 12 tables live on the Typography page; re-extract if an intermediate setting matters.

Emphasized variants: SwiftUI `bold()`, UIKit `traitBold`. Emphasized weights are Bold for the titles, Semibold for the rest (table above).

## macOS built-in text styles (source: Typography)

macOS text styles do not scale with Dynamic Type; these are the fixed values:

| Style | Weight | Size (pt) | Line height (pt) | Emphasized weight |
| --- | --- | --- | --- | --- |
| Large Title | Regular | 26 | 32 | Bold |
| Title 1 | Regular | 22 | 26 | Bold |
| Title 2 | Regular | 17 | 22 | Bold |
| Title 3 | Regular | 15 | 20 | Semibold |
| Headline | Bold | 13 | 16 | Heavy |
| Body | Regular | 13 | 16 | Semibold |
| Callout | Regular | 12 | 15 | Semibold |
| Subheadline | Regular | 11 | 14 | Semibold |
| Footnote | Regular | 10 | 13 | Semibold |
| Caption 1 | Regular | 10 | 13 | Medium |
| Caption 2 | Medium | 10 | 13 | Semibold |

## tvOS built-in text styles (source: Typography)

| Style | Weight | Size (pt) | Leading (pt) | Emphasized weight |
| --- | --- | --- | --- | --- |
| Title 1 | Medium | 76 | 96 | Bold |
| Title 2 | Medium | 57 | 66 | Bold |
| Title 3 | Medium | 48 | 56 | Bold |
| Headline | Medium | 38 | 46 | Bold |
| Subtitle 1 | Regular | 38 | 46 | Medium |
| Callout | Medium | 31 | 38 | Bold |
| Body | Medium | 29 | 36 | Bold |
| Caption 1 | Medium | 25 | 32 | Bold |
| Caption 2 | Medium | 23 | 30 | Bold |

watchOS has its own Dynamic Type tables (xSmall through the accessibility sizes, with Footnote 1/2 replacing Footnote/no Callout); default 38mm Body is 15 pt, and the tables live on the Typography page.

## App icons (source: App icons)

| Platform | Layout shape | Shape after system masking | Layout size | Style | Appearances |
| --- | --- | --- | --- | --- | --- |
| iOS, iPadOS, macOS | Square | Rounded rectangle | 1024x1024 px | Layered | Default, dark, clear light, clear dark, tinted light, tinted dark |
| tvOS | Rectangle (landscape) | Rounded rectangle | 800x480 px | Layered (parallax) | N/A |
| visionOS | Square | Circular | 1024x1024 px | Layered (3D) | N/A |
| watchOS | Square | Circular | 1088x1088 px | Layered | N/A |

One 1024 px master; "the system automatically scales your icon to produce smaller variants" for Settings, notifications, Spotlight. Color spaces: sRGB, Gray Gamma 2.2, Display P3 (all platforms except visionOS for P3). Icons are authored in Icon Composer as layered artwork since the Liquid Glass redesign.

## Screen dimensions (source: Layout)

Current iPhones (iOS 18+ hardware; the full table back to iPhone 6, and Mac guidance, is on the Layout page):

| Model | Points (portrait) | Pixels |
| --- | --- | --- |
| iPhone 17 Pro Max / 16 Pro Max | 440x956 | 1320x2868 @3x |
| iPhone 17 Pro / 17 / 16 Pro | 402x874 | 1206x2622 @3x |
| iPhone Air | 420x912 | 1260x2736 @3x |
| iPhone 16 Plus / 15 Pro Max / 15 Plus | 430x932 | 1290x2796 @3x |
| iPhone 16 / 15 / 15 Pro / 14 Pro | 393x852 | 1179x2556 @3x |
| iPhone 16e / 14 / 13 | 390x844 | 1170x2532 @3x |
| iPhone 13 mini / 12 mini | 360x780 | 1080x2340 @3x |
| iPhone 11 / XR | 414x896 | 828x1792 @2x |
| iPhone SE (4.7 inch) | 375x667 | 750x1334 @2x |

Design floor for width: 360 pt (mini) or 375 pt (SE) depending on the supported set; verify long strings there and at 440 pt, not only on the workspace simulator's size.

iPads range from 744x1133 pt (mini 8.3 inch) to 1032x1376 pt (Pro 13 inch); full table on the Layout page.

tvOS safe zone: "Inset primary content 60 points from the top and bottom of the screen, and 80 points from the sides."

## Widgets (source: Widgets)

iOS widget dimensions by screen size (pt):

| Screen (portrait) | Small | Medium | Large | Circular | Rectangular | Inline |
| --- | --- | --- | --- | --- | --- | --- |
| 430x932 | 170x170 | 364x170 | 364x382 | 76x76 | 172x76 | 257x26 |
| 428x926 | 170x170 | 364x170 | 364x382 | 76x76 | 172x76 | 257x26 |
| 414x896 | 169x169 | 360x169 | 360x379 | 76x76 | 160x72 | 248x26 |
| 393x852 | 158x158 | 338x158 | 338x354 | 72x72 | 160x72 | 234x26 |
| 390x844 | 158x158 | 338x158 | 338x354 | 72x72 | 160x72 | 234x26 |
| 375x812 | 155x155 | 329x155 | 329x345 | 72x72 | 157x72 | 225x26 |
| 375x667 | 148x148 | 321x148 | 321x324 | 68x68 | 153x68 | 225x26 |
| 360x780 | 155x155 | 329x155 | 329x345 | 72x72 | 157x72 | 225x26 |

Where each family appears:

| Family | iPhone | iPad | Mac | Vision Pro | Watch |
| --- | --- | --- | --- | --- | --- |
| System small | Home Screen, Today View, StandBy, CarPlay | Home Screen, Today View, Lock Screen | Desktop, Notification Center | Horizontal and vertical surfaces | N/A |
| System medium / large | Home Screen, Today View | Home Screen, Today View | Desktop, Notification Center | Surfaces | N/A |
| System extra large | Not supported | Home Screen, Today View | Desktop, Notification Center | Surfaces | N/A |
| Accessory circular / inline / rectangular | Lock Screen | Lock Screen | N/A | N/A | Complications, Smart Stack |
| Accessory corner | Not supported | Not supported | N/A | N/A | Complications |

watchOS Smart Stack widget sizes: 40mm 152x69.5, 41mm 165x72.5, 44mm 173x76.5, 45mm 184x80.5, 49mm 191x81.5 pt. iPad tables distinguish canvas vs device sizes; visionOS Small is 158x158 pt. Full tables on the Widgets page.

## Live Activities (source: Live Activities)

Key iOS dimensions (pt), by screen:

| Screen (portrait) | Compact leading | Compact trailing | Minimal (width range) | Expanded (height range) | Lock Screen (height range) |
| --- | --- | --- | --- | --- | --- |
| 430x932 | 62.33x36.67 | 62.33x36.67 | 36.67 to 45 x 36.67 | 408 x 84 to 160 | 408 x 84 to 160 |
| 393x852 | 52.33x36.67 | 52.33x36.67 | 36.67 to 45 x 36.67 | 371 x 84 to 160 | 371 x 84 to 160 |

Dynamic Island width: 230 pt on the Pro-size phones (17 Pro, 17, 16 Pro, 15 Pro, 14 Pro), 250 pt on the Max/Plus/Air sizes; expanded presentations run 371 to 408 pt wide. CarPlay Live Activity sizes: 240x78, 240x100, 170x78 pt. Full tables on the Live Activities page.

## SF Symbols (source: SF Symbols)

- Nine weights, ultralight to black, matching the San Francisco font weights.
- Three scales: small, medium (default), large, defined relative to the font's cap height, so symbols size with their text style.
- Four rendering modes: monochrome, hierarchical, palette, multicolor. Built-in animations (bounce, pulse, replace, and more) work across all modes, weights, and scales.

## Materials (source: Materials)

- Four standard materials in iOS and iPadOS: ultra-thin, thin, regular (default), thick. Content layer uses these; Liquid Glass is for the controls and navigation layer.
- Four vibrancy levels for labels on materials: label, secondaryLabel, tertiaryLabel, quaternaryLabel. "Avoid using quaternary on top of the thin and ultraThin materials, because the contrast is too low."

## System colors (source: Color)

The HIG publishes system and gray palette values as color swatches (images), not text, so no hex values ship in this file; that is the point of the rule "avoid hard-coding system color values". Use `Color.red` ... `Color.brown` (SwiftUI) and `systemGray` to `systemGray6` (UIKit, iOS-only grays); each carries default and increased-contrast variants in both appearances. Custom brand colors go in an asset catalog with light, dark, and increased-contrast variants.

## Standard gestures (source: Gestures)

| Gesture | Platforms | Common action |
| --- | --- | --- |
| Tap | All | Activate a control; select an item |
| Swipe | All | Reveal actions and controls; dismiss views; scroll |
| Drag | All | Move a UI element |
| Touch (or pinch) and hold | iOS, iPadOS, tvOS, visionOS, watchOS | Reveal additional controls or functionality |
| Double tap | All | Zoom in or out; primary action on Watch Series 9 / Ultra 2 |
| Zoom (pinch) | iOS, iPadOS, macOS, tvOS, visionOS | Zoom a view; magnify content |
| Rotate | iOS, iPadOS, macOS, tvOS, visionOS | Rotate a selected item |
