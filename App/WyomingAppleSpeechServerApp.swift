import SwiftUI

@main
struct WyomingAppleSpeechServerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Wyoming Apple Speech Server", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 700)
        }
        .defaultSize(width: 1060, height: 760)
    }
}
