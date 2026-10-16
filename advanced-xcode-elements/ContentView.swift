//

import SwiftUI

#if STAGE6_CONCURRENCY_LAB
final class Stage6MutableBox {
    var value = 0
}

func stage6IsolationProbe() {
    let box = Stage6MutableBox()
    Task.detached {
        box.value += 1
    }
}
#endif

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
