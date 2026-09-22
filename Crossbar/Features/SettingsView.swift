import SwiftUI

/// Everything a person can change, and the state they need in order to change it.
///
/// Five sections, because that is the whole surface: which deployment this device is in,
/// where the service is, whether this device is on the network that can reach it, whether
/// the service has been told who this device is, and — under Advanced — the instruments.
/// The identity is shown rather than configured: in the private deployment it comes from
/// the tailnet, and that is the point of it rather than a detail to be edited. A device
/// identity is enrolled rather than configured, for the same reason and from a code the
/// service's owner hands over.
struct SettingsView: View {
    @ObservedObject var session: CallSession
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var deviceAuth = DeviceAuth.shared

    @AppStorage(AppSettings.Key.serviceAddress) private var serviceAddress = ""
    @AppStorage(AppSettings.Key.signallingOrigin) private var signallingOrigin = ""
    @AppStorage(AppSettings.Key.embeddedNode) private var embeddedNode = true

    /// The connection mode, as this screen is showing it.
    ///
    /// Kept here rather than read from the setting on every pass, because the setting is
    /// written by the screen this one pushes: a value that screen changed is not one this
    /// one is told about, and a row read straight from the defaults would go on describing
    /// the mode that was in force when Settings was opened. It is seeded on the way in, and
    /// the pushed screen reports what it stored.
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
                connectionSection
                serviceSection
                networkSection
                identitySection
                deviceSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out of the tailnet?",
                                isPresented: $confirmingSignOut,
                                titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This device leaves the network and will need to be authorised again "
                     + "before it can reach the service.")
            }
            .confirmationDialog("Forget this device?",
                                isPresented: $confirmingForgetDevice,
                                titleVisibility: .visible) {
                Button("Forget", role: .destructive) { forgetDevice() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The key this device enrolled with is deleted, and it cannot be "
                     + "recovered. The service then needs a new enrolment code before this "
                     + "device can reach it again.")
            }
        }
    }

    // MARK: - Connection

    /// Which of Crossbar's two deployments this device is in, and where to change it.
    ///
    /// Shown rather than only asked once, because it is the one line on this screen that
    /// changes what the others mean: an address is a tailnet name in one mode and a server
    /// on the internet in the other, and the same word "address" is both. Changing it
    /// re-dials everything — nothing that is up can stay up across a change of route — so
    /// this is a door back to the question rather than a switch that flips underneath a
    /// live session.
    private var connectionSection: some View {
        Section {
            LabeledContent("Mode", value: mode?.title ?? "Not chosen yet")
                .accessibilityIdentifier("settings.connectionMode")

            NavigationLink("Change connection") {
                // The mode is stored, not bound, so the root screen — which loads whenever
                // the mode changes — cannot see a change made here: it was not the one that
                // changed it. So this screen asks for the reload itself, the same way the
                // Reconnect button below asks for its own, and takes back what was chosen.
                OnboardingView { chosen in
                    mode = chosen
                    Task { await session.load() }
                }
            }
            .accessibilityIdentifier("settings.changeConnection")
        } header: {
            Text("Connection")
        } footer: {
            Text(mode?.summary
                 ?? "Choose how this app reaches its service, and the rest of this screen "
                 + "will mean the deployment you chose.")
        }
    }

    // MARK: - Service

    private var serviceSection: some View {
        Section {
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
                HStack(spacing: 8) {
                    ProgressView()
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
        } header: {
            Text("Service")
        } footer: {
            Text("Both addresses must be reachable over your tailnet. Leave the service "
                 + "address empty to use the built-in one, and the signalling address empty "
                 + "to use the one each invitation carries — which is the normal case, "
                 + "because then the client cannot disagree with the service about it.")
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section {
            LabeledContent("Carried by", value: session.tailnetRoute)
                .accessibilityIdentifier("settings.route")

            Toggle("Carry the tailnet in this app", isOn: $embeddedNode)
                .accessibilityIdentifier("settings.embeddedNode")
                // Applied at once: a switch that quietly waits for the next launch would
                // leave the route line describing a network the app is no longer using.
                .onChange(of: embeddedNode) {
                    Task { await session.load() }
                }

            if case .failed(let reason) = session.tailnetState {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }

            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }

            Button("Sign out of the tailnet") { confirmingSignOut = true }
                .disabled(!embeddedNode || session.tailnetState == .idle)
                .accessibilityIdentifier("settings.signOut")

            Link("Open the tailnet console", destination: AppSettings.tailnetConsole)
                .accessibilityIdentifier("settings.tailnetConsole")
        } header: {
            Text("Network")
        } footer: {
            Text("With this on, the app runs its own node on your tailnet and nothing else "
                 + "has to be installed. Turning it off means dialling over the system's own "
                 + "network, which needs the Tailscale app connected.\n\n"
                 + "This device appears in the tailnet as \(TailnetNode.hostName).")
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            if let me = session.me {
                LabeledContent("Name", value: me.displayName)
                    .accessibilityIdentifier("settings.identityName")
            } else {
                Text("No identity yet.").foregroundStyle(.secondary)
            }
            LabeledContent("Source", value: mode == .publicServer
                           ? "This device's enrolment" : "Tailnet sign-in")
        } header: {
            Text("Identity")
        } footer: {
            Text("Your identity is not an account in this app. The service reads it from "
                 + "the tailnet you sign in to, and injects it into every request; this app "
                 + "has no password to keep and no way to change who it is.")
        }
    }

    // MARK: - Device

    /// Whether this service has been told who this device is.
    ///
    /// Separate from the identity section above on purpose: that one is the person, read
    /// from the tailnet, and this one is the hardware, which is a key this device holds and
    /// the service keeps a record of. A household that has turned device auth on needs this
    /// enrolled before anything else in the app will answer; the private deployment does
    /// not ask for it, and then this section says so and stays out of the way.
    private var deviceSection: some View {
        Section {
            if deviceAuth.isEnrolled {
                LabeledContent("Device ID", value: deviceAuth.deviceId ?? "—")
                    .accessibilityIdentifier("settings.deviceId")

                LabeledContent("Device name", value: deviceAuth.deviceName ?? "—")
                    .accessibilityIdentifier("settings.deviceName")
            } else {
                Text("This device is not enrolled.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.deviceStatus")
            }

            // The camera or the keyboard; both end up in this one field.
            HStack(spacing: 10) {
                TextField("Enrolment code", text: $enrollmentCode, prompt: Text("Paste the code"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.enrollmentCode")

                Button {
                    isScanning = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .imageScale(.large)
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
                HStack(spacing: 8) {
                    ProgressView()
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

            if deviceAuth.isEnrolled {
                Button("Forget this device", role: .destructive) {
                    confirmingForgetDevice = true
                }
                .accessibilityIdentifier("settings.forgetDevice")
            }
        } header: {
            Text("Device")
        } footer: {
            Text("An enrolment code ties this device to one service, and it carries that "
                 + "service's own address, so the address above does not have to be set by "
                 + "hand as well.\n\n"
                 + "The key this device enrols with is made here and never leaves it, and "
                 + "forgetting the device deletes it: the service then needs to issue a new "
                 + "code before this device can be reached again. Leave all of this alone "
                 + "unless the service asks for it — a service without device enrolment, "
                 + "which is the private deployment this app was built against, needs none "
                 + "of it.")
        }
    }

    private func enroll() {
        let code = enrollmentCode
        Task {
            isEnrolling = true
            enrollmentFailure = nil
            do {
                try await deviceAuth.enroll(code: code)
                enrollmentCode = ""
                // The code may have moved the service's address, which only takes effect
                // when something is asked of it: loading here means the app is talking to
                // the service it just enrolled with rather than to the one it was pointed
                // at a moment ago.
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
        // The refusal, if there was one, was about the identity that has just been
        // deleted; leaving it on screen would read as a fault in the state that replaced it.
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
