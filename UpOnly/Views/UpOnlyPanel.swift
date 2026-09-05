import SwiftUI

struct UpOnlyPanel: View {
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        Group {
            if session.state == .unlocked, let model = session.monthModel {
                if session.document?.settings.setupComplete != true { UpOnlySetup().id(session.sessionToken) }
                else { UpOnlyUnlockedPanel(model: model).id(session.sessionToken) }
            } else { UpOnlyLockView().id(session.sessionToken) }
        }
        .frame(width: 344)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { session.surfaceOpened() }
        .onDisappear { session.surfaceClosed() }
    }
}

struct UpOnlyLockView: View {
    @Environment(UpOnlySession.self) private var session
    @State private var recovery: RecoveryCode?
    @State private var confirmation = ""
    @State private var recoveryText = ""
    @State private var showRecovery = false
    @State private var showRestore = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text("Up Only").font(.system(size: 24, weight: .semibold))
            Text(session.state == .newVault ? "A private home for your finances." : "Your finances, kept on this Mac.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if let recovery, session.state == .newVault {
                Text("Save your recovery code somewhere safe, separately from your backup. It is the only way to recover without this Mac’s Keychain.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(recovery.canonical).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                TextField("Enter your saved recovery code", text: $confirmation, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3)
                Button("Create encrypted vault") {
                    Task { await session.create(recovery: recovery, confirmation: confirmation) }
                }.buttonStyle(.borderedProminent).disabled(session.isBusy || !recovery.matches(confirmation))
            } else if showRestore {
                SecureField("Recovery code for your backup", text: $recoveryText).textFieldStyle(.roundedBorder)
                Button("Choose encrypted backup…") { Task { await session.restoreBackup(code: recoveryText); recoveryText = "" } }
                    .disabled(session.isBusy || recoveryText.isEmpty)
                Button("Back") { showRestore = false; recoveryText = "" }
            } else if showRecovery || session.state == .recovery {
                SecureField("Recovery code", text: $recoveryText).textFieldStyle(.roundedBorder)
                Button("Recover vault") { Task { await session.recover(code: recoveryText); recoveryText = "" } }
                    .buttonStyle(.borderedProminent).disabled(session.isBusy || recoveryText.isEmpty)
                Button("Back") { showRecovery = false; recoveryText = "" }.buttonStyle(.plain)
            } else if session.state == .newVault {
                Button("Set up Up Only") { recovery = RecoveryCode.random() }.buttonStyle(.borderedProminent)
                Button("Restore an encrypted backup…") { showRestore = true }.buttonStyle(.plain).font(.system(size: 12))
            } else {
                Button { Task { await session.unlock() } } label: { Label("Unlock Up Only", systemImage: "touchid") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(session.isBusy)
                Text("Touch ID or your Mac password").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Use recovery code") { showRecovery = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let message = session.message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
            if session.isBusy { ProgressView().controlSize(.small) }
        }.padding(24)
        .accessibilityIdentifier("UpOnlyLocked")
    }
}

private struct UpOnlyUnlockedPanel: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.openWindow) private var openWindow
    var model: PopoverModel
    @State private var scope: ValuationScope = .allTracked
    @State private var range = "6M"
    @State private var detail: String?
    @State private var allMonths = false

    private var result: ValuationResult? {
        session.document.map { NetWorthCalculator.value(at: Date(), scope: scope, document: $0) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                destination("This month", value: 0)
                destination("Net worth", value: 1)
                Spacer(minLength: 0)
                Button { session.lock() } label: { Image(systemName: "lock").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Lock Up Only (⌘L)")
                    .keyboardShortcut("l", modifiers: .command).accessibilityLabel("Lock Up Only")
            }.padding(.top, 16).padding(.bottom, 20)
            if session.destination == 0 { monthContent }
            else { worthContent }
            Divider().padding(.top, 12)
            HStack {
                Text(session.isFixture ? "Preview · synthetic figures" : "Up Only · USD")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    session.managementSection = session.destination == 0 ? "Accounts" : "Portfolios"
                    openWindow(id: "management")
                } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Manage Up Only")
                    .accessibilityLabel("Manage Up Only").accessibilityIdentifier("ManageUpOnly")
            }.padding(.vertical, 11)
            if let message = session.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }.padding(.horizontal, 16)
        .frame(maxHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UpOnlyUnlocked")
        .sheet(item: Binding(get: { session.pendingStatement }, set: { session.pendingStatement = $0 })) { StatementReview(draft: $0) }
    }
    private func destination(_ title: String, value: Int) -> some View {
        Button { session.destination = value; detail = nil } label: {
            Text(title).font(.system(size: 12, weight: session.destination == value ? .semibold : .regular))
                .foregroundStyle(session.destination == value ? .primary : .secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(session.destination == value ? .isSelected : [])
    }
    private var monthContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(detail ?? model.month.title).font(.system(size: 13, weight: .medium))
                Spacer()
                if detail != nil {
                    Button("Back") { detail = nil }.buttonStyle(.plain).font(.system(size: 12))
                } else {
                    Button { model.step(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }.disabled(!model.canStepBack).accessibilityLabel("Previous month")
                    Button { model.step(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }.disabled(!model.canStepForward).accessibilityLabel("Next month")
                    Menu {
                        Button("Add statement…") { session.managementSection = "Accounts"; openWindow(id: "management"); session.choosingStatementAccount = true }
                        Button("Add entry…") { session.managementSection = "Entries"; openWindow(id: "management") }
                        if model.month < .current() { Button("Mark month reviewed") { model.markReviewed() } }
                        Toggle("Show all months", isOn: $allMonths)
                    } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Add financial information")
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            if let totals = model.state.totals {
                UpOnlyAmount(value: totals.net, signed: true, tint: totals.net < 0 ? Color(nsColor: .systemRed) : Color(red: 0.13, green: 0.51, blue: 0.39))
                    .padding(.top, 8)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.left").font(.system(size: 10))
                    Text(UpOnlyFormat.money(totals.moneyIn) + " in")
                    Text("·").padding(.horizontal, 3)
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                    Text(UpOnlyFormat.money(totals.moneyOut) + " out")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            } else {
                Text("—").font(.system(size: 40, weight: .semibold)).padding(.top, 8)
            }
            Text(monthStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).padding(.top, 5)
            if let detail {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(detailRows(detail).enumerated()), id: \.offset) { _, row in
                            UpOnlyValueRow(label: row.0, value: UpOnlyFormat.money(row.1))
                        }
                    }
                }.frame(height: 220).padding(.top, 14)
            } else {
                UpOnlyChart(points: monthPoints, includesZero: true, selected: model.month.description, tint: Color(red: 0.13, green: 0.51, blue: 0.39)) { id in
                    if let month = MonthKey(id) { model.select(month) }
                }.padding(.top, 22)
                if let totals = model.state.totals {
                    VStack(spacing: 0) {
                        if totals.otherBusiness != 0 { monthRow("Business", value: totals.otherBusiness) }
                        monthRow("Paid in", value: totals.personalIncome)
                        monthRow("Spent", value: -totals.personalSpend)
                    }.padding(.top, 12)
                } else {
                    Button("Add your first account or entry") { openWindow(id: "management") }
                        .buttonStyle(.plain).font(.system(size: 12)).padding(.vertical, 18)
                }
            }
        }
    }
    private var monthStatus: String {
        var parts = [model.month == .current() ? "Month to date" : "Monthly result"]
        if model.state.isEstimated { parts.append("Provisional") }
        if let waiting = model.state.waitingCaption { parts.append(waiting) }
        return parts.joined(separator: " · ")
    }
    private var monthPoints: [UpOnlyChartPoint] {
        Array(model.history.suffix(allMonths ? model.history.count : 12)).map {
            UpOnlyChartPoint(id: $0.month.description, label: String($0.month.shortName.prefix(3)), value: $0.net, provisional: !$0.settled)
        }
    }
    private func monthRow(_ label: String, value: Decimal) -> some View {
        Button { detail = label } label: { UpOnlyValueRow(label: label, value: UpOnlyFormat.money(value), chevron: true) }
            .buttonStyle(.plain)
    }
    private func detailRows(_ title: String) -> [(String, Decimal)] {
        switch title {
        case "Paid in": return model.breakdown(.income).map { ($0.label, $0.amount) }
        case "Spent": return model.breakdown(.expense).map { ($0.label, -$0.amount) }
        default: return (session.document?.entries ?? []).filter { $0.month == model.month.description && $0.kind != .transfer && ($0.bucket == .otherBusiness || $0.bucket == .businessCost) }.compactMap { entry in
            guard let doc = session.document, let rate = MonthlyLedger.rate(currency: entry.currency, month: model.month, document: doc), let amount = try? MoneyInput.multiply(entry.amount, rate) else { return nil }
            return (entry.label, entry.kind == .expense ? -amount : amount)
        }
        }
    }
    private var worthContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu(scopeTitle) {
                    Button("All accounts") { scope = .allTracked }
                    Button("Bank balances") { scope = .banks }
                    ForEach(session.document?.portfolios.filter { !$0.isArchived } ?? []) { p in
                        Button(p.name) { scope = .portfolio(p.id) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text("USD").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let result, !result.isUnavailable, let value = result.total ?? result.lastComplete?.value {
                UpOnlyAmount(value: value).padding(.top, 8)
            } else { Text("—").font(.system(size: 40, weight: .semibold)).padding(.top, 8) }
            Text(worthCaption).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 5)
            HStack(spacing: 16) {
                ForEach(["1M", "6M", "1Y", "All"], id: \.self) { item in
                    Button { range = item } label: {
                        Text(item).font(.system(size: 11, weight: range == item ? .semibold : .regular))
                            .foregroundStyle(range == item ? .primary : .secondary)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.top, 18).padding(.bottom, 14)
            UpOnlyChart(points: worthPoints, tint: Color(red: 0.29, green: 0.39, blue: 0.67))
            ScrollView {
                VStack(spacing: 0) {
                    if case .allTracked = scope {
                        worthRow("Bank balances", scope: .banks)
                        ForEach(session.document?.portfolios.filter { !$0.isArchived } ?? []) { p in worthRow(p.name, scope: .portfolio(p.id)) }
                    } else {
                        ForEach(result?.components ?? [], id: \.id) { component in
                            VStack(alignment: .leading, spacing: 1) {
                                UpOnlyValueRow(label: component.label, value: component.usdValue.map { UpOnlyFormat.money($0.value) } ?? "Needs update")
                                Text(component.nativeAmount.map { UpOnlyFormat.quantity($0.value) + (component.kind == .bank ? " " + component.currency : " coins") } ?? "No observation")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 5)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 112).padding(.top, 12)
        }
    }
    private var scopeTitle: String {
        switch scope {
        case .allTracked: "All accounts"
        case .banks: "Bank balances"
        case .portfolio(let id): session.document?.portfolio(id: id)?.name ?? "Portfolio"
        }
    }
    private func worthRow(_ name: String, scope: ValuationScope) -> some View {
        let valuation = session.document.map { NetWorthCalculator.value(at: Date(), scope: scope, document: $0) }
        return Button { self.scope = scope } label: {
            UpOnlyValueRow(label: name, value: valuation?.total.map(UpOnlyFormat.money) ?? "Needs update", chevron: true)
        }.buttonStyle(.plain)
    }
    private var worthCaption: String {
        guard let result else { return "Add a bank balance or your first portfolio" }
        if result.isUnavailable { return "Add a bank balance or your first portfolio" }
        if result.total == nil {
            if let last = result.lastComplete { return "Needs update · Last complete " + last.at.formatted(date: .abbreviated, time: .omitted) }
            return "Needs update · Some balances or prices are missing"
        }
        if !result.stale.isEmpty { return "Last-known values · Some sources need an update" }
        if let doc = session.document, let first = visibleSamples.first {
            let old = NetWorthCalculator.value(at: first.computedAt, scope: scope, document: doc)
            if let change = NetWorthCalculator.change(from: old, to: result) {
                return (change.amount > 0 ? "+" : "") + UpOnlyFormat.money(change.amount) + " change · " + range
            }
        }
        return "Your tracked balances, together"
    }
    private var visibleSamples: [DailyValuation] {
        let cutoff: Date = switch range {
        case "1M": Date().addingTimeInterval(-30 * 86400)
        case "6M": Date().addingTimeInterval(-183 * 86400)
        case "1Y": Date().addingTimeInterval(-365 * 86400)
        default: .distantPast
        }
        return (session.document?.dailyValuations ?? []).filter { $0.scope == scope && $0.computedAt >= cutoff }
            .sorted { $0.utcDay < $1.utcDay }
    }
    private var worthPoints: [UpOnlyChartPoint] {
        let samples = visibleSamples
        guard let first = samples.first, let last = samples.last else { return [] }
        var byDay: [Date: DailyValuation] = [:]
        for sample in samples { byDay[UTCDay.start(of: sample.utcDay)] = sample }
        var points: [UpOnlyChartPoint] = []
        var day = UTCDay.start(of: first.utcDay)
        let end = UTCDay.start(of: last.utcDay)
        while day <= end && points.count < 10000 {
            let sample = byDay[day]
            points.append(UpOnlyChartPoint(id: String(day.timeIntervalSince1970), label: UpOnlyFormat.utcDay(day), value: sample?.isComplete == true ? sample?.total?.value : nil))
            day = day.addingTimeInterval(86400)
        }
        return points
    }
}

struct UpOnlyAmount: View {
    var value: Decimal
    var signed = false
    var tint: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text((value < 0 ? "−" : signed && value > 0 ? "+" : "") + "$")
                .font(.system(size: 24, weight: .medium))
            Text(UpOnlyFormat.money(abs(value)).replacingOccurrences(of: "$", with: ""))
                .font(.system(size: 40, weight: .semibold).monospacedDigit()).tracking(-1.3)
        }.foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.75)
            .accessibilityElement(children: .ignore).accessibilityLabel(UpOnlyFormat.money(value))
    }
}

struct UpOnlyValueRow: View {
    var label: String
    var value: String
    var chevron = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(.primary).lineLimit(1)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
        }.font(.system(size: 13)).frame(minHeight: 28).contentShape(Rectangle())
    }
}
