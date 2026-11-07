import SwiftUI

/// Full-screen password prompt shown over everything while locked. Any non-empty
/// password opens a vault; a different password opens a different (maybe empty) one.
struct UnlockView: View {
    @Environment(AppSession.self) private var session
    @State private var password = ""
    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("AES Camera")
                    .font(.largeTitle.bold())

                if session.state == .unlocking {
                    ProgressView("Unlocking…")
                        .padding(.vertical, 28)
                } else {
                    form
                }
                Spacer()
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
        }
        .onAppear { focused = true }
    }

    private var form: some View {
        VStack(spacing: 16) {
            HStack {
                Group {
                    if revealed {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(unlock)

                Button {
                    revealed.toggle()
                    focused = true
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(revealed ? "Hide password" : "Show password")
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            Button(action: unlock) {
                Text("Unlock")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)

            Text("A different password opens a different vault.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""
        revealed = false
        Task { await session.unlock(password: entered) }
    }
}
