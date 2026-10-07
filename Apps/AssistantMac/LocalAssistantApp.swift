import AppKit
import Carbon
import Foundation
import ServiceManagement
import SwiftUI

@main
enum LocalAssistantEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--check-payload") {
            do {
                try PayloadCheck.run()
                print("Native app payload valid.")
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--check-login-startup") {
            let service = SMAppService.mainApp
            let original = service.status
            if original == .enabled || original == .requiresApproval {
                print("Login registration already exists (status \(original.rawValue)); it was preserved. A physical login/reply test is still required.")
                return
            }
            do {
                try service.register()
                let registered = service.status
                // This probe must restore an initially disabled registration.
                try await service.unregister()
                let restored = service.status
                guard registered == .enabled || registered == .requiresApproval,
                      restored == .notRegistered else {
                    throw HostFailure("Unexpected login registration states: registered \(registered.rawValue), restored \(restored.rawValue). Inspect Login Items before continuing.")
                }
                print("Login registration round trip passed (registered \(registered.rawValue), restored \(restored.rawValue)). Startup remains off; physical login and phone delivery are unverified.")
            } catch {
                if service.status == .enabled || service.status == .requiresApproval {
                    do { try await service.unregister() }
                    catch { print("Could not restore disabled login startup: \(error). Inspect Login Items.") }
                }
                try? FileHandle.standardError.write(contentsOf: Data("Login registration check failed: \(error)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--login-status") {
            switch SMAppService.mainApp.status {
            case .enabled: print("Login startup: enabled. Starts at the next login; a physical login test is still required.")
            case .requiresApproval: print("Login startup: requires approval in System Settings > General > Login Items & Extensions.")
            case .notRegistered: print("Login startup: not registered. Enable Start at login in the Local Assistant menu.")
            case .notFound:
                print("Login startup: Service Management could not find this login service. Open the installed app and check Start at login.")
                exit(1)
            @unknown default:
                print("Login startup: unknown status.")
                exit(1)
            }
            return
        }
        LocalAssistantApplication.main()
    }
}

@MainActor
struct LocalAssistantApplication: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate
    @StateObject private var host = HostController.shared

    var body: some Scene {
        MenuBarExtra("Local Assistant", systemImage: "bubble.left.and.text.bubble.right") {
            HostPanel(host: host)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private var controlWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        HostController.shared.launch()
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !loginLaunch { showControls() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    private func showControls() {
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Local Assistant"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HostPanel(host: HostController.shared))
            window.center()
            controlWindow = window
        }
        controlWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let host = HostController.shared
        host.stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@MainActor
struct HostPanel: View {
    @ObservedObject var host: HostController
    @State private var showCoverage = false
    @State private var showActivity = false
    @State private var showFolders = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local Assistant").font(.headline)
                        Text(host.phase.rawValue).foregroundStyle(host.phase == .running ? Color.green : Color.secondary)
                    }
                    Spacer()
                    Button(host.isActive ? "Stop" : "Start") {
                        if host.isActive { host.stop() } else { host.launch() }
                    }
                    .disabled(host.phase == .stopping || host.pairingPhone)
                }
                Text(host.modelLabel).font(.subheadline).textSelection(.enabled)
                if !host.notice.isEmpty {
                    Text(host.notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Divider()
                HStack {
                    Text("iPhone context").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(host.pairingPhone ? "Pairing…" : "Pair iPhone") { host.pairPhone() }
                        .disabled(!host.canPairPhone)
                    if host.pairingPhone { Button("Cancel") { host.stop() } }
                }
                if !host.phonePairingResult.isEmpty {
                    Text(host.phonePairingResult).font(.caption).textSelection(.enabled)
                }
                Text("Stop the host before pairing the iPhone companion. Scan and verify on the same local network, then Start to sync phone context.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Source access").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Refresh") { host.refreshSources() }.disabled(host.checkingSources || host.pairingPhone)
                    Button("Connect") { host.refreshSources(connect: true) }.disabled(host.checkingSources || host.pairingPhone)
                }
                if host.checkingSources { Text("Checking source access…").foregroundStyle(.secondary) }
                if host.sources.isEmpty {
                    Text("Connect sources to grant access and see their status.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(host.sources) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(source.name)
                                Spacer()
                                Text(source.ready ? "Available" : "Needs access")
                                    .foregroundStyle(source.ready ? Color.secondary : Color.orange)
                            }
                            Text(source.checkedAt, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                            if !source.ready { Text(source.detail).textSelection(.enabled) }
                        }
                        .font(.caption)
                    }
                }
                DisclosureGroup("Indexed coverage", isExpanded: $showCoverage) {
                    Text(host.coverage).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("Extra folders", isExpanded: $showFolders) {
                    Text("Stop the host to change additional permitted folders. Supported files are read only when relevant to a question.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(host.readRoots, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { host.removeReadFolder(path) }.disabled(host.isActive)
                        }
                    }
                    Button("Add folder") { host.chooseReadFolder() }.disabled(host.isActive)
                }
                DisclosureGroup("Recent activity", isExpanded: $showActivity) {
                    ScrollView {
                        Text(host.recentLines.isEmpty ? "No activity in this app session." : host.recentLines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 130)
                    Button("Open log folder") { host.openLogs() }
                }
                Divider()
                Toggle("Start at login", isOn: Binding(get: { host.loginEnabled }, set: { host.setLoginEnabled($0) }))
                Text(host.loginDetail).font(.caption).foregroundStyle(.secondary)
                if host.loginDetail.contains("Approve") {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                HStack {
                    Button("Access settings") { host.openAccessSettings() }
                    Button("Setup guide") { host.openSetupGuide() }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                Text("This Mac must remain awake and online. Closing the lid can interrupt replies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(width: 440, height: 650)
        .onAppear { host.refreshSavedState(); host.refreshLoginStatus() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { host.refreshSavedState(); host.refreshLoginStatus() }
        }
    }
}

enum PayloadCheck {
    static func run() throws {
        guard let resources = Bundle.main.resourceURL else { throw HostFailure("The app resources are missing.") }
        for relative in ["bin/assistantctl", "bin/imsg", "Models/LocalAssistantModel.app/Contents/MacOS/assistant-model-worker"] {
            let file = resources.appendingPathComponent("Runtime").appendingPathComponent(relative)
            guard FileManager.default.isExecutableFile(atPath: file.path) else {
                throw HostFailure("Missing executable payload: \(relative)")
            }
        }
        for key in ["NSAppleEventsUsageDescription", "NSContactsUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription", "NSPhotoLibraryUsageDescription", "NSLocalNetworkUsageDescription"] {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
                throw HostFailure("Missing access description: \(key)")
            }
        }
        guard Bundle.main.bundleIdentifier == "org.localproactiveassistant.mac" else {
            throw HostFailure("Unexpected native app identity.")
        }
    }
}
