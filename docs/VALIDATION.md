# Menu-bar app validation

The completed source includes saved onboarding, bank/crypto/metal entry and bulk imports, personal and company performance, ownership-weighted net worth, compact menu-only navigation, automatic authentication and password fallback, background refresh, and shared privacy controls.

The current native validation uses Xcode on macOS 27 with separate synthetic public and private fixtures. The latest suites passed 161 private and 157 public tests (318 total), including encryption/recovery/fencing, ledger calculations, imports, missing data, timestamp compatibility and measured chart-axis spacing. The signed app retains the existing sandbox and protected Keychain access group.

Chart date labels use measured text widths, preserve timeline endpoints when they fit, and omit intermediate labels to maintain a minimum gap. Data points, hover targets and period selection remain independent of label density.

Dashboard tabs and detail-page Back/title headers sit above the shared time selector. Transactions use compact month groups with rounded surfaces, row dividers, aligned amounts and bordered edit controls. Native menu checks cover navigation order, light/dark layouts, transaction row spacing, and opening/closing inline transaction editing.

The empty Net worth state offers asset entry and, when newer values exist, a shortcut to the current period. Metals collections share the detail header and grouped holdings layout. The latest focused pass covers 22 native background renders and interactions across transactions, long descriptions, metals, portfolio updates and empty-period actions. The fixture capture resizes to the current page before rendering; it is compiled out of production. During iteration, checks are limited to affected screens, followed by one combined validation pass when the changes are complete.

The synthetic vault-unlock/dashboard benchmark previously improved from 14.2 seconds to about 0.40 seconds after timestamp-decoding and ledger optimizations. This benchmark uses synthetic authentication and in-memory file/key stores; it does not measure the real sensor or protected Keychain access.

Real unlock diagnostics are opt-in (`UPONLY_MEASURE_UNLOCK=1`). They record only elapsed phase timings, using the macOS authentication-success callback and completion of the first AppKit menu display. Physical monitor scan-out is outside the measurement. See the README for the diagnostic file location and privacy scope.

Build and visual evidence, source transfer hashes, recovery transcripts and local installation records are retained in the workspace's ignored `.context` directory. Financial data, credentials, private source mappings and personal profile artwork are local vault/Keychain configuration, not repository contents. Synthetic preview and source-verification switches compile out of the installed app.
