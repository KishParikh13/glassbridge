import SwiftUI
import MWDATCore

@main
struct GlassbridgeApp: App {
    static private(set) var wearablesConfigured = false
    static private(set) var wearablesConfigureError: String? = nil

    init() {
        do {
            try Wearables.configure()
            Self.wearablesConfigured = true
        } catch {
            // Fails on simulator (no Meta AI infra) and on misconfigured Info.plist.
            // Non-fatal so the UI still renders; GlassesController surfaces the cause.
            Self.wearablesConfigureError = String(describing: error)
            print("Wearables.configure() failed: \(error). Glasses features disabled.")
        }

        #if DEBUG
        // Best-effort mock kit setup. We do NOT pretend Wearables.shared works —
        // MockDeviceKit is parallel test infrastructure; accessing Wearables.shared
        // when configure() failed fatals. SessionCoordinator's automated test path
        // bypasses Wearables and uses the mock image directly.
        if Self.wearablesConfigured {
            MockSetup.setupIfSimulatorDebug()
        } else {
            MockSetup.prepareStubImage()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
        }
    }
}
