import SwiftUI

/// The one question this app has to ask before it can work: where its service is.
///
/// Shown when no mode has been chosen yet, and again from Settings when someone wants to
/// change it. Crossbar's two deployments are not two addresses for one thing — one is a
/// household's own network, which this app carries, and the other is a server reached the
/// ordinary way — so the two paths are explained here in plain words, one section each, and
/// the answer is stored. See `ConnectionMode` for why it is stored rather than worked out
/// from the address.
///
/// Neither path repeats anything the rest of the app already does. A tailnet that needs
/// this device approved lands in the session's own `needsLogin` state, which has a screen
/// and a button of its own, and an enrolment code goes to `DeviceAuth`, which is the only
/// thing that knows how to spend one. Nor does either path dial anything itself: a load is
/// what takes a route, and whoever changed the mode asks for it — the root screen reacts to
/// the value it seeded from the setting, and Settings asks directly, because a change made
/// there is one the root never saw.
struct OnboardingView: View {
    /// Called once a mode has been stored, so whoever showed this screen can carry on.
    ///
    /// The root screen replaces this view with the ordinary flow; Settings, which pushes
    /// this, is popped by `dismiss` and needs nothing from here.
    var onChoose: (ConnectionMode) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var deviceAuth = DeviceAuth.shared

    /// The private address, bound to the same setting Settings edits. Left alone by the
    /// private path: empty means the built-in address, and a household that has set its own
    /// keeps it.
    @AppStorage(AppSettings.Key.serviceAddress) private var serviceAddress = ""

    @State private var serverAddress = ""
    @State private var enrollmentCode = ""
    @State private var failure: String?
    @State private var isWorking = false

    /// What a person is told when the server wants a code and they have not given one.
    ///
    /// The wording is the way in: it says what is being asked of them and nothing about
    /// what happens if it is not answered, because what happens is a call that never
    /// arrives and a sentence about identity that would not have helped.
    private static let needsEnrolment =
        "This server needs this device to be enrolled. Paste the enrollment code you were given."

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Crossbar runs in two places, and this app reaches them "
                         + "differently. Choose the one that is yours — you can change it "
                         + "later in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                privateSection
                publicSection
            }
            .navigationTitle("Connection")
        }
    }

    // MARK: - This household's own network

    private var privateSection: some View {
        Section {
            TextField("Address", text: $serviceAddress,
                      prompt: Text(FamilyCallService.compiledDefault.absoluteString))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("onboarding.privateAddress")

            Button("Use this household's network") { usePrivateNetwork() }
                .accessibilityIdentifier("onboarding.usePrivateNetwork")
        } header: {
            Text("This household runs its own network (Tailscale)")
        } footer: {
            Text("Choose this to join a household whose Crossbar server runs on its own "
                 + "private network. This app carries that network itself, so nothing else "
                 + "has to be installed — the first time it connects, that network will ask "
                 + "to approve this device, and the page for it is the whole of the setup.\n\n"
                 + "The address below is the one this app was built with unless someone has "
                 + "set a different one here. Leave it as it is unless you were told "
                 + "otherwise.")
        }
    }

    // MARK: - A server

    private var publicSection: some View {
        Section {
            TextField("Server address", text: $serverAddress,
                      prompt: Text("https://crossbar.example.com"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("onboarding.serverAddress")

            TextField("Enrolment code", text: $enrollmentCode,
                      prompt: Text("Only if the server asks for one"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("onboarding.enrollmentCode")

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking the server…").foregroundStyle(.secondary)
                }
            } else {
                Button("Connect") { Task { await usePublicServer() } }
                    .disabled(serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("onboarding.useServer")
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.notice")
            }
        } header: {
            Text("Connect to a Crossbar server")
        } footer: {
            Text("Choose this when you were given the address of a Crossbar server — one "
                 + "that answers at a hostname, on the internet or on a network you are "
                 + "already on. The address must be an https:// one.\n\n"
                 + "If the server asks devices to enrol, paste the enrolment code you were "
                 + "given: the whole line, or the payload a QR code carries. A code carries "
                 + "that server's own address, so the field above does not have to be right "
                 + "as well. A server that asks for nothing needs no code, and leaving the "
                 + "field empty there is not a mistake.")
        }
    }

    // MARK: - Choosing

    /// The tailnet path: the mode, and nothing else.
    ///
    /// The address is deliberately untouched. An empty one means the built-in address, a
    /// stored one is the household's own, and writing either of them from here would be
    /// this screen deciding something it was not asked about.
    private func usePrivateNetwork() {
        finish(.privateNetwork)
    }

    /// The server path: validate the address, spend the code if there is one, then choose.
    private func usePublicServer() async {
        guard let address = validatedServerAddress() else {
            failure = "That is not a server address. A Crossbar server is reached at an "
                    + "https:// address, so paste the whole of it, starting with https://."
            return
        }

        isWorking = true
        failure = nil
        // Set before anything is asked of the service, because both `DeviceAuth` and the
        // control plane read the address afresh on every request: this is what the probe,
        // the enrolment and the load after them will use.
        AppSettings.serviceAddress = address.absoluteString

        let code = enrollmentCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty {
            // Nothing to spend, so the only question left is whether the server was
            // expecting something. Asked here rather than discovered later, because a load
            // against a server that wants a code fails as a call that never arrives.
            if !deviceAuth.isEnrolled, await deviceAuth.requiresEnrolment() == true {
                failure = Self.needsEnrolment
                isWorking = false
                return
            }
        } else {
            do {
                try await deviceAuth.enroll(code: code)
            } catch DeviceAuthError.unsupportedServer {
                // A server with no device-auth routes answers 404, and for this app that is
                // the server saying it does not ask — never a fault. The code was simply
                // not needed, which is worth no sentence at all.
            } catch let refusal as DeviceAuthError {
                failure = refusal.failureMessage
                isWorking = false
                return
            } catch {
                failure = error.localizedDescription
                isWorking = false
                return
            }
        }

        finish(.publicServer)
    }

    /// The address someone typed, when it is one this app can dial.
    ///
    /// `https` is required rather than preferred: a public server is answering over the
    /// internet, and the pairing secret that follows — the enrolment code and the session
    /// it buys — is a credential, not a preference.
    private func validatedServerAddress() -> URL? {
        let text = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Stores the choice and hands the person on.
    ///
    /// Nothing is dialled from here, because this screen does not know what is watching it:
    /// storing the mode *is* continuing to the normal flow, and each caller asks for the
    /// reload that follows — the root screen by reacting to the value it holds, Settings by
    /// asking the session directly.
    private func finish(_ mode: ConnectionMode) {
        AppSettings.connectionMode = mode
        onChoose(mode)
        dismiss()
    }
}
