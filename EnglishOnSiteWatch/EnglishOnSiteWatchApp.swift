import SwiftUI

@main
struct EnglishOnSiteWatchApp: App {
    @State private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(model)
                .task {
                    // Defer WCSession until UI is up — avoids launch kill on unpaired watch.
                    model.activate()
                }
        }
    }
}
