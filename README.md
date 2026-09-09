# Up Only

A small, private macOS menu-bar app for monthly cash flow and net worth.

Up Only starts empty. Two short setup steps save your recovery code and offer automatic reference exchange rates and metal prices. Finish with **Add your first balance** or **Do this later**. Everything else is added from the **+** button on the home screen: a bank balance, crypto, gold and silver, a single income or expense, or a bank statement CSV. No account registration, analytics, connected wallets or cloud sync.

## What it does

- Two tabs: **Net worth** and **Cash flow**. One Monthly, Annual or All time selector beneath them controls both. Cash flow can show All, Personal, or a connected company. Net worth values balances at the selected period end.
- Monthly keeps the selected year's monthly chart for context, highlights the selected month, and provides previous/next arrows. The headline and data review still apply to the selected month.
- When something is missing, a **Needs attention** row appears under the time selector and names the first item (for example “Balance needed for Everyday”). It opens missing balances, quantities, prices, accounting and month-completion checks. The current month is never flagged. A balance or partial import never confirms complete spending; closed months require an explicit review, and new accounts or changed entries reopen the relevant reviews.
- Compact bank/profile rows show one full USD balance, alongside crypto and metals. Company pages show bank cash, your share, period profit/loss, history and underlying accounts.
- The personal net-worth headline and historical chart apply the company ownership in effect on each date. Assign company ownership when adding bank accounts or crypto/metals portfolios, or from Manage. Existing personal assets default to personal; matching connected bank profile names resolve to their accounting company. Full asset observations remain unchanged.
- Keeps quantities separate from prices. Moving coins between portfolios preserves the total quantity.
- Fetches optional CoinGecko USD prices and Frankfurter reference exchange rates while the app runs, including when the menu is closed or the vault is locked.
- Imports Monzo, Wise or the generic CSV format below, with review before saving. Mark transfers explicitly.
- Encrypts the ledger, holdings, settings, API key and imported statement originals in one local vault.
- Supports Touch ID or Mac-password unlock, a recovery code, and encrypted backup export/restore.

Personal Performance describes recorded outside income less personal spending. All adds ownership-weighted company profit from connected accounting, independent of owner draws; a company scope shows its full profit and your share separately. Missing accounting and personal records produce gaps or explicitly partial period totals. These are not investment returns. Net-worth changes include deposits, withdrawals and market moves. Missing observations remain missing; history is not invented. A month stays provisional until reviewed. Bank balances need manual updates; importing transactions does not infer a closing balance.

## Build and run

Requires macOS 26 or later and Xcode 26.6 or later. There are no third-party app dependencies.

1. Open `UpOnly.xcodeproj` in Xcode.
2. Select the **UpOnly** scheme and **My Mac** destination.
   In **Signing & Capabilities**, select your development team and keep automatic signing enabled. The production app requires an Apple-issued provisioning profile for its protected Keychain access group.
3. Build and run. Click the “up” icon in the menu bar for the compact welcome, setup, and dashboard. Bank balances, crypto and metals can be added directly in the menu bar: choose an asset, enter the amount, then review and save. Manage, settings, bulk imports and editors open as pages inside the same 344-point menu panel, with a bordered Back button. There is no separate management window or sidebar. Long pages scroll vertically within the menu. Native file pickers remain standard macOS dialogs. The menu mark and welcome wordmark use vector artwork for sharp rendering at each display scale; editable masters are in [UpOnly/Resources](UpOnly/Resources/README.md).
4. Complete setup and save the recovery code separately from backups. After vault creation, your onboarding step and choices are saved in the encrypted vault and resume after unlocking.

No personal development team is embedded in the project. UpOnly uses Apple Development signing; configure your own identity for distribution and notarize the app. UpOnlyFixture uses local ad-hoc signing and in-memory keys so previews and tests do not require production Keychain provisioning. This repository does not include a signed, notarized installer. Apple explains the signing requirement in [TN3137: On Mac keychain APIs and implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

For a synthetic preview and tests, use **UpOnlyFixture**. It uses a temporary vault, in-memory keys, and fabricated figures; it never opens the production vault. Fixture data is excluded from the production build. Set `UPONLY_PREVIEW_DESTINATION=welcome`, `recovery` (save a new code), `locked`, `recover` (enter a saved code), `setup`, `sources`, `networth`, `tracking`, `preferences`, `security`, `metals`, or `import` when launching the fixture. Use `UPONLY_PREVIEW_TRACKED=banks`, `crypto`, `metals`, `cashFlow`, or comma-separated combinations. `UPONLY_PREVIEW_DARK=1` selects dark appearance; `UPONLY_PREVIEW_CAPTURE=1` writes a synthetic screenshot and prints its path. Use `UPONLY_PREVIEW_LONG_TEXT=1` to exercise wrapping with long names, filenames, and large amounts. All management previews use the same 344-point panel as the app, with a borderless fixture host.

Additional preview destinations: `accounts`, `portfolios`, `entries`, `empty`, `syncing`, `sync-error`, `missing-rates`, `worth-missing-rates`, `resume-setup`, `add-info`, `manual-bank`, `manual-crypto`, `manual-metals`, and `statements`. Use `guided-choices`, `guided-bank`, `guided-crypto`, and `guided-metals` for the compact entry flow; `UPONLY_PREVIEW_ENTRY_STEP=choose`, `amount`, or `review` selects a step, and `account` checks new bank account entry. The `calendar` destination renders the native date picker. Set `UPONLY_PREVIEW_HIDDEN=1` with capture enabled to render without showing a window or activating the app. Additional failure previews: `failed-rates`, `missing-balances`, and `missing-prices`. Wise previews require the private fixture compilation flag and always use fabricated profiles.

`UPONLY_PREVIEW_OFFSCREEN=1` positions the synthetic window outside the desktop without activating it, while allowing Accessibility button actions. It prints a temporary `UPONLY_AUDIT_DIRECTORY` that accepts bounded JSON commands (`controls`, `type` by native field index, and `capture`) in `ui-command.json` and writes `ui-response.json`. This harness exists only in the fixture build. Use the current `controls` response before editing because native field order can change. `UPONLY_VERIFY_PUBLIC_FX=1` verifies the real v2 current/history parsers against public GBP/EUR/AED rates plus an intentionally unsupported code, using no user credentials or vault.

Set `UPONLY_PREVIEW_MENU_BAR=1` to check the actual menu-bar presentation instead of a preview window. Launch the fixture through Finder or `open`, then click its distinct “up*” preview label to verify opening, closing, and reopening at a readable size, with no large window opening at launch. This catches menu-bar sizing regressions that a regular preview window cannot reproduce. Pages fit their content up to 600 points high, then scroll; the locked row stays 144 × 56 points. Use `UPONLY_PREVIEW_DESTINATION=sources` with `UPONLY_PREVIEW_SOURCES_ENABLED=1` to check the largest setup state, with all price-key fields visible. `UPONLY_PREVIEW_DARK=0` and `1` also apply to actual menu-bar previews.

With FlowDeck installed:

```sh
flowdeck config set --workspace UpOnly.xcodeproj --scheme UpOnlyFixture --device 'My Mac' --configuration Debug
flowdeck test --streaming
flowdeck run
```

## Optional prices

Enter your own [CoinGecko Demo API key](https://www.coingecko.com/en/api/pricing) in setup or Sources. Choose a coin from the catalog or enter its exact CoinGecko ID, such as the public identifier `bitcoin`. Symbols are not unique identifiers.

Price requests send only selected coin IDs, the API key and network metadata to CoinGecko. Currency conversion sends currency codes and network metadata to Frankfurter. Neither request contains quantities, portfolio names, account names or balances. A failed currency request does not discard successful rates. When conversion is unavailable, monthly income and spending remain visible by currency; the affected result names the missing currencies and offers enabling, retrying, or manually supplying a dated rate. Crypto and metals refresh hourly; banks refresh every 12 hours. FX and accounting retain their 15-minute background checks while the app is running and the Mac is awake. Wake/reconnect checks respect the persisted source schedules. Initial setup requires one normal unlock. While locked, fetched observations are sealed for the vault; they are applied after the next normal unlock. Provider limits and outages are shown; saved observations are retained.

Rates are reference rates, not executable trading quotes. Personal historical FX backfills missing monthly rates independently of the asset-history queue when automatic FX is enabled. You can also add a dated USD exchange rate in Entries. USD totals are the initial reporting currency.

## Local price history and offline catch-up

All holdings, exact quantities, price/FX observations, catch-up checkpoints and daily valuations live in the encrypted vault on this Mac. There is no database server, Cloudflare dependency or hosting bill. Backups include this history. The current store is an atomically replaced encrypted document, not SQLite; the existing 128 MiB limit still applies. A future encrypted local database could avoid whole-file writes for unusually large histories without adding a server.

When unlocked, refresh checks for missing historical periods, including after the network reconnects. It retrieves published historical prices and rebuilds daily values with the quantities and dated bank observations that were effective then. It does not apply today's holdings or prices retroactively, infer unrecorded balance changes, or fabricate missing prices. Catch-up requests are chunked into 90-day periods and limited to four per refresh; remaining periods are queued. Provider errors back off and retry; partial responses leave visible gaps. Failed writes or locking save none of that update.

Crypto history uses [CoinGecko's Demo range endpoint](https://docs.coingecko.com/demo/reference/coins-id-market-chart-range), retaining the last returned observation per UTC day. Demo access covers the past 365 days; older data already saved is retained. [Frankfurter v2](https://frankfurter.dev/) supplies daily reference rates and their history without a key. Weekend FX uses the last published reference within seven days, keeping its original timestamp. These are reference rates, not live executable FX quotes.

**Precious metals** supports physical gold, silver, platinum and palladium independently from crypto. Enter total **fine metal weight**, excluding alloy weight, in `g`, `kg`, or `ozt` (troy ounces). One troy ounce is exactly 31.1034768 grams. Internal quantities are fine grams with exact decimal conversion; derived USD-per-gram prices are rounded to 12 decimal places. Explicit zero replaces the total, and omitted metals stay unchanged. Spot values exclude premiums and selling fees. Tokenized metals belong in Crypto holdings.

Enable metal prices in Sources. [Gold API](https://gold-api.com/docs) provides current USD spot prices without a key. Its **free account key** enables daily-average history for offline catch-up; add it in Sources. The free plan allows ten historical requests per hour; Up Only caps its metal history work at four/hour and spaces requests. Missing keys, rate limits and unavailable dates appear in Sources. Metal price charts label daily averages and show gaps; net worth charts include these holdings. Current spot values and daily averages are distinct observations, not tick-by-tick trade history.

[Preev](https://preev.com/) describes WebSocket streams from 12 exchanges and a 24-hour volume-weighted average. It is useful as a reference for a future live-price display; this release uses documented provider APIs and hourly price refreshes. It does not scrape Preev or claim continuous live ticks. Daily catch-up supplies the app's daily charts, not every trade missed while offline.

## Adding data

The **+** button opens one Add page with five choices: Bank balance, Crypto, Gold & silver, Income or expense, and Bank statement. The first three use a short guided form (choose → amount → review → save). Bank statement opens the file picker directly and then shows a summary with the account, covered months, and an **Import N transactions** button. The link at the bottom, **Import several at once from a spreadsheet…**, opens the bulk table described below.

The bulk import accepts multiple CSV files, dropped files, and cells copied from Excel or Numbers. Choose **Statements**, **Bank balances**, **Crypto holdings**, or **Precious metals**. Each follows Input → Review → Save. Nothing is saved until the entire accepted batch validates; locking clears unsaved drafts.

Known Monzo, Wise, and Up Only statement headers are recognized. Other exports have editable column mapping, explicit date and number formats, and optional headers. Use one account per statement file or pasted table; create accounts inline without an opening balance if needed. Statement imports never infer closing balances.

Statements accept uploaded CSV files only; they have no manual-row or spreadsheet-paste action. Imported rows can still be reviewed and corrected. Select rows to classify income, expense, or transfers together. Identical account-scoped transaction IDs are skipped; conflicting IDs are blocked. Without IDs, similar transactions require an explicit decision so legitimate repeated payments are retained. Original statement files and optional import fingerprints remain encrypted in the vault.

Save a CSV template from any input screen. Default templates use ISO dates and decimal points. Supported columns:

| Input | Columns |
|---|---|
| Statements | `TransactionID` (optional), `Date`, `Description`, `Amount`, `Currency`, `Type` |
| Bank balances | `Account`, `Currency`, `Balance`, `ObservedOn` |
| Crypto holdings | `Portfolio`, `Coin`, `Quantity` |
| Precious metals | `Portfolio`, `Metal`, `Weight`, `Unit` |

Statement mapping also supports separate Debit/Credit columns. With a Type column, amounts are nonnegative and types are `income`, `expense`, or `transfer`; otherwise the amount sign determines the initial classification. Headerless statement paste starts with Date, Description, Amount, Currency, Type, TransactionID.

Bank balances may be negative or zero. Today's observations use the save time, allowing multiple updates in a day. Historical dates remain historical observations. Crypto quantities replace the total for the listed coin and portfolio; omitted holdings remain unchanged. Explicit zero sets the quantity to zero. Coin tickers need an explicit selection; exact CoinGecko IDs and a bundled common-coin list also work offline.

Bulk entry (**Import or paste…**) selects statements, bank balances, crypto holdings, or metals for table entry. The individual Add cards keep the short guided forms.

Use **Update all balances** in Accounts or **Update all quantities** in Crypto to start from existing records. Manage lists Accounts, Crypto, Gold & silver and Transactions only once they contain data, followed by **Prices & rates** and **Backup & security**. Older vaults that chose a subset of asset types during setup keep that choice under the hood.

Limits: 8 MiB and 20,000 rows per file; 50 files, 32 MiB and 50,000 rows per batch; 128 MiB per encrypted vault. Excel workbooks and PDFs are not supported; export CSV or copy spreadsheet cells.

## Optional private Wise build

The standard app contains no Wise API connector. A local build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=UPONLY_PERSONAL` enables a read-only native connector. Use a separate bundle identifier (for example `org.uponly.personal`) and the **Up Only Personal** vault directory.

The connector reads a local Keychain item with service `org.uponly.personal.wise`, account `connection`. Its JSON contains a read-only `token` and a `profiles` array with `id`, `name`, `bucket`, and optional base64 `image`. Configure this only on the owner's Mac; never bundle it, commit it, or include it in screenshots or logs. Public builds compile out credential access, network code, and Wise setup controls.

The private build reads STANDARD balances and the activity feed from `api.wise.com`, follows all pages within a bounded sync, and saves atomically. Completed activities are deduplicated by profile and activity ID. Cancelled/reversed records are removed; card checks are excluded. Interbalance movements and transfers identifiable across connected profiles are classified as transfers. Other transfers can be reviewed in Transactions. The activity feed is not a certified bank statement.

Crypto and gold/silver prices refresh hourly in the background. Balances and completed transactions refresh silently in the background every 12 hours, including while the vault is locked. The persisted schedule survives relaunches and reconnects; unlocking applies encrypted cached updates without requesting Wise again. Sources provides an automatic-sync switch and Sync Wise now. Profile artwork is configured locally and encrypted with linked accounts; unavailable artwork uses initials. Currency conversion remains a separate, optional source. No payment or transfer-creation endpoint exists in the app.

## Private company accounting and Performance

The private build also reads an owner-configured `org.uponly.personal.accounting` Keychain item (`connection`), containing a service-account email, DER private key and source mappings. Source IDs, company names and ownership periods are local configuration. Google Sheets and Drive access uses read-only OAuth scopes; the app never changes the accounting workbooks. These credential and network implementations compile out of public builds.

Profit First workbooks use actual revenue less operating expenses, before owner salaries, dividends and retained allocations. P&L workbooks use NET PROFIT. Source reconciliation errors remain visible; unreadable months remain gaps. Ownership is date-effective and monthly shares round to cents before aggregation. Annual and all-time figures are sums of recorded monthly results, with missing-month counts. Company profit does not inflate net worth; bank balances remain actual balances.

The top row holds the Net worth / Cash flow tabs, a **+** button for adding data, and a **…** menu with Manage, Hide values and Lock. Data that needs review appears as an inline row beneath the time selector rather than inside the menu. The shared time selector sits beneath them; detail pages put Back and the title above the time selector. Account arrows beneath the headline cycle the selected scope and update the result and chart together. The Needs attention row opens a single page, with monthly income/spending totals, transactions and completion in one page, plus relevant missing-data and refresh-retry actions. Performance charts rescale for the selected entity and period. Selecting a chart month opens its monthly result. Company details show revenue, costs, profit and ownership share. Incomplete results keep specific missing-data messages and review actions; generic Partial labels are omitted. Secondary portfolio, holding and import actions are grouped into menus. Charts use sparse round-number axes, restrained smoothing, a light fill and exact values on hover; missing observations remain gaps. Secondary actions and menus use native bordered controls throughout the app. Full-card choices have one visible outline and pressed/disabled feedback. Entry classification still matters: owner-paid expenses already counted in company accounting and proceeds from asset sales need review if imported as personal spending or income.

Synthetic Performance previews use `UPONLY_PREVIEW_DESTINATION=performance` or `performance-missing`, with `UPONLY_PERFORMANCE_SCOPE=all|personal|studio|agency` and `UPONLY_PERFORMANCE_PERIOD=Monthly|Annual|All time`. A private fixture can run `UPONLY_VERIFY_ACCOUNTING=1` to check configured real read-only sources in isolation, without opening the production vault. Its financial audit stays in a private temporary directory on the Mac.

## Security and recovery

See [SECURITY.md](SECURITY.md) for storage, network boundaries and limitations. Keep your recovery code separate from backups. Losing both the Keychain access and the recovery code means losing access to the vault.

This is an early source release. Automated tests exercise encryption, failure paths, recovery, valuation and input validation. They are not an external security certification.

## License

MIT. See [LICENSE](LICENSE).

Privacy mode: use the eye button (Shift–Command–P) to hide amounts throughout the viewer, management pages and editable forms. The preference is saved in your encrypted vault. Closing the menu leaves the vault unlocked for the remainder of its five-minute inactivity period; reopening or interacting restarts that period. Mac lock and sleep still lock immediately. Touch ID feedback appears inside the compact unlock row on supported hardware; Click the fingerprint icon for the native Mac-password prompt; Control-click the logo for recovery options.

Synthetic fixtures also accept `UPONLY_PREVIEW_PRIVACY=1` for masked screenshots and `UPONLY_PREVIEW_IDLE_LOCK=1` to exercise the production inactivity observers in an isolated test desktop. Both switches are excluded from production.

Performance periods match their chart: Monthly contains the selected month only (a single monthly observation is a compact horizontal bar), Annual contains that year, and All time contains recorded history. Every recorded month has a marker. Empty leading/trailing history is omitted from the plot while interior missing months remain gaps. With accounting connected, first opening defaults to the latest common reported month; an explicit selection is preserved across refreshes. Unreported company months are identified separately from connection failures, and known personal/company results remain visible as partial. Temporary accounting failures retry, successful companies refresh independently, and saved company/month history is retained with a warning when a refresh omits it.

## Optional unlock timing

Launch with `UPONLY_MEASURE_UNLOCK=1` to record the latest successful unlock's phase timings in `unlock-timing.json` in the app's Application Support directory. The diagnostic records authentication method and elapsed times for the macOS authentication callback, protected key read, vault opening, dashboard preparation and first AppKit menu display. It records no financial values, passwords, fingerprint data, screenshots or accessibility contents. It is off by default and does not bypass authentication. The display timestamp follows `displayIfNeeded()`; physical monitor scan-out is not measured.
