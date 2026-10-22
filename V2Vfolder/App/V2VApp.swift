import SwiftData
import SwiftUI

@main
struct V2VApp: App {
    @State private var dependencies = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            ConversationView(viewModel: dependencies.conversation, historyViewModel: dependencies.history)
        }
        .modelContainer(dependencies.modelContainer)
    }
}
