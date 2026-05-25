import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = SessionCoordinator()

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            LiveView(coordinator: coordinator, glasses: coordinator.glasses)
                .tabItem { Label("Live", systemImage: "camera.viewfinder") }
                .tag(SessionCoordinator.Tab.live)
            SetupView(coordinator: coordinator, glasses: coordinator.glasses)
                .tabItem { Label("Setup", systemImage: "checklist") }
                .tag(SessionCoordinator.Tab.setup)
            MoreView(coordinator: coordinator, glasses: coordinator.glasses, wake: coordinator.wake)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(SessionCoordinator.Tab.more)
        }
    }
}

#Preview { ContentView() }
