import PhoneSync
import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    @State private var model = AssistantViewModel.shared
    @ObservedObject private var upload = PhoneUploadClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importingModel = false
    @State private var phoneConversationExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Chat in Messages", systemImage: "message.fill").font(.title2.bold())
                    Text("Text yourself in Messages. Your Mac replies while Local Assistant is running.")
                        .accessibilityIdentifier("messagesInstructions")
                    Text("This companion connects phone sources. You do not need it open to chat in Messages.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                macConnection
                phoneSources
                Section("Optional local chat") {
                    DisclosureGroup("Phone conversation", isExpanded: $phoneConversationExpanded) {
                        phoneConversation
                    }.accessibilityIdentifier("phoneConversationDisclosure")
                }
                if !model.notice.isEmpty { Section { Text(model.notice).font(.subheadline) } }
            }
            .navigationTitle("Phone companion")
            .task { await model.activate(); await model.checkPhoneModel() }
            .onOpenURL { model.receivePairing($0) }
            .fileImporter(isPresented: $importingModel, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): Task { await model.importPhoneModel(url) }
                case .failure(let error): model.notice = "Could not open model folder: \(error.localizedDescription)"
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.activate() } } }
            .alert("Pair with your Mac?", isPresented: Binding(get: { model.pendingPairing != nil }, set: { if !$0 { model.pendingPairing = nil } })) {
                Button("Pair") {
                    if let pairing = model.pendingPairing { Task { await model.confirmPairing(pairing) } }
                }
                Button("Cancel", role: .cancel) { model.pendingPairing = nil }
            } message: {
                if let pending = model.pendingPairing {
                    Text("\(pending.name)\nVerify code \(pending.verificationCode) matches your Mac.")
                }
            }
        }
    }

    private var macConnection: some View {
        Section("Mac connection") {
            if let pairing = upload.pairing {
                Label(pairing.name, systemImage: "desktopcomputer")
                Text(upload.status).font(.subheadline)
                if let date = upload.lastSynced {
                    Text("Last received by Mac: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if upload.pendingCount > 0 { Text("\(upload.pendingCount) updates queued on this phone.") }
                Button("Sync now") { Task { await model.sync(force: true) } }.disabled(model.busy)
                Button("Disconnect phone", role: .destructive) { Task { await model.disconnect() } }
            } else {
                Text("On your Mac, open the Local Assistant menu. Stop the assistant if it is running, then choose Pair iPhone. Scan the QR code, verify the matching code, then Start the assistant on your Mac.")
                    .accessibilityIdentifier("pairingInstructions")
                Text("Pair while both devices are on the same local network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var phoneSources: some View {
        Section("Phone sources") {
            if model.sleepEnabled {
                Toggle("Share sleep summaries", isOn: Binding(get: { model.sleepEnabled }, set: { enabled in
                    if !enabled { Task { await model.disableSleep() } }
                }))
            } else {
                Button("Enable sleep sharing") { Task { await model.enableSleep() } }
            }
            if model.activityEnabled {
                Toggle("Share activity summaries", isOn: Binding(get: { model.activityEnabled }, set: { enabled in
                    if !enabled { Task { await model.disableActivity() } }
                }))
            } else {
                Button("Enable activity sharing") { Task { await model.enableActivity() } }
            }
            if model.locationEnabled {
                Toggle("Share coarse location", isOn: Binding(get: { model.locationEnabled }, set: { enabled in
                    if !enabled { Task { await model.disableLocation() } }
                }))
            } else {
                Button("Enable coarse location sharing") { Task { await model.enableLocation() } }
            }
            Text("Share only enabled summaries with your paired Mac. Raw Health samples stay here. Location is a recent foreground fix rounded to about 1 km.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy)
    }

    private var phoneConversation: some View {
        Group {
            Text("Chat inside this app with Apple Intelligence or a small open model. Messages replies still come from your running Mac.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Phone model", selection: Binding(get: { model.phoneModelChoice }, set: { choice in
                Task { await model.selectPhoneModel(choice) }
            })) {
                ForEach(PhoneModelChoice.allCases) { choice in Text(choice.title).tag(choice) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("phoneModelPicker")
            .accessibilityValue(model.phoneModelChoice.title)
            .disabled(model.phoneBusy || model.phoneDownloading)
            Text(model.phoneModelChoice.detail).font(.caption).foregroundStyle(.secondary)
            if !model.phoneModelDetail.isEmpty {
                Text(model.phoneModelDetail).font(.caption).foregroundStyle(.secondary)
            }
            if model.phoneModelChoice.repository != nil, !model.phoneModelInstalled {
                Text("Download public weights once from Hugging Face. Your messages and source data stay here; later replies work offline.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Download model to this iPhone") { model.downloadPhoneModel() }
                    .accessibilityIdentifier("downloadPhoneModel")
                    .disabled(model.phoneDownloading || model.phoneBusy)
            }
            if model.phoneImporting {
                ProgressView("Copying model files")
            } else if model.phoneDownloading {
                ProgressView("Saving phone model", value: model.phoneDownloadProgress)
                Button("Cancel download") { model.cancelPhoneDownload() }
            }
            TextField("Message to phone model", text: Binding(get: { model.phoneQuestion }, set: { model.phoneQuestion = $0 }))
                .accessibilityIdentifier("phoneMessageField")
            TextField("Exact contact name (optional)", text: Binding(get: { model.phoneContactName }, set: { model.phoneContactName = $0 }))
                .accessibilityIdentifier("phoneContactField")
            Button("Ask on this iPhone") { Task { await model.askOnPhone() } }
                .accessibilityIdentifier("askPhoneButton")
                .disabled(model.phoneBusy || model.phoneDownloading || !model.phoneModelReady || model.phoneQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if model.phoneBusy { ProgressView("Preparing a local reply") }
            if !model.phoneAnswer.isEmpty { Text(model.phoneAnswer).textSelection(.enabled) }
            Button("New phone conversation") { Task { await model.newPhoneConversation() } }
                .disabled(model.phoneBusy || model.phoneDownloading)
            Button("Allow phone Calendar") { Task { await model.enablePhoneCalendar() } }
            Button("Allow phone Contacts") { Task { await model.enablePhoneContacts() } }
            Text("Enabled Health and coarse-location summaries are also available here. iOS does not expose your Messages to this companion.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Import my MLX model folder") { importingModel = true }
                .disabled(model.phoneBusy || model.phoneDownloading)
            if model.phoneModelInstalled {
                Button("Remove selected model", role: .destructive) { Task { await model.removePhoneModel() } }
                    .disabled(model.phoneBusy || model.phoneDownloading)
            }
        }
    }
}
