import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: GameEngine

    var body: some View {
        Group {
            switch engine.state.phase {
            case .menu:
                MenuView(engine: engine)
                    .transition(.opacity)
            default:
                GameBoardView(engine: engine)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: engine.state.phase)
    }
}
