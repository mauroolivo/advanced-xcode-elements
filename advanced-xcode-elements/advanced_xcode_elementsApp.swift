//

import SwiftUI

enum Stage7MessageFactory {
    static func greeting(for name: String, punctuation: String) -> String {
        format("Hello, \(name)\(punctuation)")
    }

    private static func format(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@main
struct advanced_xcode_elementsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
