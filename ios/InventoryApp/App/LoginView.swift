import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var network: NetworkMonitor

    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var submitting = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("库存管理系统").font(.largeTitle.bold())

            VStack(spacing: 12) {
                TextField("邮箱", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("密码", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            .font(.title3)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                Group {
                    if submitting { ProgressView() } else { Text("登录") }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(email.isEmpty || password.isEmpty || submitting)
            .requiresOnline()
        }
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .email }
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty, !submitting, network.isOnline else { return }
        submitting = true
        error = nil
        Task {
            defer { submitting = false }
            do {
                try await auth.signIn(email: email, password: password)
            } catch {
                self.error = AppError.message(error)
            }
        }
    }
}
