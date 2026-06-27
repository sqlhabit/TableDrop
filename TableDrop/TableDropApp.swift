import AppKit
import SwiftUI

@main
struct TableDropApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowMovableConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 420)
    }
}

private struct WindowMovableConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MovableWindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isMovableByWindowBackground = true
    }
}

private final class MovableWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isMovableByWindowBackground = true
    }
}
