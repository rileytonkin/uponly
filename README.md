# Up Only

A small, private macOS menu-bar app for monthly cash flow and net worth.

Up Only starts empty. First-run setup creates an encrypted vault and a recovery code, then lets you choose whether to enable public market prices. Add your own bank accounts, crypto portfolios, income and expenses inside the app. No account registration, analytics, connected wallets or cloud sync.

## What it does

- Shows the current month’s recorded income, spending and net result, with monthly history.
- Tracks dated bank balances and multiple manually maintained crypto portfolios.
- Keeps quantities separate from prices. Moving coins between portfolios preserves the total quantity.
- Fetches optional CoinGecko USD prices and Frankfurter reference exchange rates while unlocked.
- Imports Monzo, Wise or the generic CSV format below, with review before saving. Mark transfers explicitly.
- Encrypts the ledger, holdings, settings, API key and imported statement originals in one local vault.
- Supports Touch ID or Mac-password unlock, a recovery code, and encrypted backup export/restore.

Monthly results describe **recorded cash flow**, not investment returns. Net-worth changes include deposits, withdrawals and market moves. Missing observations remain missing; history is not invented. A month stays provisional until reviewed. Bank balances need manual updates; importing transactions does not infer a closing balance.

## Build and run

Requires macOS 15 or later and Xcode 26 or later. There are no third-party app dependencies.

1. Open `UpOnly.xcodeproj` in Xcode.
2. Select the **UpOnly** scheme and **My Mac** destination.
3. Build and run. The chart icon appears in the menu bar.
4. Complete setup and save the recovery code separately from backups.

The checked-in project uses local ad-hoc signing, with no developer identity or team embedded. For distribution, configure your own signing identity and notarize the app. This repository does not include a signed, notarized installer.

For a synthetic preview and tests, use **UpOnlyFixture**. It uses a temporary vault, in-memory keys, and fabricated figures; it never opens the production vault. Fixture data is excluded from the production build. Set `UPONLY_PREVIEW_DESTINATION=setup` or `networth` when launching the fixture to inspect those screens.

With FlowDeck installed:

```sh
flowdeck config set --workspace UpOnly.xcodeproj --scheme UpOnlyFixture --device 'My Mac' --configuration Debug
flowdeck test --streaming
flowdeck run
```

## Optional prices

Enter your own [CoinGecko Demo API key](https://www.coingecko.com/en/api/pricing) in setup or Sources. Choose a coin from the catalog or enter its exact CoinGecko ID, such as the public identifier `bitcoin`. Symbols are not unique identifiers.

Price requests send only selected coin IDs, the API key and network metadata to CoinGecko. Currency conversion sends currency codes and network metadata to Frankfurter. Neither request contains quantities, portfolio names, account names or balances. Refreshes run every 15 minutes while unlocked and stop when locked. Provider limits and outages are shown; saved observations are retained.

Rates are reference rates, not executable trading quotes. For historical entries, add a dated USD exchange rate in Entries if no suitable rate has been recorded. USD totals are the initial reporting currency.

## Statement format

The generic format has these headers:

```csv
TransactionID,Date,Description,Amount,Currency,Type
```

Use a unique transaction ID, an ISO date (`YYYY-MM-DD`), a nonnegative decimal amount, a three-letter currency code, and `income`, `expense` or `transfer`. Amounts use a period as the decimal separator and no currency symbols. Quote fields containing commas. Monzo and Wise statement dates use `DD/MM/YYYY`.

Select the account the statement belongs to, then review every classification before importing. Files larger than 8 MB or 20,000 rows are refused. Invalid rows stop the entire import. Duplicate transaction IDs for the same account are skipped across statements; importing the exact same file again is refused. Account balances remain separately dated observations.

## Security and recovery

See [SECURITY.md](SECURITY.md) for storage, network boundaries and limitations. Keep your recovery code separate from backups. Losing both the Keychain access and the recovery code means losing access to the vault.

This is an early source release. Automated tests exercise encryption, failure paths, recovery, valuation and input validation. They are not an external security certification.

## License

MIT. See [LICENSE](LICENSE).
