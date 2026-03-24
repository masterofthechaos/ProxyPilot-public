import SwiftUI

struct AddCustomProviderView: View {
    @Environment(\.dismiss) private var dismiss

    var onAdd: (String, String, String) -> Void

    @State private var name: String = ""
    @State private var apiBaseURL: String = ""
    @State private var apiKey: String = ""

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Custom Provider")
                .font(.headline)

            Text("If you're just adding a new LLM endpoint, consider using OpenRouter to verify functionality before adding a custom provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Provider Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("API Base URL (e.g. https://api.together.xyz/v1)", text: $apiBaseURL)
                .textFieldStyle(.roundedBorder)

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Text("Custom providers use OpenAI-compatible endpoints without translation or parameter normalization. Compatibility with Xcode Agent is not guaranteed.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
