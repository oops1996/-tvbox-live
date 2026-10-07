import SwiftUI

@main
struct FamilyTVApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("家庭电视") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowStyle(.titleBar)
    }
}
