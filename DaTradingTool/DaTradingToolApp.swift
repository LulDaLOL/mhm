import SwiftUI

// Da Trading Tool for iPhone and iPad: the same page as the Chrome, desktop and Android versions (Web/index.html),
// full screen in a web view. See WebScreen.swift for how the page talks to the phone.
@main
struct DaTradingToolApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                WebScreen()
            }
            .preferredColorScheme(.dark)
        }
    }
}
