import PhoneSync
import SwiftUI

struct AssistantView: View {
    @State private var model = AssistantViewModel.shared
    @ObservedObject private var upload = PhoneUploadClient.shared
    @Environment(\.scenePhase) private var scenePhase

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
                    Text("When this app is open, a supported iPhone can use Apple's on-device model with phone Calendar, Contacts, and sleep data you allow. It cannot read your Messages or answer in iMessage while the Mac is offline.")
                        .font(.subheadline).foregroundStyle(.secondary)
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
                        .disabled(model.phoneBusy || model.phoneQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                if upload.pairing != nil {
                    Section("Phone sources") {
                        if model.sleepEnabled {
                            Toggle("Share sleep summaries", isOn: Binding(get: { model.sleepEnabled }, set: { enabled in
                                if !enabled { Task { await model.disableSleep() } }
                            }))
                        } else {
                            Button("Enable sleep sharing") { Task { await model.enableSleep() } }
                        }
                        Text("Only recorded sleep totals for the last 24 hours and seven days leave this phone. Raw Health samples stay here. Calendar, Contacts and Messages already come from your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.busy)
                }
                if !model.notice.isEmpty { Section { Text(model.notice).font(.subheadline) } }
            }
            .navigationTitle("Phone companion")
            .task { await model.activate(); await model.checkPhoneModel() }
            .onOpenURL { model.receivePairing($0) }
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
