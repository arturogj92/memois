import SwiftUI

@main
struct MemoisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Memois") {
            MainWindowView(model: appDelegate.model, settings: appDelegate.model.settings)
                .frame(minWidth: 620, minHeight: 720)
        }
        .defaultPosition(.center)
        .defaultSize(width: 780, height: 760)
    }
}
