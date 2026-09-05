import SwiftUI

@main
struct UpOnlyApp: App {
    @State private var session = UpOnlySession()
    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!session.isFixture)) {
            UpOnlyPanel().environment(session)
        } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .accessibilityLabel("Up Only")
                .accessibilityIdentifier("UpOnlyStatusItem")
        }.menuBarExtraStyle(.window)
        Window("Up Only", id: "management") {
            UpOnlyManagement().environment(session)
        }.defaultSize(width: 680, height: 520)
        #if UPONLY_FIXTURE
        Window("Up Only Preview", id: "preview") {
            UpOnlyPanel().environment(session)
        }.defaultSize(width: 344, height: 470).windowResizability(.contentSize)
        #endif
    }
}
