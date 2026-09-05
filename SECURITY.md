# Security

## Local storage

Financial records, portfolio names, quantities, bank balances, API settings, imported statements and historical observations are encrypted together using CryptoKit AES-256-GCM. Authentication covers the vault ID and generation. Saves retain a verified previous encrypted generation and use atomic replacement under a process lock.

A random vault key is stored in this Mac’s non-synchronizing, device-only data-protection Keychain with user-presence access control. Unlock uses LocalAuthentication with Touch ID or the Mac password. The recovery code is a separate randomly generated 256-bit secret that wraps the vault key; the app does not retain the recovery code.

The app locks when the last finance surface closes, after five minutes of inactivity, and on screen lock, sleep or session resignation. Lock invalidates authentication, clears financial view state and cancels refresh work. A session fence prevents an old operation from publishing into a later session. Plaintext exists in process memory while unlocked; Swift does not guarantee immediate zeroization of every copy.

The sandbox allows outbound HTTPS and files explicitly selected by the user. There is no application server, analytics SDK or automatic cloud backup. OS backups may include the encrypted vault. FileVault is complementary protection for the Mac itself.

## Network

Networking is opt-in. The only app-requested hosts are `api.coingecko.com` and `api.frankfurter.dev`. Redirects are refused. Sessions are ephemeral with no persistent cookies or URL cache. Response sizes and deadlines are bounded; prices, asset IDs, currencies and timestamps are validated before committing.

The providers see requests and network metadata, including IP addresses. CoinGecko sees requested coin identifiers and its API key. Frankfurter sees currency codes. Neither receives quantities, bank balances, account names, portfolio names, statements or vault keys.

The encrypted process also performs these requests. This release does not claim process separation between the UI and networking. It fetches only while unlocked; there is no background collector with access to a closed vault.

## Backups

Export produces a directory ending in `.uponlybackup`, containing ciphertext, the recovery wrapper and a checksummed manifest. Restore requires the recovery code and an empty destination. It refuses to overwrite an existing vault. Keep the code and backup separately: either alone is insufficient to decrypt the data.

Vault files are capped at 128 MiB. A save that would exceed that limit is refused without replacing the last saved vault. Save, export and restore share the same size limits so a successful export stays within the restore reader’s limits.

No financial files, API credentials, signing certificates, recovery codes or user containers belong in this repository. Production starts empty; only the separate preview target contains synthetic records.

## Limits

Encryption cannot protect information already visible to someone using an unlocked app, a compromised operating system, or malware with sufficient access to the running process. Keychain and Touch ID depend on macOS and hardware availability. Financial observations may be stale or incomplete; the interface labels those conditions.

Do not publish private financial data, keys or statements in an issue. A security report should describe the defect with synthetic examples only.
