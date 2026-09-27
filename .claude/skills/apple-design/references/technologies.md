# Technologies (9 pages distilled, 20 read and dismissed)

Technologies distilled at rule depth. Tags per the skill's strength model; quoted sentences are Apple's.

## In-app purchase

- [PREFER] "Let people experience your app before making a purchase."
- [ALWAYS] The store is integrated: browsing and buying mirror the app's style, never a bolted-on shop.
- [ALWAYS] "Display the total billing price for each in-app purchase you offer." Simple, non-truncating product names.
- [ALWAYS] Show the store only when the person can pay (`canMakePayments`); otherwise hide it or explain.
- [HARD] "Use the default confirmation sheet. Don't modify or replicate this sheet."
- Subscriptions:
  - [PREFER] A range of durations and levels; limited free access (freemium, metered paywall, trial) before signup.
  - [ALWAYS] Options distinguishable at a glance: name, price, duration; introductory offers list the intro price, its duration, and the standard price after.
  - [ALWAYS] "Clearly describe how a free trial works": trial length and the exact amount auto-billed when it ends, on the signup screen.
  - [PREFER] Minimal signup fields; a subscribe entry point in settings; Terms of Service and Privacy Policy links on the in-app signup screen.
  - [ALWAYS] Help people manage and cancel: link the system management flow; a custom purchase-help screen may add app-specific help and must keep the system refund flow reachable, with a plain "Request a Refund" label.
- Family Sharing: welcome family members with wording that fits them ("Your family subscription includes…").

## Sign in with Apple

- [PREFER] The system button via the system APIs (correct localization, sizing, review-safe). A custom button must remain instantly recognizable, use only Apple's downloadable logo artwork, and keep the system proportions (title font size 43% of button height); App Review evaluates it.
- Titles: "Sign in with Apple", "Sign up with Apple", or "Continue with Apple".
- [ALWAYS] Respect the private relay address; [NEVER] ask for a personal email to replace one.
- [PREFER] Let people link an existing account; ask for optional data only after engagement, and never gate features on declining.
- [PREFER] Show the shared name/email back to people (transparency about what was collected).

## iCloud

- [ALWAYS] Works automatically when the user has iCloud on; at most one all-or-nothing choice at first launch; [NEVER] per-document storage questions.
- [ALWAYS] Respect the storage people pay for: store what people create, never regeneratable resources; be picky about the Documents folder (backups include it).
- [PREFER] Keep content current within storage/bandwidth reason; indicate when a newer version exists; subtle feedback on slow downloads.
- [ALWAYS] Behave gracefully when iCloud is off or unreachable: no alert, an unobtrusive note that changes will not sync yet.
- [PREFER] Resolve version conflicts automatically and early; when impossible, an unobtrusive chooser that differentiates versions.
- State (last-read position, cross-device settings) belongs in iCloud too; search results include iCloud content.

## Generative AI

- [ALWAYS] "Keep people in control": honor requests, allow dismiss/revert/retry, never make the AI the decision maker.
- [ALWAYS] "Clearly identify when and where you use AI"; [NEVER] pass AI output off as human-authored; align disclosure with regional regulation.
- [ALWAYS] Inclusive by design: ask for the information a feature needs about a person rather than inferring personal or cultural characteristics; test across diverse people.
- [ALWAYS] Disclose how personal data is used and whether it trains the model.
- [ALWAYS] Permission before irreversible or significant actions; never automate destructive ones.
- [PREFER] Generative features only where they add clear value, with a non-AI fallback when the feature is complementary.
- [PREFER] Refinement controls (Edit, Undo, Retry, Adjust) near generated content, with visible acknowledgment when corrections take effect.
- [PREFER] Blocked-output moments coach a better request ("Unable to use that description" plus examples).
- [PREFER] Generation feedback is specific: "Finding substitutions for ingredients" beats "Processing…".

## Machine learning

- Classify the feature first: complementary (app works without it) or critical; visible or invisible; proactive or reactive; dynamic or static. The answers set how much control and disclosure people need.
- Feedback: [PREFER] implicit signals over asking; explicit feedback always voluntary, described by consequence (never a bare "dislike"), and usable to tune when/where results appear.
- [ALWAYS] Multiple implicit signals before concluding intent (viewing plus sharing a photo still does not mean liking it).
- [ALWAYS] Strict privacy on behavioral signals; tell people how information flows and let them restrict it; withhold suggestions on private or sensitive topics (shared devices exist).
- Mistakes are part of the design: correction paths, not just accuracy targets.

## Photo editing (extensions)

- [ALWAYS] Preview edits before returning to Photos; the extension icon is the app icon.

## Live Photos

- [ALWAYS] Keep the content intact ("don't disassemble a Live Photo"); still representation in unsupported contexts, never a fake replica of the effect; download progress shown; distinguishable from stills (a motion hint; badge in a consistent corner).

## Siri (App Intents)

- Expose the app's most popular actions and personally relevant content (recents, favorites) as intents/entities, named in the words people actually use.
- Responses: [ALWAYS] succinct (they get heard repeatedly), deliverable audibly AND visually with the voice version self-sufficient, device-independent, inclusive ("Who should I send it to?" not "What's his or her name?"), clean of offensive language.
- [ALWAYS] Specific errors: "Sorry, we're out of chicken noodle soup" beats "we can't complete your order."
- [NEVER] Impersonate Siri, reproduce its functionality, or use reserved phrases.

## VoiceOver

- [ALWAYS] "Provide alternative labels for all key interface elements", including every custom element, kept current as the UI changes.
- [ALWAYS] Describe meaningful images: only what the image itself conveys (VoiceOver already reads nearby captions).
- [ALWAYS] Charts and infographics get a concise description plus accessible versions of their interactions.
- [PREFER] Unique screen titles and real section headings (the title is the first thing announced; headings build the mental model); support the rotor for heading/link navigation.

---

## Read and dismissed (20 technology pages)

Every page below was fetched and read in full for this distillation. None is distilled because it was judged out of scope for the apps this skill was written for; the one-line note says what it covers so a future need can reverse the call by re-extracting the page (URLs in SKILL.md → Provenance).

- **AirPlay**: streaming media to other devices.
- **Always On**: watchOS/iPhone always-on display states; no watch app.
- **App Clips**: lightweight app excerpts launched from links/codes.
- **Apple Pay**: physical-goods/services payment.
- **Augmented reality**: ARKit experiences; none shipped or planned.
- **CareKit**: care plans and health tasks; out of domain.
- **CarPlay**: car dashboard apps; out of domain.
- **Game Center**: leaderboards/multiplayer.
- **HealthKit**: health data storage/display; out of domain.
- **HomeKit**: home automation; out of domain.
- **ID Verifier**: government ID checking; out of domain.
- **iMessage apps and stickers**: Messages extensions; none planned. (Would be the binding page if a sticker pack ever ships.)
- **Mac Catalyst**: iPad apps on Mac.
- **Maps**: MapKit display conventions; the page is about map-centric apps; re-extract if map features grow.
- **NFC**: tag reading; out of domain.
- **ResearchKit**: medical research studies; out of domain.
- **SharePlay**: synchronized group sessions over FaceTime.
- **ShazamKit**: audio recognition; out of domain.
- **Tap to Pay on iPhone**: merchant payments; out of domain.
- **Wallet**: passes and tickets; out of domain.
