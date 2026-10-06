import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@main
enum LocalAssistantEntry {
    @MainActor static func main() {
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
    func applicationDidFinishLaunching(_ notification: Notification) { HostController.shared.launch() }

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
                Button(host.canStart ? "Start" : "Stop") {
                    if host.canStart { host.launch() } else { host.stop() }
                }
                .disabled(host.phase == .stopping)
            }
            Text(host.modelLabel).font(.subheadline).textSelection(.enabled)
            if !host.notice.isEmpty {
                Text(host.notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Divider()
            HStack {
                Text("Source access").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Refresh") { host.refreshSources() }.disabled(host.checkingSources)
                Button("Connect") { host.refreshSources(connect: true) }.disabled(host.checkingSources)
            }
            if host.checkingSources { Text("Checking source access…").foregroundStyle(.secondary) }
            if host.sources.isEmpty {
                Text("Access has not been checked from this host yet. Connect sources to review macOS permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(host.sources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(source.name)
                            Spacer()
                            Text(source.ready ? "Available when checked" : "Needs access")
                                .foregroundStyle(source.ready ? Color.secondary : Color.orange)
                        }
                        Text(source.checkedAt, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                        if !source.ready { Text(source.detail).textSelection(.enabled) }
                    }
                    .font(.caption)
                }
            }
            Text("These are past observations. This app may need its own macOS access grants.")
                .font(.caption).foregroundStyle(.secondary)
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
        for key in ["NSAppleEventsUsageDescription", "NSContactsUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription", "NSPhotoLibraryUsageDescription"] {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
                throw HostFailure("Missing access description: \(key)")
            }
        }
        guard Bundle.main.bundleIdentifier == "org.localproactiveassistant.mac" else {
            throw HostFailure("Unexpected native app identity.")
        }
    }
}
