import SwiftUI

struct BetaAccessRequestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BetaAccessFormModel()
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.isSubmitted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("You're on the list. Expect to hear back within around five days or less.")
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Thanks for using ProxyPilot.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Enter an e-mail address for your beta invitation")
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("ProxyPilot beta users can try new features that may or may not make it to the stable version of ProxyPilot. Beta features will be clearly marked in the app, and rolling back to the GA build is simple.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("E-mail address")
                        .font(.callout.weight(.medium))
                    TextField("you@example.com", text: $model.email)
                        .textContentType(.emailAddress)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($emailFocused)
                        .disabled(model.isSubmitting)
                        .accessibilityLabel("E-mail address")
                        .onSubmit { Task { await model.submit() } }
                    Text("Submit to share your e-mail address with Slicewrite Studio for ProxyPilot beta invitations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Submission error: \(error)")
                }
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isSubmitting)
                    Spacer()
                    if model.isSubmitting { ProgressView().controlSize(.small) }
                    Button(model.isSubmitting ? "Submitting…" : "Submit") {
                        Task { await model.submit() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                }
            }
        }
        .padding(28)
        .frame(width: 520)
        .onAppear { emailFocused = true }
        .interactiveDismissDisabled(model.isSubmitting)
    }
}
