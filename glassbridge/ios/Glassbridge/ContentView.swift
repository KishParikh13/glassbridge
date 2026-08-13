import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = SessionCoordinator()

    var body: some View {
        LiveView(coordinator: coordinator, glasses: coordinator.glasses)
    }
}

#Preview { ContentView() }
