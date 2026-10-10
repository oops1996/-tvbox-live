import SwiftUI

@main
struct FamilyTVApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("家庭电视", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 680)
                .onDisappear { if !model.playback.isDetached { model.playback.stop() } }
        }
        .windowStyle(.titleBar)
    }
}
