import LocalInference
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let assistantContext = UTType(exportedAs: "org.localproactiveassistant.context", conformingTo: .json)
}

struct AssistantView: View {
    @State private var model = AssistantViewModel()
    @State private var showingLocalTools = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Chat in Messages", systemImage: "message.fill")
                        .font(.title2.bold())
                    Text("Open your private self-chat in Messages—the same conversation you used during setup.")
                        .accessibilityIdentifier("messagesInstructions")
                    Text("Try sending:")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("What is on my calendar tomorrow?")
                        .textSelection(.enabled)
                    Text("Your Mac answers in that conversation. Keep it awake with the assistant running. You do not need this app open to chat.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Phone companion") {
                    NavigationLink {
                        PhoneSourcesView(model: model)
                    } label: {
                        Label("Phone sources", systemImage: "iphone")
                    }
                    Text("Optional phone sources are used only for answers inside this app. They are not connected to your Messages assistant yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Advanced") {
                        Button("On-phone model tools") { showingLocalTools = true }
                            .accessibilityIdentifier("phoneModelTools")
                        Text("Test answers that run on this phone, or import a Mac snapshot. This is separate from chatting in Messages.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Local Assistant")
            .navigationDestination(isPresented: $showingLocalTools) {
                PhoneModelToolsView(model: model)
            }
            .task { await model.checkModel() }
            .onOpenURL {
                model.importContext(from: $0)
                if model.imported != nil { showingLocalTools = true }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancel() } }
        }
    }
}

private struct PhoneSourcesView: View {
    @Bindable var model: AssistantViewModel

    var body: some View {
        Form {
            Section {
                Text("These sources stay on this phone. Enabling them does not add phone data to answers in Messages; device sync is still to come.")
            }
            Section("Calendar") {
                if model.includeCalendar {
                    Toggle("Use Calendar", isOn: $model.includeCalendar)
                } else {
                    Button("Enable Calendar") { Task { await model.allowCalendar() } }
                }
                Text("Upcoming events in the next seven days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Contacts") {
                if model.includeContacts {
                    Toggle("Use Contacts", isOn: $model.includeContacts)
                    TextField("Exact contact name", text: $model.contactName)
                        .textInputAutocapitalization(.words)
                } else {
                    Button("Enable Contacts") { Task { await model.allowContacts() } }
                }
                Text("One person matching the exact name you enter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sleep") {
                if model.includeSleep {
                    Toggle("Use recorded sleep", isOn: $model.includeSleep)
                } else {
                    Button("Enable sleep context") { Task { await model.allowSleep() } }
                }
                Text("Recorded sleep over seven days. Raw samples stay on this phone; missing data is not treated as zero sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.notice.isEmpty {
                Section { Text(model.notice).font(.subheadline) }
            }
        }
        .disabled(model.busy)
        .navigationTitle("Phone sources")
    }
}

private struct PhoneModelToolsView: View {
    @Bindable var model: AssistantViewModel
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                Text("These answers run on this phone and appear here. For your everyday assistant, use your self-chat in Messages.")
            }
            Section("On-device model") {
                Text(model.modelDetail).font(.subheadline)
                Button("Check availability") { Task { await model.checkModel() } }
                    .disabled(model.busy)
                Text("Answers run here. No AI server or model action tools are configured.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Context") {
                Picker("Use", selection: $model.contextChoice) {
                    ForEach(AssistantViewModel.ContextChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.contextChoice == .phone {
                    NavigationLink("Choose phone sources") { PhoneSourcesView(model: model) }
                }
                if model.contextChoice == .mac {
                    if let context = model.imported {
                        Text("\(context.records.count) records exported \(context.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("This is a snapshot. Your phone cannot read the Mac's Messages database or refresh this file automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("Import a context document exported by assistantctl.") }
                }
                Button("Import Mac context") { importing = true }
                Button("Clear local context", role: .destructive) { model.clearContext() }
            }.disabled(model.busy)
            Section("Question") {
                TextField("Ask about selected evidence", text: $model.question, axis: .vertical)
                    .lineLimit(2...5).disabled(model.busy)
                if model.busy {
                    HStack {
                        ProgressView()
                        Text("Answering locally…")
                        Spacer()
                        Button("Cancel") { model.cancel() }
                    }
                } else {
                    Button("Ask locally") { model.ask() }
                        .disabled(model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !model.notice.isEmpty {
                Section { Text(model.notice).font(.subheadline) }
            }
            if !model.answer.isEmpty {
                Section("Answer and source coverage") { Text(model.answer).textSelection(.enabled).accessibilityIdentifier("localAnswer") }
            }
            if let evidence = model.evidence {
                Section("Evidence supplied to the model") {
                    ForEach(evidence.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("[\(record.id)] \(record.source)").font(.headline)
                            Text(record.text).textSelection(.enabled)
                            Text(record.locator).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("At most eight records. Citations identify supplied sources; review whether they support each claim.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("On-phone model tools")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.assistantContext, .json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importContext(from: url) }
        }
    }
}
