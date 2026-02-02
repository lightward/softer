import SwiftUI

@main
struct SofterApp: App {
    @State private var pendingShareURL: URL?

    var body: some Scene {
        WindowGroup {
            RootView(pendingShareURL: $pendingShareURL)
                .onOpenURL { url in
                    // Handle ckshare:// URLs for share acceptance
                    if url.scheme == "ckshare" {
                        pendingShareURL = url
                    }
                }
        }
    }
}
