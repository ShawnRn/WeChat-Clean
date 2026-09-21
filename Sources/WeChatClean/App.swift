import SwiftUI

@main
struct WeChatCleanApp: App {
    var body: some Scene {
        Window("微信存储管理", id: "main") {
            MainView()
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {}
        }
    }
}
