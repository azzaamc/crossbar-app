import SwiftUI

/// Everything a person can change, in five sections and one order.
///
/// The order is the point. What somebody opens this screen for is themselves and their server;
/// what they almost never open it for is the address the app dials or the network it dials over.
/// Those are still here, one section down, together with the reason a load failed — because a
/// troubleshooting question deserves an answer, and it does not deserve to be the first thing on
/// the screen.
///
/// The identity is shown rather than configured: in one deployment it comes from the network,
/// and in both a device is enrolled rather than edited, from a code somebody else hands over.
struct SettingsView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var deviceAuth = DeviceAuth.shared

    @State private var confirmingSignOut = false
    @State private var confirmingForgetDevice = false
    @State private var enrollmentCode = ""
    @State private var isScanning = false
    @State private var enrollmentFailure: String?
    @State private var isEnrolling = false
    @State private var notice: String?
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                youSection
                serverSection
                advancedSection
                privacySection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of the tailnet?",
                                isPresented: $confirmingSignOut,
                                titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This device leaves the network and will need to be authorised again "
                     + "before it can reach the server.")
            }
            .confirmationDialog("Forget this device?",
                                isPresented: $confirmingForgetDevice,
                                titleVisibility: .visible) {
                Button("Forget", role: .destructive) { forgetDevice() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The key this device enrolled with is deleted and cannot be recovered. "
                     + "Your administrator will need to invite it again before it can connect.")
            }
        }
    }

    // MARK: - You

    private var youSection: some View {
        Section {
            if let me = session.me {
                LabeledContent("Name", value: me.displayName)
                    .accessibilityIdentifier("settings.identityName")
            } else {
                Text("Not signed in yet.")
                    .foregroundStyle(.secondary)
            }

            if deviceAuth.isEnrolled {
                // The name the system has for this device, read now rather than replayed from
                // what enrollment stored: renaming the phone is something a person does once and
                // would expect to see here without enrolling the device again. It is also the
                // name the service holds, because enrollment sends this same value.
                LabeledContent("This device", value: DeviceIdentity.defaultDeviceName)
                    .accessibilityIdentifier("settings.deviceName")

                Button("Forget this device", role: .destructive) {
                    confirmingForgetDevice = true
                }
                .accessibilityIdentifier("settings.forgetDevice")
            } else {
                Text("This device is not enrolled with your Crossbar.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.deviceStatus")

                // The camera or the keyboard; both end up in this one field.
                HStack(spacing: Theme.Space.snug) {
                    TextField("Enrollment code", text: $enrollmentCode, prompt: Text("Enrollment code"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.enrollmentCode")

                    Button {
                        isScanning = true
                    } label: {
                        Theme.symbol("qrcode.viewfinder", size: 20)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Scan the code")
                    .accessibilityIdentifier("settings.scanCode")
                }
                .sheet(isPresented: $isScanning) {
                    EnrollmentScanner { code in
                        enrollmentCode = code
                        isScanning = false
                    }
                }

                if isEnrolling {
                    HStack(spacing: Theme.Space.tight) {
                        ProgressView().controlSize(.small)
                        Text("Enrolling…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Enrol this device") { enroll() }
                        .disabled(enrollmentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("settings.enroll")
                }

                if let enrollmentFailure {
                    Text(enrollmentFailure)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.enrollmentNotice")
                }
            }
        } header: {
            Text("You")
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            LabeledContent("Crossbar", value: serverName)
                .accessibilityIdentifier("settings.serverName")

            NavigationLink("Change server") {
                // The mode is stored, not bound, so the root screen — which loads whenever the
                // mode changes — cannot see a change made here: it was not the one that changed
                // it. So this screen asks for the reload itself rather than waiting to be told.
                OnboardingView { _ in
                    Task { await session.load() }
                }
            }
            .accessibilityIdentifier("settings.changeConnection")

            // Only where there is an identity to invite from. An invitation is issued *by* a
            // device — the service reads whose it is from the session — so a deployment that does
            // not enroll devices has nobody for this row to act as, and its invitations come from
            // whoever installed it. A row that could only ever fail is worse than no row.
            if deviceAuth.isEnrolled {
                NavigationLink("Add another device") {
                    AddDeviceView(session: session)
                }
                .accessibilityIdentifier("settings.addDevice")
            }
        } header: {
            Text("Crossbar Server")
        }
    }

    /// The server's name as somebody would say it: the host, not the whole address.
    private var serverName: String {
        let address = AppSettings.serviceAddress ?? ServiceAddress.compiledDefault.absoluteString
        return URL(string: address)?.host ?? address
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            NavigationLink("What Crossbar knows") { PrivacyView() }
        } header: {
            Text("Privacy")
        }
    }

    // MARK: - Advanced

    /// What to do when it is not working.
    ///
    /// This section used to hold every address the app knows, the switch for carrying a network
    /// inside it, and two links to somebody else's console — a screen of plumbing that confused
    /// the person who wrote the rest of this app, which is a reliable sign it would confuse
    /// everybody else. What is left is the two things it is actually for: asking it to try
    /// again, and reading what the server said when it refused.
    private var advancedSection: some View {
        Section {
            if isBusy {
                HStack(spacing: Theme.Space.tight) {
                    ProgressView().controlSize(.small)
                    Text("Reconnecting…").foregroundStyle(.secondary)
                }
            } else {
                Button("Reconnect now") {
                    Task {
                        isBusy = true
                        await session.load()
                        isBusy = false
                    }
                }
                .accessibilityIdentifier("settings.reconnect")
            }

            if case .failed(let reason) = session.phase {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.failureReason")
            }

            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }

            Button("Sign out of the tailnet") { confirmingSignOut = true }
                .disabled(session.tailnetState == .idle)
                .accessibilityIdentifier("settings.signOut")
        } header: {
            Text("Advanced")
        }
    }

    // MARK: - About

    /// What this build is.
    ///
    /// It used to name the device as the tailnet console sees it, which is a fact only for
    /// somebody who runs that console — and then only to recognise one row among many.
    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: version)
        } header: {
            Text("About")
        }
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: - Actions

    private func enroll() {
        let code = enrollmentCode
        Task {
            isEnrolling = true
            enrollmentFailure = nil
            do {
                try await deviceAuth.enroll(code: code)
                enrollmentCode = ""
                // The code may have moved the server's address, which only takes effect when
                // something is asked of it: loading here means the app is talking to the server
                // it just enrolled with rather than the one it was pointed at a moment ago.
                await session.load()
            } catch let refusal as DeviceAuthError {
                enrollmentFailure = refusal.failureMessage
            } catch {
                enrollmentFailure = error.localizedDescription
            }
            isEnrolling = false
        }
    }

    private func forgetDevice() {
        deviceAuth.forget()
        // The refusal, if there was one, was about the identity that has just been deleted;
        // leaving it on screen would read as a fault in the state that replaced it.
        enrollmentFailure = nil
    }

    private func signOut() {
        Task {
            let outcome = await session.node.signOut()
            notice = outcome
            await session.load()
        }
    }
}

/// What this app does and does not know, in plain words.
///
/// Every line is checkable against the code: calls are peer to peer and the server arranges them
/// rather than carrying them, a relay is used when a network leaves two devices no other way to
/// reach each other, and the directory the server keeps is the people on it. Anything
/// stronger than that — anonymous, impossible to intercept — would be a claim this app cannot
/// keep, so none of it is here.
struct PrivacyView: View {
    var body: some View {
        List {
            Section("Your calls") {
                Text("Calls go directly between the two devices wherever the network allows it. "
                     + "Your Crossbar server arranges the call and knows who is on it; the sound "
                     + "and the picture do not pass through it.")
            }

            Section("When a direct path is not possible") {
                Text("Some networks leave two devices no way to reach each other. Then the call "
                     + "is relayed through a server so that it can happen at all. Your "
                     + "administrator can see whether one is configured for your Crossbar.")
            }

            Section("What your server keeps") {
                Text("Your Crossbar's directory: who is in it, which devices have joined, and "
                     + "when calls happened. That is what it is for. It does not record calls, "
                     + "and nothing in this app can.")
            }

            Section("What this device keeps") {
                Text("A key it made itself, which never leaves it, and the names of the people "
                     + "you can call. Forgetting the device deletes the key.")
            }
        }
        .navigationTitle("What Crossbar knows")
        .navigationBarTitleDisplayMode(.inline)
    }
}
