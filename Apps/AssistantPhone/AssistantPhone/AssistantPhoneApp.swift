import PhoneSync
import SwiftUI
import UIKit

@main
struct AssistantPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    var body: some Scene { WindowGroup { AssistantView() } }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { await AssistantViewModel.shared.activate() }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void) {
        PhoneUploadClient.shared.backgroundCompletion = completionHandler
    }
}
