# Security

## Local storage

Financial records, portfolio names, quantities, bank balances, API settings, imported statements and historical observations are encrypted together using CryptoKit AES-256-GCM. Authentication covers the vault ID and generation. Saves retain a verified previous encrypted generation and use atomic replacement under a process lock.

A random vault key is stored in this Mac’s non-synchronizing, device-only data-protection Keychain with user-presence access control. Unlock uses LocalAuthentication with Touch ID or the Mac password. The recovery code is a separate randomly generated 256-bit secret that wraps the vault key; the app does not retain the recovery code.

Production builds require a provisioned Keychain access group. Initial creation stores the protected key before publishing the first vault file. If an initial disk save fails before publication, its unpublished wrapper and key are removed so setup can retry. Access or provisioning errors remain distinct from a missing key and do not automatically send the user to recovery. The authenticated vault schema is unchanged.

After initial vault creation, onboarding progress is saved inside its encrypted settings, including the current step, selected asset types and unfinished price-source choices. Provider keys entered during setup receive the same encryption as the rest of the vault. These draft choices do not enable network sources until setup is completed; locking clears their plaintext session state. Completion removes the onboarding draft. Import drafts stay in memory, survive navigation between management pages, and are cleared when the vault locks.

The app stays unlocked across popover dismissal and locks after five minutes of app inactivity, or immediately on screen lock, sleep or session resignation. User interaction restarts the idle period; background source updates do not. Lock invalidates authentication, clears financial view state and cancels foreground refresh work. A session fence prevents an old operation from publishing into a later session. Unlocked vault plaintext and transient fetched provider responses exist in process memory; Swift does not guarantee immediate zeroization of every copy.

The sandbox allows outbound HTTPS and files explicitly selected by the user. There is no application server, analytics SDK or automatic cloud backup. OS backups may include the encrypted vault. FileVault is complementary protection for the Mac itself.

## Network

Networking is opt-in. In the standard build, the only app-requested hosts are `api.coingecko.com`, `api.frankfurter.dev` and `api.gold-api.com`. Redirects are refused. Sessions are ephemeral with no persistent cookies or URL cache. Response sizes and deadlines are bounded; prices, asset IDs, currencies and timestamps are validated before committing. Frankfurter v2 requests validate the returned base/quote pair and retain exact source decimals. Individual currency failures preserve successful observations; cancellation and failed vault writes publish none of the pending update.

The providers see requests and network metadata, including IP addresses. CoinGecko sees requested coin identifiers and its API key. Frankfurter sees currency codes and historical date ranges. Gold API sees metal symbols, date ranges and an optional history API key. No provider receives quantities, bank balances, account names, portfolio names, statements or vault keys.

The same process also performs networking; this release does not claim process separation. After a normal setup unlock, selected source identifiers, source switches, provider credentials, the vault's public inbox key and a dedicated signing key live in an app-specific Keychain configuration for background refresh. This configuration never contains the vault key or inbox private key. Background requests do not authenticate or decrypt the vault and cannot extend the inactivity deadline.

Each source's last successful background response is encrypted with a fresh AES-GCM key wrapped to the vault's public inbox key and signed with the dedicated signing key. Atomic mode-600 `.sealed` files contain only envelopes. A trusted signer stored inside the encrypted vault, its vault ID, signature and authenticated encryption are checked after normal unlock before observations are applied. Disabled sources and replayed packets are ignored; source timestamps remain intact. A failed source preserves its previous cache. Current observations refresh on a 15-minute target while running/awake; the app cannot refresh while quit or asleep. Historical catch-up and activity sync require unlock.

Historical fetches and their checkpoints remain inside the encrypted vault. Backfill uses dated quantities and source timestamps; publication gaps remain explicit. Metal quantities are fine grams, distinct from crypto token identifiers. Current metal prices need no account, but automatic historical catch-up requires the user's free Gold API key. Provider credentials are sent only to their designated host in request headers, never query strings. History and live data are committed together after validation; lock cancels preparation and fences stale results.

## Backups

Export produces a directory ending in `.uponlybackup`, containing ciphertext, the recovery wrapper and a checksummed manifest. Restore requires the recovery code and an empty destination. It refuses to overwrite an existing vault. Keep the code and backup separately: either alone is insufficient to decrypt the data.

Vault files are capped at 128 MiB. A save that would exceed that limit is refused without replacing the last saved vault. Save, export and restore share the same size limits so a successful export stays within the restore reader’s limits.

No financial files, API credentials, signing certificates, recovery codes or user containers belong in this repository. Production starts empty; only the separate preview target contains synthetic records.

## Limits

Encryption cannot protect information already visible to someone using an unlocked app, a compromised operating system, or malware with sufficient access to the running process. Keychain and Touch ID depend on macOS and hardware availability. Financial observations may be stale or incomplete; the interface labels those conditions.

Do not publish private financial data, keys or statements in an issue. A security report should describe the defect with synthetic examples only.

## Private Wise build

`UPONLY_PERSONAL` is an optional local compilation flag. The public app excludes the Wise credential reader, connector and setup UI. The private build uses a separate bundle identifier and vault directory. Its read-only API token, selected profile IDs and bootstrap artwork live in a local Keychain item, never in the app bundle or repository. The app does not write that token into the vault or backups.

Selected profile names and bootstrap artwork appear on the private welcome screen before vault unlock and stay loaded when the popover closes. Financial records and pending imports still clear when the vault locks.

Private Wise requests are GET-only to `api.wise.com`, with ephemeral sessions, no cookies/cache, no redirects and bounded response/pagination limits. Activity sync runs only while unlocked; current balances may prefetch into sealed cache while locked. Lock cancels foreground requests and fences pending results; no response from an earlier session can commit into a later one. Completed activities, linked profile identifiers and account artwork are stored only in the encrypted vault. A failed sync preserves the last saved document. Native balances come from the balance endpoint, not transaction sums. The activity feed may require user review for transfers; it is not a replacement for official statements.

Privacy mode is an encrypted, backward-compatible vault preference. It replaces displayed financial values and accessibility text with placeholders, masks native amount inputs, and hides chart tooltip/accessibility values while keeping trends and navigation usable. It does not lock the vault or conceal account names, dates, transaction descriptions, or file names. Toggle it with the eye button or Shift–Command–P. Touch ID uses Apple’s embedded authentication view; Mac-password authentication remains system-owned.

## Private accounting

Private accounting credentials and source mappings remain in a separate local Keychain item. Native requests use Google OAuth JWT exchange and read-only Sheets/Drive scopes, bounded responses and no redirects. Credential reads refuse authentication UI, so background work cannot prompt for a vault unlock. The service account's workbook permissions remain external to the app. Saved company results, effective ownership periods, source provenance and refresh warnings live in the encrypted vault (or sealed prefetch until unlock). Public builds exclude this connector and credential access.
