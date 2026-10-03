import LocalInference
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let assistantContext = UTType(exportedAs: "org.localproactiveassistant.context", conformingTo: .json)
}

struct AssistantView: View {
    @State private var model = AssistantViewModel()
    @State private var importing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
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
                        Toggle("Include next seven days of Calendar", isOn: $model.includeCalendar)
                        Button("Allow Calendar access") { Task { await model.allowCalendar() } }
                        Toggle("Include one exact contact", isOn: $model.includeContacts)
                        TextField("Exact contact name", text: $model.contactName)
                            .textInputAutocapitalization(.words)
                        Button("Allow Contacts access") { Task { await model.allowContacts() } }
                        Toggle("Include recorded sleep total", isOn: $model.includeSleep)
                        Button("Request sleep read access") { Task { await model.allowSleep() } }
                        Text("Sleep context is a seven-day recorded total, not medical advice. Raw HealthKit samples stay on this phone.")
                            .font(.caption).foregroundStyle(.secondary)
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
                    Section("Answer and source coverage") { Text(model.answer).textSelection(.enabled) }
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
            .navigationTitle("Local Assistant")
            .task { await model.checkModel() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.assistantContext, .json], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { model.importContext(from: url) }
            }
            .onOpenURL { model.importContext(from: $0) }
            .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancel() } }
        }
    }
}
