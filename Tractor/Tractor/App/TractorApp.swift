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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = GameEngine()
    @StateObject private var adsManager = AdsManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(adsManager)
                .onAppear {
                    OrientationLockedAppDelegate.requestPreferredLandscape()
                }
                .task {
                    await adsManager.prepareForAds()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await adsManager.refreshAdFreeAccess() }
                }
        }
    }
}
