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

    @AppStorage(AppSettings.Key.serviceAddress) private var serviceAddress = ""
    @AppStorage(AppSettings.Key.signallingOrigin) private var signallingOrigin = ""
    @AppStorage(AppSettings.Key.embeddedNode) private var embeddedNode = true

    /// The connection mode, as this screen is showing it.
    ///
    /// Kept here rather than read from the setting on every pass, because the setting is written
    /// by the screen this one pushes: a value that screen changed is not one this screen is told
    /// about, and a row read straight from the defaults would go on describing the mode that was
    /// in force when Settings was opened. It is seeded on the way in, and the pushed screen
    /// reports what it stored.
    @State private var mode = AppSettings.connectionMode

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
                privacySection
                advancedSection
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
                LabeledContent("This device", value: deviceAuth.deviceName ?? "Enrolled")
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
                    TextField("Enrolment code", text: $enrollmentCode, prompt: Text("Enrolment code"))
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
        } footer: {
            Text("Your name comes from your household's Crossbar, not from an account here. "
                 + "This device holds a key it made itself and never sends anywhere; forgetting "
                 + "it deletes the key.")
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            LabeledContent("Crossbar", value: serverName)
                .accessibilityIdentifier("settings.serverName")

            LabeledContent("Status", value: connectionWord)
                .accessibilityIdentifier("settings.connectionMode")

            NavigationLink("Change server") {
                // The mode is stored, not bound, so the root screen — which loads whenever the
                // mode changes — cannot see a change made here: it was not the one that changed
                // it. So this screen asks for the reload itself and takes back what was chosen.
                OnboardingView { chosen in
                    mode = chosen
                    Task { await session.load() }
                }
            }
            .accessibilityIdentifier("settings.changeConnection")
        } header: {
            Text("Crossbar Server")
        } footer: {
            Text(mode?.summary
                 ?? "This app reaches one Crossbar server: your household's. The code you were "
                 + "sent points it there.")
        }
    }

    /// The server's name as somebody would say it: the host, not the whole address.
    private var serverName: String {
        let address = AppSettings.serviceAddress ?? FamilyCallService.compiledDefault.absoluteString
        return URL(string: address)?.host ?? address
    }

    /// Whether this device can reach its server, in a word.
    private var connectionWord: String {
        switch session.phase {
        case .ready: return "Connected"
        case .loading: return "Connecting…"
        case .needsLogin: return "Waiting for approval"
        case .ringing, .outgoing, .inCall: return "In a call"
        case .failed: return "Not connected"
        }
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

    /// The plumbing, and the reason a load failed.
    ///
    /// Everything here is real and none of it is needed to make a call, which is exactly why it
    /// is one section down rather than spread across the screen. The failure's own words are
    /// here too: somebody debugging has to be able to read them, and somebody ringing their
    /// mother should not have to.
    private var advancedSection: some View {
        Section {
            LabeledContent("Carried by", value: session.tailnetRoute)
                .accessibilityIdentifier("settings.route")

            Toggle("Carry the network in this app", isOn: $embeddedNode)
                .accessibilityIdentifier("settings.embeddedNode")
                // Applied at once: a switch that quietly waited for the next launch would leave
                // the row above describing a network the app is no longer using.
                .onChange(of: embeddedNode) {
                    Task { await session.load() }
                }

            TextField("Address", text: $serviceAddress,
                      prompt: Text(FamilyCallService.compiledDefault.absoluteString))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("settings.serviceAddress")

            TextField("Signalling address", text: $signallingOrigin, prompt: Text("From the invitation"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("settings.signallingOrigin")

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

            Link("Open the tailnet console", destination: AppSettings.tailnetConsole)
                .accessibilityIdentifier("settings.tailnetConsole")

            Button("Sign out of the tailnet") { confirmingSignOut = true }
                .disabled(!embeddedNode || session.tailnetState == .idle)
                .accessibilityIdentifier("settings.signOut")
        } header: {
            Text("Advanced")
        } footer: {
            Text("The address this app dials, and the network it dials over. Leave all of it "
                 + "alone unless you have been told otherwise — an address that is wrong here "
                 + "stops the app reaching anything at all.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: version)
            LabeledContent("This device appears as", value: TailnetNode.hostName)
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
/// reach each other, and the directory the server keeps is the household itself. Anything
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
                Text("The household's directory: who is in it, which devices have joined, and "
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
