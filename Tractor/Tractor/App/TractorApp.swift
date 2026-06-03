import SwiftUI
import UIKit

final class OrientationLockedAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Self.requestPreferredLandscape()
    }

    static var supportedOrientations: UIInterfaceOrientationMask {
        .landscape
    }

    static func requestPreferredLandscape() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { scene in
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: supportedOrientations))
            }
    }
}

@main
struct TractorApp: App {
    @UIApplicationDelegateAdaptor(OrientationLockedAppDelegate.self) private var appDelegate
    @StateObject private var engine = GameEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .onAppear {
                    OrientationLockedAppDelegate.requestPreferredLandscape()
                }
        }
    }
}
