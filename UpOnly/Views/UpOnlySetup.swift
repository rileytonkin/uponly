import SwiftUI

struct UpOnlySetup: View {
    @Environment(UpOnlySession.self) private var session
    @State private var step = 0
    @State private var prices = false
    @State private var fx = false
    @State private var key = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: step == 0 ? "checkmark.shield" : "chart.line.uptrend.xyaxis")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(step == 0 ? "Your space. Your numbers." : "Keep prices up to date.")
                .font(.system(size: 24, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if step == 0 {
                Text("Your encrypted vault is ready. Start with a bank account, a crypto portfolio, or your monthly income and spending. You can add the rest whenever you like.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text("Everything starts empty. No sign-up, no tracking, no cloud account.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Continue") { step = 1 }.buttonStyle(.borderedProminent)
            } else {
                Toggle("Automatic crypto prices", isOn: $prices)
                Text("CoinGecko receives coin IDs and your IP address. Your quantities and portfolio names stay on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if prices {
                    SecureField("CoinGecko Demo API key", text: $key).textFieldStyle(.roundedBorder)
                    Link("Get a free Demo API key", destination: URL(string: "https://www.coingecko.com/en/api/pricing")!).font(.system(size: 12))
                }
                Toggle("Automatic currency conversion", isOn: $fx)
                Text("Frankfurter receives currency codes and your IP address. No balances are sent. Totals are displayed in USD.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Prices refresh while the vault is open. Missing or older observations are labelled. You can change this in Sources.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Back") { step = 0 }
                    Spacer()
                    Button("Start with an empty vault") { Task { await finish() } }
                        .buttonStyle(.borderedProminent).disabled(session.isBusy || (prices && key.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
    }
    private func finish() async {
        do {
            try await session.saveSources(prices: prices, fx: fx, key: key)
            try await session.mutate { $0.settings.setupComplete = true }
            key = ""
        } catch { self.error = "Setup could not be saved. Please try again." }
    }
}

struct UpOnlySources: View {
    @Environment(UpOnlySession.self) private var session
    @State private var prices = false
    @State private var fx = false
    @State private var key = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Automatic crypto prices", isOn: $prices)
            Text("CoinGecko receives coin identifiers, your API key and IP address. Quantities, portfolio names and balances are never sent.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("CoinGecko Demo API key", text: $key).textFieldStyle(.roundedBorder)
            Link("Get a CoinGecko Demo API key", destination: URL(string: "https://www.coingecko.com/en/api/pricing")!)
            Divider()
            Toggle("Automatic exchange rates", isOn: $fx)
            Text("Frankfurter receives currency codes and your IP address. Daily reference rates convert balances to USD. Historical entries need a rate dated near the end of their month.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Save source settings") { Task {
                do { try await session.saveSources(prices: prices, fx: fx, key: key); message = "Source settings saved." }
                catch { message = "Settings could not be saved. Check the API key and try again." }
            } }.disabled(session.isBusy || (prices && key.isEmpty))
            Button(session.refreshing ? "Refreshing…" : "Refresh now") { Task { await session.refreshPrices() } }.disabled(session.refreshing)
            if let status = session.sourceMessage ?? message { Text(status).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("Bank balances are entered manually. Import statements to track monthly income and spending. Wallets and exchanges are never connected.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Automatic requests run every 15 minutes while unlocked. Locking stops refreshes and clears the financial views.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            if let settings = session.document?.settings { prices = settings.automaticPrices; fx = settings.automaticFX; key = settings.coinGeckoKey }
        }
    }
}
