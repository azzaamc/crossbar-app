import SwiftUI

/// The first thing anybody sees, and the only question this app has to ask.
///
/// The question is not which transport to use: that is your Crossbar administrator's business,
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

    /// The network this app may have to carry before it can reach the service at all.
    ///
    /// Observed here because setup is where it comes up on a private deployment: the login
    /// page belongs on this screen, and this is what knows there is one to offer.
    @ObservedObject private var node = TailnetNode.shared

    @State private var code = ""
    @State private var isScanning = false
    @State private var isWorking = false
    /// Whether the wait is the network coming up rather than the enrollment being sent.
    @State private var isCarrying = false
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
                        // Nothing to enroll. Only a public deployment gets here — the private
                        // option will not let this button be pressed without a code, because a
                        // private server is reached at an address only the code carries.
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
                Label("Scan your enrollment code", systemImage: "qrcode.viewfinder")
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
                    TextField("Enrollment code", text: $code, prompt: Text("Type or paste the code"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .font(.callout.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .accessibilityLabel("Enrollment code")
                        .accessibilityIdentifier("onboarding.code")
                }

                if isWorking {
                    HStack(spacing: Theme.Space.tight) {
                        ProgressView().controlSize(.small)
                        Text(isCarrying ? "Bringing up your private network…" : "Joining…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Join") { Task { await join() } }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("onboarding.join")
                }

                // Waiting for a person, said as itself rather than as a slow join: nothing can
                // be sent until Tailscale has approved this device, and "Joining…" would be
                // describing a wait that is somebody else's to end. The same words the session's
                // own screen uses, because it is the same wait.
                if isCarrying, node.loginURL != nil {
                    VStack(spacing: Theme.Space.tight) {
                        Text("Tailscale has to approve this device before Crossbar can reach your "
                             + "private network. Approve it in the page that opens, and setup "
                             + "carries on by itself.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open the sign-in page") { _ = node.openLoginPage() }
                            .accessibilityIdentifier("onboarding.tailscaleLogin")
                    }
                }
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.failure")

                // A node that will not come up has to be recoverable from the screen it failed
                // on. This is the first screen the app ever shows, so there is no Settings behind
                // it to go to, and the node has to be stopped before its state can be cleared --
                // which is why this is a button and not an instruction.
                if TailnetNode.isEnabled {
                    Button("Start the network over") { Task { await startNetworkOver() } }
                        .accessibilityIdentifier("onboarding.resetNetwork")
                    Text("Forgets this device's identity in the network, so Tailscale will ask to "
                         + "approve it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
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

            // A private deployment whose requests ride the *system's* Tailscale app needs that
            // app connected, and saying so here is the only warning there is. One that carries
            // its own node was authorised during setup — the screen before this one — so the
            // same sentence would be describing work that is already done.
            if AppSettings.connectionMode == .privateNetwork, !TailnetNode.isEnabled {
                Text("Next: Tailscale has to approve this device before Crossbar can reach your "
                     + "private network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.tailscaleNext")
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The one action

    /// Clears the node and tries the whole thing again, which is what a network that will not
    /// come up needs: the state it keeps is the thing that is broken, and the app is the only
    /// thing that can clear it.
    private func startNetworkOver() async {
        if let refusal = await node.reset() {
            failure = refusal
            return
        }
        await join()
    }

    private func join() async {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty, !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false; isCarrying = false }

        do {
            // What the code says is read first — and read here rather than only inside the
            // enrollment — because it decides the order of everything after it.
            let parsed = try deviceAuth.settle(from: entered)

            // The network comes up *before* the request, not after it. On a private deployment
            // the enrollment is the first request this app ever makes, and it can only be made
            // through the node the app carries: sent first, it is a request to an address that
            // resolves nowhere, which is exactly what "could not reach the service" is. The
            // person holding the phone is also the one who has to authorise the node, so the
            // login page is offered while this waits rather than after it has failed.
            //
            // `isEnabled` is the same question the load asks — private mode, the node switched
            // on, and not overridden — so someone who dials with the Tailscale app instead gets
            // no bring-up here either.
            if (parsed.mode ?? AppSettings.connectionMode) == .privateNetwork, TailnetNode.isEnabled {
                isCarrying = true
                try await CallSession.shared.attachForSetup()
                isCarrying = false
            }

            try await deviceAuth.enroll(code: entered)
            isDone = true
            // The enrollment settled both of these from the code, so what it stored is what this
            // app now runs as.
            //
            // Written down as well as handed over. A code that carried no mode — the bare token
            // an administrator can paste — leaves this device with none, and a mode that lived
            // only in the view would be a device that asked to be set up again on every launch.
            let settled = AppSettings.connectionMode ?? kind
            AppSettings.connectionMode = settled
            onChoose(settled)
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
                        // The names come from the mode itself, so the sentence underneath and
                        // the option above it cannot come to describe different things.
                        ForEach(ConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    // Without this the picker draws its own label as the first row, which
                    // reads as an option that cannot be selected.
                    .labelsHidden()
                } header: {
                    Text("Crossbar Server Configuration")
                } footer: {
                    Text(kind.summary)
                }

                Section {
                    TextField("Code", text: $code, prompt: Text("Enrollment code"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Enrollment code")
                } footer: {
                    // A private network is reached at an address this app has no way to work out,
                    // so the code is not optional there — it is the only thing that carries the
                    // address. A public deployment has one it can fall back on.
                    Text(kind == .privateNetwork
                         ? "Request an enrollment code from your Crossbar network administrator. "
                         + "A private network is reached at an address only the code carries."
                         : "Request an enrollment code from your Crossbar network administrator.")
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
                    .disabled(kind == .privateNetwork
                              && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("onboarding.useServer")
                }
            }
        }
    }
}
