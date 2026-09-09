# User-flow audit and simplification

Audit date: 2026-09-09. Scope: every common flow in the menu-bar app. The goal was the way Apple would structure a small personal-finance app: one obvious place to add, one obvious place to see, plain words, and the rules hidden under the hood.

## Principles used

1. **One verb per screen.** Home shows. Plus adds. The dots menu manages.
2. **Show what exists, not what could exist.** Sections appear when you add data. No pre-configuration.
3. **Ask for a credential when it is needed, not up front.** Exchange rates and metal prices need no key, so they are one switch. The CoinGecko key is asked for when a crypto price is actually missing.
4. **Say what is wrong in the user's words.** "Balance needed for Everyday" beats an orange dot.
5. **Do not nag about the present.** The current month is always incomplete; that is not a problem to fix.

## Flow-by-flow findings and changes

### First run

| Before | Problem | After |
|---|---|---|
| Three steps: recovery code → "What do you want to track?" (four cards) → "Keep it current" (per-provider switches, CoinGecko key field, Gold API key field, provider disclosure). | Two of the three steps were configuration, not onboarding. New users had to understand asset types and API keys before entering a single number. | Two steps: recovery code → one switch, "Automatic prices and exchange rates", on by default, with a collapsed "What providers receive" note. Primary button is **Add your first balance**. |

Under the hood all asset kinds are tracked from the start; the home screen and Manage show only kinds that contain data. The Tracking page is gone. Vaults created before this change keep whatever subset they chose.

### Home screen

| Before | Problem | After |
|---|---|---|
| Tabs "Performance" / "Net worth", Performance first. | "Performance" reads as investment return. Net worth is the headline number a personal-finance app leads with. | Tabs "Net worth" / "Cash flow", Net worth first and the default when any asset exists. |
| Adding data lived behind an empty-state button or Manage → Add your info. | The most common action had no permanent home. | A **+** button sits in the top row on every home state. |
| Review items hid inside the "…" menu with a 5-point orange dot. | Invisible. Also lit permanently because the current month always counts as unreviewed. | An inline **Needs attention** row under the time selector names the first item or the count. The current month is excluded. The "…" menu is now just Manage, Hide values, Lock. |
| Captions: "Personal result", "Your share · Sep 9, 2026", "Last-known values · Some sources need an update", "Needs update · Last complete …". | Internal vocabulary. | "Income minus spending", "As of Sep 9, 2026", "Some values may be out of date", "Last complete value · date". |
| Empty state: "Nothing recorded yet – Add your info". | Vague. | "Start with one balance" with a one-line list of what counts and a single **Add** button. |

### Adding a bank balance, crypto, or metals

The guided three-step form (choose → amount → review) was already good and is kept. Changes: the picker is now a proper page titled **Add** with five cards that each say what they are for ("What's in an account, as of a date"). "Precious metals" is "Gold & silver" everywhere.

### Importing a bank statement

| Before | Problem | After |
|---|---|---|
| Statements were reachable via "Statements & bulk import…", which opened a table page with "Import or paste…", "Check file", "Fix import", "Apply mapping", "Check corrections", "Back to summary". | Too many verbs. Statements were lumped with spreadsheet paste. | A **Bank statement** card on the Add page goes straight to the file picker and then the summary (account, months covered, **Import N transactions**). The bulk table is a secondary link, "Import several at once from a spreadsheet…". Buttons renamed "Review" and "Fix rows". |

Unchanged and still worth a later pass: the column-mapping editor for unknown CSV layouts, and the per-row editor. Both are only reached when a file does not match a known bank format.

### Checking balances and drilling in

Unchanged structurally. Rows on the Net worth tab open a group, portfolio, or company page. Wording in those pages was aligned with the rest ("Add a coin", "Set up prices", "Open Prices & rates").

### Manage

| Before | After |
|---|---|
| Add your info, Accounts, Crypto, Precious metals, Transactions, Tracking, Sources, Security. | Accounts, Crypto, Gold & silver, Transactions (each only once it has data), then Prices & rates, Backup & security. If nothing has data yet, a one-line hint points to the plus button. |

### Needs attention page

Title "Review data" → "Needs attention". The month check now asks a question, "Is all of your income and spending for August 2026 recorded?", with a **Yes, it's complete** button, instead of "Mark month complete". Empty state: "You're all caught up".

## What stayed under the hood, deliberately

- The reviewed-month rule (a month is provisional until the user confirms it). It still exists, but the app asks a plain question once the month is over instead of surfacing "provisional" states.
- Tracked kinds, ownership, company scopes, FX repair, and price-history catch-up are unchanged in the model. Only their presentation moved.
- Import validation, duplicate detection, and atomic saves are untouched.

## Second pass (same day): intuitiveness and minimalism

No functionality was removed. Each change makes an existing action visible or plainer.

| Where | Before | After |
|---|---|---|
| Net worth / Cash flow headline | "‹ All assets ›" cycling control. | A small menu pill, "All assets ⌄", listing every scope with a check mark. |
| Time selector menu | Monthly / Annual / All time, "Choose month", "Current month". | By month / By year / All time, "Go to month", "This month". |
| Cash flow with nothing recorded | Text only. | Text plus an **Add** button. |
| Bank statement from the + button | After saving or cancelling you landed on a Manage sub-page. | You return to the overview, with "Statement imported." shown once. Back reads "Back to overview". |
| Accounts page cards | One "Edit" menu hiding Update balance, Import statement, Owner, Include in net worth. | A visible **Update** button; the rest under a "…" button. |
| Crypto and Gold & silver cards | Same "Edit" menus on portfolios and on each coin. | **Update** on each coin; **Update all** on the portfolio only when it holds more than one coin; "…" for Add a coin, Owner, Archive, Move to another portfolio. |
| Guided form buttons | "Review balance" / "Save balance", "Review holding" / "Save holding". | "Next" / "Save". The review step names the account instead of "Create new / Update balance". |
| Empty Manage pages | "Your accounts, together", "Your coins, wherever you keep them". | "No accounts yet", "No crypto yet". |

## Purchase dates and gain since purchase

- Crypto and metal entries carry an "As of" date and an optional "Paid" amount with currency. The date is the quantity observation's effective date, so charts and history use it directly; nothing new is inferred.
- Backdating is allowed: a purchase dated before a holding or portfolio existed moves their start back to that day, and an earlier total may be inserted before later ones. When that happens the stored daily values from that day forward are recomputed off the main actor; days without saved prices become gaps rather than stale numbers until the price-history catch-up fills them.
- Costs live in an optional `purchases` list of lots (holding, quantity bought, total paid, currency, date). Old vaults load unchanged. Gain is simple: current value minus cost; no time-weighting.
- Each holding shows "Since Mar 2025 · Paid $4,200 · +$1,310 (+31%)" on the portfolio page and in Manage. A cost in another currency shows unconverted until a rate for that month exists.

Review notes from the bug pass: the duplicate check now compares against the total on the chosen date, not today; the entry date is always parsed as ISO regardless of a file's date format; lock clears the new navigation flags; the crypto page values each portfolio once rather than once per row.

## Remaining opportunities (not done)

1. **Bulk import table.** Column mapping, date and number formats, and per-row editing remain a power-user surface. It is now out of the main path but could be reduced to a single "This file looks like: [Monzo / Wise / Generic]" chooser.
2. **CoinGecko key prompt.** Currently a "Set up prices" button on the Net worth tab when a coin has no price. An inline field on that card would save a trip to Manage.
3. **Prices & rates page.** Switches still need an explicit "Save changes". Auto-saving each switch would match system Settings, but the CoinGecko key field needs validation first.
4. **Company and ownership pages** (private build) were not audited for wording.
5. **Purchase lots** cannot yet be edited or deleted, and the spreadsheet import has no Paid column.

## Verification

- 134 unit tests pass (`flowdeck test`, UpOnlyFixture scheme).
- Fixture previews checked: `sources` (setup step 2), `networth`, `performance`, `empty`, `add-info`, `guided-choices`, `accounts`, `missing-balances`. Note that the in-app synthetic capture omits glass-effect controls (the plus button and period chevrons); a `screencapture -l` of the live preview window shows them.
