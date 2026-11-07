import SwiftUI

@main
struct ErhuApp: App {
    @State private var services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            ThemedRoot { appContent }
                .environment(services.library)
                .environment(services.player)
                .environment(services.actions)
                .environment(services.mixes)
                .environment(services.vybe)
                .environment(services.search)
                .environment(services.router)
                .environment(services.settings)
                .environment(services.sound)
                .environment(services.lyrics)
                .environment(services.transfer)
                .environment(services.fixTags)
                .environment(services.artwork)
                .environment(services.transitions)
                .preferredColorScheme(services.settings.colorScheme)
        }
    }

    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--erhu-interaction-probe=") }),
           let page = argument.split(separator: "=").last {
            InteractionProbeView(page: String(page))
        } else { RootView() }
        #else
        RootView()
        #endif
    }

}
