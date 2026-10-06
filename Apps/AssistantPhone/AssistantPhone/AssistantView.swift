import PhoneSync
import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    @State private var model = AssistantViewModel.shared
    @ObservedObject private var upload = PhoneUploadClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importingModel = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Chat in Messages", systemImage: "message.fill").font(.title2.bold())
                    Text("Use your private self-chat in Messages. Your Mac answers there while the assistant is running.")
                        .accessibilityIdentifier("messagesInstructions")
                    Text("This companion connects phone sources. You do not need it open to chat.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Optional: ask this iPhone locally") {
                    Text("Use Apple Intelligence or a small open model while this app is open. The phone can use Calendar, Contacts, Health summaries and coarse location you allow. iOS does not expose Messages to this app; iMessage answers still come from your running Mac.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker("Phone model", selection: Binding(get: { model.phoneModelChoice }, set: { choice in
                        Task { await model.selectPhoneModel(choice) }
                    })) {
                        ForEach(PhoneModelChoice.allCases) { choice in Text(choice.title).tag(choice) }
                    }.accessibilityIdentifier("phoneModelPicker")
                        .disabled(model.phoneBusy || model.phoneDownloading)
                    Text(model.phoneModelChoice.detail).font(.caption).foregroundStyle(.secondary)
                    if model.phoneModelChoice.repository != nil, !model.phoneModelInstalled {
                        Text("Download public weights once from Hugging Face. Only model files are requested; your messages and source data stay here. After download, answering works offline.")
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
                    Button("Import my MLX model folder") { importingModel = true }
                        .disabled(model.phoneBusy || model.phoneDownloading)
                    if model.phoneModelInstalled {
                        Button("Remove selected model", role: .destructive) { Task { await model.removePhoneModel() } }
                            .disabled(model.phoneBusy || model.phoneDownloading)
                    }
                    if !model.phoneModelDetail.isEmpty {
                        Text(model.phoneModelDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Message to phone model", text: Binding(
                        get: { model.phoneQuestion },
                        set: { model.phoneQuestion = $0 }
                    ))
                    TextField("Exact contact name (optional)", text: Binding(
                        get: { model.phoneContactName },
                        set: { model.phoneContactName = $0 }
                    ))
                    Button("Ask on this iPhone") { Task { await model.askOnPhone() } }
                        .disabled(model.phoneBusy || model.phoneDownloading || !model.phoneModelReady || model.phoneQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.phoneBusy { ProgressView("Preparing a local reply") }
                    Button("New phone conversation") { Task { await model.newPhoneConversation() } }.disabled(model.phoneBusy || model.phoneDownloading)
                    Button("Allow phone Calendar") { Task { await model.enablePhoneCalendar() } }
                    Button("Allow phone Contacts") { Task { await model.enablePhoneContacts() } }
                    if !model.phoneAnswer.isEmpty {
                        Text(model.phoneAnswer).textSelection(.enabled)
                    }
                }
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
                        Text("On your Mac, run assistantctl pair-phone once. Scan the displayed QR code using your iPhone Camera, then open it in Local Assistant.")
                        Text("Pair while both devices are on the same local network.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                        Text("Enabled sources are available to the phone model. When paired, sleep totals, today's steps/energy/exercise and a recent location rounded to about 1 km can sync to your Mac. Raw Health samples stay on this phone. Location is collected while the app is open.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.busy)
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
}
