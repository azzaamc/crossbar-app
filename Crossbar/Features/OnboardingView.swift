import SwiftUI

/// The first thing anybody sees, and the only question this app has to ask.
///
/// The question is not which transport to use: that is the household administrator's business,
/// and the code they hand over answers it. So the screen is one thing — a code. Scan it or paste
/// it, and the app configures itself: which server, which kind of network, and who this device is.
///
/// The manual path still exists, because a deployment whose code cannot be scanned has to be
/// reachable somehow. It is behind a button in the corner, and it is the only place in the app
/// where the two kinds of deployment are named — everywhere else, a code carries that answer and
/// nobody has to know it.
struct OnboardingView: View {
    /// Called once the app knows how it reaches its service, so whoever showed this can carry on.
    var onChoose: (ConnectionMode) -> Void = { _ in }

    @ObservedObject private var deviceAuth = DeviceAuth.shared

    @State private var code = ""
    @State private var isScanning = false
    @State private var isWorking = false
    @State private var failure: String?
    @State private var isDone = false
    @State private var showingManual = false

    /// The manual path's own state, kept here because the sheet is presented from here.
    @State private var kind: ConnectionMode = .privateNetwork

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.loose) {
                Spacer(minLength: Theme.Space.normal)
                welcome
                Spacer(minLength: Theme.Space.normal)
                if isDone { done } else { join }
                Spacer(minLength: Theme.Space.tight)
            }
            .padding(.horizontal, Theme.Space.screen)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Manual Setup") { showingManual = true }
                        .font(.footnote)
                        .accessibilityIdentifier("onboarding.manual")
                }
            }
            .sheet(isPresented: $isScanning) {
                EnrollmentScanner { scanned in
                    code = scanned
                    isScanning = false
                    Task { await join() }
                }
            }
            .sheet(isPresented: $showingManual) {
                ManualJoinView(kind: $kind, code: $code) {
                    if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Nothing to enrol, which is the case this path exists for: a server
                        // that does not hand out codes, where the kind is the whole of what it
                        // needed and the address is the one the app was built with.
                        onChoose(kind)
                    } else {
                        Task { await join() }
                    }
                }
            }
            // One haptic for the longest wait in the app and the outcome that matters most.
            .sensoryFeedback(.success, trigger: isDone)
            .sensoryFeedback(.error, trigger: failure)
        }
    }

    // MARK: - What is on the screen

    private var welcome: some View {
        VStack(spacing: Theme.Space.snug) {
            CrossbarMark()
                .frame(width: 92, height: 92)

            VStack(spacing: Theme.Space.tight) {
                Text("Crossbar")
                    .font(.largeTitle.weight(.semibold))
                Text("Calls with the people on your Crossbar.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var join: some View {
        VStack(spacing: Theme.Space.normal) {
            Button {
                isScanning = true
            } label: {
                Label("Scan the code", systemImage: "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboarding.scan")

            VStack(spacing: Theme.Space.snug) {
                VStack(spacing: Theme.Space.tight) {
                    // Named as a field rather than left to its placeholder: a bordered box
                    // holding grey centred text reads as a disabled button, and this is the
                    // path somebody has to take when there is no camera to point at a code.
                    Text("Or paste the code instead")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Enrolment code", text: $code, prompt: Text("Type or paste the code"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .font(.callout.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .accessibilityLabel("Enrolment code")
                        .accessibilityIdentifier("onboarding.code")
                }

                if isWorking {
                    HStack(spacing: Theme.Space.tight) {
                        ProgressView().controlSize(.small)
                        Text("Joining…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Join") { Task { await join() } }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("onboarding.join")
                }
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.failure")
            }
        }
    }

    private var done: some View {
        VStack(spacing: Theme.Space.normal) {
            Label("You're in", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
            Text("Crossbar is ready. The people on your server appear in a moment.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The one action

    private func join() async {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty, !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }

        do {
            try await deviceAuth.enroll(code: entered)
            isDone = true
            // The enrolment settled both of these from the code, so what it stored is what
            // this app now runs as.
            onChoose(AppSettings.connectionMode ?? kind)
        } catch let refusal as DeviceAuthError {
            failure = refusal.failureMessage
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The way in for a deployment whose code cannot be scanned.
///
/// The only place in the app where the two kinds of deployment are named, and deliberately so:
/// a code carries that answer, an address does not, and asking somebody to choose between two
/// kinds of network they have never heard of is exactly the question the rest of this screen
/// exists to avoid.
private struct ManualJoinView: View {
    @Binding var kind: ConnectionMode
    @Binding var code: String
    var onJoin: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Private network (Tailscale)").tag(ConnectionMode.privateNetwork)
                        Text("Public internet (HTTPS)").tag(ConnectionMode.publicServer)
                    }
                    .pickerStyle(.inline)
                    // Without this the picker draws its own label as the first row, which
                    // reads as an option that cannot be selected.
                    .labelsHidden()
                } header: {
                    Text("How it is reached")
                } footer: {
                    Text(kind.summary)
                }

                Section {
                    TextField("Code", text: $code, prompt: Text("Enrolment code"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Enrolment code")
                } footer: {
                    Text("A code carries the address of the server it belongs to, so this is "
                         + "usually the only thing to fill in.")
                }
            }
            .navigationTitle("Manual Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        // The kind is the only thing this screen decides. A code carries the
                        // server's address and the mode it is reached in; when there is no
                        // code, the kind is what the app has to be told.
                        AppSettings.connectionMode = kind
                        dismiss()
                        onJoin()
                    }
                    .accessibilityIdentifier("onboarding.useServer")
                }
            }
        }
    }
}
