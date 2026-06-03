import Foundation
import Combine

enum ConnectionState: Equatable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case error(String)
}

@MainActor
final class OrbState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var connection: ConnectionState = .idle
    @Published var audioLevel: Float = 0    // 0...1 from input mic
    @Published var outputLevel: Float = 0   // 0...1 from playback
    @Published var lastTranscript: String = ""
    @Published var aiControlling: Bool = false  // AI is synthesizing mouse/keyboard input
    @Published var activeTool: String? = nil    // e.g. "looking at screen", "clicking"
    @Published var sessionCost: Double = 0      // estimated USD spent this session
}
