import SwiftUI

/// Everything a person can change, and the state they need in order to change it.
///
/// Three sections, because that is the whole surface: where the service is, whether this
/// device is on the network that can reach it, and — under Advanced — the instruments. The
/// identity is shown rather than configured: it comes from the tailnet, and that is the
/// point of it rather than a detail to be edited.
struct SettingsView: View {
    @ObservedObject var session: CallSession
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.serviceAddress) private var serviceAddress = ""
    @AppStorage(AppSettings.Key.signallingOrigin) private var signallingOrigin = ""
    @AppStorage(AppSettings.Key.embeddedNode) private var embeddedNode = true

    @State private var confirmingSignOut = false
    @State private var notice: String?
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                networkSection
                identitySection

                #if DEBUG
                advancedSection
                #endif
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
                if let relationship = me.relationship, !relationship.isEmpty {
                    LabeledContent("Relationship", value: relationship)
                }
            } else {
                Text("No identity yet.").foregroundStyle(.secondary)
            }
            LabeledContent("Source", value: "Tailnet sign-in")
        } header: {
            Text("Identity")
        } footer: {
            Text("Your identity is not an account in this app. The service reads it from "
                 + "the tailnet you sign in to, and injects it into every request; this app "
                 + "has no password to keep and no way to change who it is.")
        }
    }

    // MARK: - Advanced

    #if DEBUG
    private var advancedSection: some View {
        Section {
            NavigationLink("Instruments") { ProbeView() }
                .accessibilityIdentifier("settings.instruments")

            Button("Exercise the camera") { session.runCameraSelfTest() }
                .accessibilityIdentifier("settings.cameraSelfTest")

            Button("Exercise CallKit") { session.runCallKitSelfTest() }
                .accessibilityIdentifier("settings.callKitSelfTest")
        } header: {
            Text("Advanced")
        } footer: {
            Text("The instruments this app was built against, and the two self-tests that "
                 + "exercise paths a call would otherwise have to be in front of a person to "
                 + "reach. Debug builds only.")
        }
    }
    #endif

    private func signOut() {
        Task {
            let outcome = await session.node.signOut()
            notice = outcome
            await session.load()
        }
    }
}
