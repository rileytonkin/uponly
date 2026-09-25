# Bank sync for everyone: research and plan

Checked 2026-09-24. Prices marked "quote" aren't published. Anything uncertain is marked so. This is a product plan,
not legal advice.

## The rule we're designing to

People pick their bank and sign in with the bank. They never paste an API key or token. Up Only provides the
connection. Bank data is stored only on the user's Mac, encrypted in the vault as today.

## What that means, in one paragraph

Big banks everywhere only open their data to licensed firms: a PSD2 account-information provider in the EU/UK, a CDR
recipient in Australia, an Open Finance institution in Brazil, and so on. So a public app reaches them through an
aggregator that holds the licence, and Up Only signs a contract with it. Every aggregator gives Up Only a secret that
can't ship inside a Mac app. So Up Only needs one small server of its own, the **relay**. The relay holds those
secrets and checks that the caller is a genuine Up Only install (and, if sync is paid, a subscriber). Where the
aggregator allows it, the relay hands the Mac a token for that one user, and the Mac then fetches data straight from
the aggregator. Otherwise the relay forwards the data without keeping or logging it. The rare exceptions that need no
relay at all are marked below.

## Recommended providers by region

| Region | First choice | Why | Relay | Cost to Up Only |
|---|---|---|---|---|
| **US** | **Plaid** | Most banks, including investments (Schwab, Fidelity, Vanguard); hosted sign-in page | Forwards data (Plaid's tokens must stay server-side) | Free trial for 10 live connections, then pay-as-you-go per connection; prices shown only in Plaid's dashboard |
| US (cheaper second) | **Teller** | Published prices; its tokens are useless without Up Only's certificate, so they can stay on the Mac | Forwards data (mTLS) | 100 live connections free, then $0.30 per connection a month for transactions, $0.10 per balance call |
| **Canada** | Plaid (same integration) | Turning on another country in Plaid | Same | Same |
| **UK + EU** | **Enable Banking** (or **Tink** / **finAPI**) | 2,700+ banks in 30 countries including the UK; unlicensed apps can go live on its licence after a contract and business verification (KYB) | Enable Banking: forwards data (its token covers the whole app). Tink and finAPI: can mint a token for one user, so the Mac fetches directly | Enable Banking: volume-based with a monthly minimum (quote). finAPI publishes €60/month up to 200 users, €300 up to 1,000 |
| **Germany** (bonus) | **FinTS**, direct | The Mac talks to the bank itself. Registering the product with the Deutsche Kreditwirtschaft is free. Covers Sparkassen, Volksbanken, Deutsche Bank, Commerzbank, ING-DiBa, DKB, comdirect and others (not N26, Revolut or Trade Republic). This is how MoneyMoney works | **None** | Free |
| **Brazil** | **Pluggy** (Belvo second) | Regulated Open Finance: the user approves in their bank's app. Covers Nubank, Itaú, Bradesco, BB, Caixa, Santander, Inter, C6, BTG, XP, Mercado Pago, PicPay | Forwards data (may be able to mint for balances; to confirm) | From R$2,500/month (Belvo from US$1,000/month) |
| **Australia** | **Fiskil** as a CDR representative (**Basiq** second) | Up Only signs up as a CDR representative, the lightest role. Fiskil uses official CDR connections only, and a personal-finance app (Lucie Money) went live this way in Aug 2026. CommBank, Westpac, NAB, ANZ, Macquarie, ING, Up, Ubank, Revolut and Wise are all CDR data holders. Users re-consent every 12 months | Forwards data; hosted in Australia (Privacy Safeguard 8). Yodlee's per-user tokens would let the Mac fetch directly, if it will serve a small representative | Fiskil: quote. Basiq: $0.50 per user a month plus a platform fee, 12-month minimum |
| **New Zealand** | **Akahu** | Accredited intermediary, so Up Only needs no accreditation of its own. Covers the big five banks and KiwiSaver | More than a relay: Akahu requires Up Only user sign-in and user tokens kept on the server | NZ$0.50–2.50 per user a month |
| **Japan** | **Moneytree LINK** | 1,200+ personal bank accounts; PKCE sign-in with a documented no-backend setup | **None** | Quote |
| HK, SG, MY, PH, ID | Finverse (pilot) | Only 3–6 major retail banks per market; US$0.50 per connected account plus a monthly minimum | Mints tokens, probably | Quote for the minimum |
| Chile | wait (Fintoc until then) | The regulated system starts July 2027 | | |
| Colombia | wait | Mandatory open finance was decreed April 2026; standards are still to come | | |
| Mexico, Argentina, Peru | skip for now | No regulated APIs; only aggregators that take the user's bank password | | |
| India, Korea, Thailand | not possible | Only licensed local firms may receive the data | | |

Banks' own APIs don't help a public app. Monzo, Starling, Revolut, N26, Wise, Mercury and Schwab all limit personal
tokens to your own account, and their OAuth is for licensed firms or approved partners. The exceptions are bunq
(OAuth anyone can register for, but it needs an HTTPS redirect and bunq's API plan) and Mercury (OAuth for approved
apps, public clients allowed). The current Wise integration uses a personal token, so it stays a private-build
feature.

## Architecture

1. **One sync layer in the app.** Each provider is an adapter behind one interface: list institutions, start a
   sign-in, finish it, fetch accounts, balances and transactions, and report when consent expires. The Add flow's
   bank list (the new catalog) shows "Connect" for banks a provider covers in the user's country, and falls back to
   typed balances and CSV everywhere else.
2. **Sign-in** uses `ASWebAuthenticationSession` (a system browser sheet, which also lets the bank's own app open for
   approval). The callback is an HTTPS link on Up Only's domain (Associated Domains, macOS 14.4+) or a
   custom scheme where the provider allows one.
3. **The relay:** stateless, e.g. a Cloudflare Worker. Its only jobs:
   - hold provider secrets;
   - check app attestation and the subscription (otherwise anyone could run up the per-connection bill);
   - mint per-user tokens where possible, else forward calls without storing or logging them.
   - Tokens are kept on the Mac, encrypted; the Moneydance+ model keeps them wrapped under a key only the Mac holds.
4. **Consent renewal:** EU banks ask for re-authentication every 180 days; UK apps reconfirm every 90 days. The app
   shows "Reconnect" on the account a week before.
5. **Paid feature.** Every consumer app with bank sync charges for it (Monarch, Copilot, YNAB, Banktivity: about
   $95–$109 a year), because each connection costs money.

## Order of work

1. Company entity, privacy policy and terms (every provider's KYB asks for them). Pick the relay host and domain.
2. US via Plaid (the biggest single market, and a free trial to build against).
3. UK + EU via Enable Banking, and Germany via FinTS. FinTS needs no contract, only product registration.
4. Brazil via Pluggy, Australia via Fiskil (or Basiq), New Zealand via Akahu, Japan via Moneytree.
5. Keep CSV/statement import and typed balances as the universal fallback.

## Questions for providers and counsel

- Plaid: per-connection prices after the trial; whether the hosted sign-in page works in a macOS `ASWebAuthenticationSession`.
- Enable Banking: its monthly minimum and whether custom-scheme redirects are allowed. Tink: pricing for new
  customers, and whether a Mac app may use per-user tokens directly.
- Pluggy: pricing per connection and whether a foreign company can sign.
- Moneytree: pricing, and whether a foreign company needs its own Japanese registration.
- Fiskil and Basiq: prices and representative contract terms. A representative can have only one principal.
- Counsel: GDPR/LGPD role of a pass-through relay, the FTC Safeguards Rule in the US, whether CDR data kept on the
  user's Mac counts as "disclosed to the consumer" in Australia, and consumer-facing terms for each region.
