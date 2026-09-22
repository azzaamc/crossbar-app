import CoreImage.CIFilterBuiltins
import SwiftUI

/// Hands a second phone its way into Crossbar, without an administrator in the middle.
///
/// A device that is already enrolled is the authority on the identity it holds — that is what the
/// enrolment it holds already means — so the code is asked for here rather than from whoever
/// administers the household's server. It is always for the person this device belongs to: the
/// service reads the invitee from the session, so a device can invite nobody else, and this screen
/// has no field in which to try.
///
/// It is reached only from a device that is enrolled, because an invitation is issued *by* an
/// identity: a deployment with no device auth has nobody to invite from, and its invitations come
/// from whoever installed it. `SettingsView` is where that gate is, beside the reason for it.
///
/// The code is minted when the screen **appears** rather than when it is reached from Settings, and
/// the difference matters: a code spends its life whether or not anybody looks at it, so one minted
/// on the way past is one that expires unused, leaving the second phone refused by a code that was
/// never even read. Nothing is asked of the service until somebody is looking at the answer.
///
/// What is minted is held here and nowhere else — not in the defaults, not in the keychain, not on
/// disk — and it goes when the screen does. The whole of its purpose is to be read off this glass by
/// one other camera and then be worthless; a copy of it kept anywhere else outlives that purpose.
struct AddDeviceView: View {
    let session: CallSession

    /// What the service answered with, once it has answered.
    @State private var invitation: DeviceInvitation?

    /// The code as pixels.
    ///
    /// Drawn once, when the invitation arrives, rather than on every pass of `body`: rendering a
    /// CoreImage graph is real milliseconds, and re-drawing the same unchanged code through them is
    /// work nobody asked for.
    @State private var qr: CGImage?

    /// Whether a request is out, which is the one thing this screen can be doing without a code.
    ///
    /// True before anything has been asked for, because the first paint happens before the task
    /// that does the asking runs, and a blank screen for that moment would be a worse account of
    /// what is happening than the waiting line is.
    @State private var isMinting = true

    /// What the service said when it would not mint one.
    @State private var refusal: String?

    /// Whether the code in hand has stopped working since it was drawn.
    @State private var hasExpired = false

    var body: some View {
        List {
            if let invitation, let qr {
                if hasExpired {
                    expiredSection
                } else {
                    codeSection(qr: qr)
                    wordsSection(invitation)
                }
            } else if isMinting {
                mintingSection
            } else if let refusal {
                refusalSection(refusal)
            }
        }
        .navigationTitle("Add another device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await mint() }
        // The code dies on the service's clock rather than on this screen's, so the only thing this
        // watches is the instant it was told. A code past its life must not sit here looking as
        // though it still works — that is the one way this screen could lie.
        .task(id: invitation?.expiresAt) { await watchExpiry() }
    }

    // MARK: - What is on the screen

    /// The invitation itself, at a size another phone's camera can read.
    private func codeSection(qr: CGImage) -> some View {
        Section {
            Image(decorative: qr, scale: 1)
                // A QR code is a grid of black squares, and a smoothed one is a grid of grey
                // smudges: the interpolation that flatters a photograph is what makes a module
                // indistinguishable from the white beside it.
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 260)
                // The drawing carries its own white and its own quiet zone, since what a camera
                // needs around a code is not something a layout can be trusted to leave. The
                // padding here is only what makes it look like a badge.
                .padding(Theme.Space.snug)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel("The invitation, as a QR code")
                .accessibilityIdentifier("addDevice.qrCode")
        } footer: {
            Text("On the other phone, open Crossbar, choose Scan the code, and point it at this.")
        }
    }

    /// The same invitation in words, for a phone whose camera cannot be pointed at the code, and
    /// when it stops working.
    private func wordsSection(_ invitation: DeviceInvitation) -> some View {
        Section {
            LabeledContent("Stops working", value: stopsWorking(invitation))
                .accessibilityIdentifier("addDevice.expiry")

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text("If it cannot scan, this is the same invitation in words:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(invitation.token)
                    .font(.callout.monospaced())
                    // Selectable because the point of these words is to be taken somewhere else:
                    // copied whole, rather than read off a screen and typed from memory.
                    .textSelection(.enabled)
                    .accessibilityIdentifier("addDevice.code")
            }
        } header: {
            Text("The code")
        } footer: {
            Text("It enrols one device, once, and it is only ever for you — a device can invite "
                 + "nobody but the person it belongs to. The QR code also carries your server's "
                 + "address; typed on its own, the code below is the token by itself.")
        }
    }

    /// What the screen says while the service is being asked.
    private var mintingSection: some View {
        Section {
            HStack(spacing: Theme.Space.tight) {
                ProgressView().controlSize(.small)
                Text("Asking your Crossbar for a code…").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("addDevice.minting")
        }
    }

    /// What it says when the service would not hand one over — in the service's own words, which is
    /// how every other failure in this app is reported.
    private func refusalSection(_ refusal: String) -> some View {
        Section {
            Text(refusal)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("addDevice.refusal")

            Button("Try again") { Task { await mint() } }
                .accessibilityIdentifier("addDevice.retry")
        } header: {
            Text("No code yet")
        } footer: {
            Text("A code is asked for each time this screen opens, and the service keeps only a "
                 + "hash of one, so a code that was not read here cannot be shown again.")
        }
    }

    /// What it says once the code on it has died.
    ///
    /// The code goes rather than greys out: a QR code that can still be scanned is one somebody will
    /// still try to scan, and a refusal at the other end would say nothing about why.
    private var expiredSection: some View {
        Section {
            Label("This code has stopped working", systemImage: "clock.badge.exclamationmark")
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("addDevice.expired")

            Button("Ask for a new one") { Task { await mint() } }
                .accessibilityIdentifier("addDevice.retry")
        } footer: {
            Text("A code is deliberately short-lived, so the other phone has to be ready to use it "
                 + "when it is shown.")
        }
    }

    /// When the code stops working, in whatever words can be made of the instant the service gave.
    ///
    /// An instant this app cannot place in time is not a reason to leave the line empty — the code
    /// is a short-lived one either way, and saying nothing would be the one thing this screen must
    /// not do with an expiry.
    private func stopsWorking(_ invitation: DeviceInvitation) -> String {
        let when = Reading.when(invitation.expiresAt)
        return when.isEmpty ? "in a few minutes" : when
    }

    // MARK: - The two things it does

    /// Asks the service for an invitation, and draws the code it answers with.
    ///
    /// Each call replaces whatever was on the screen rather than adding to it. Two live codes on one
    /// screen would be one more than the other phone can read, and the one left up would then be the
    /// only one it could have taken.
    private func mint() async {
        isMinting = true
        refusal = nil
        hasExpired = false
        invitation = nil
        qr = nil

        do {
            let minted = try await session.createDeviceInvitation()
            invitation = minted
            qr = Self.qrImage(for: minted.code)
        } catch {
            // The service's own sentence is in here, behind the status and code this app puts in
            // front of every API failure it shows.
            refusal = error.localizedDescription
        }

        isMinting = false
    }

    /// Waits out the life of the code on the screen.
    ///
    /// The service states an instant rather than a lifetime, so the wait is the difference between
    /// that instant and now. A wait rather than a poll, because nothing about a code changes except
    /// that it dies. A wait interrupted by the screen closing has nothing left to correct.
    private func watchExpiry() async {
        guard let deadline = Reading.instant(invitation?.expiresAt) else { return }
        if deadline <= Date() {
            hasExpired = true
            return
        }

        try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
        if !Task.isCancelled { hasExpired = true }
    }

    /// The code as pixels, at a size and a sharpness a camera can read.
    ///
    /// CoreImage's generator rather than a drawing of our own: the module layout, the quiet zone and
    /// the error correction are the parts a hand-rolled encoder gets subtly wrong, and a code that
    /// is *nearly* right fails on somebody else's camera, where nobody can debug it.
    private static func qrImage(for text: String) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        // Medium correction. This code is read by another phone held up to this screen — a close,
        // clean, deliberate optical path — so the heavier levels would spend modules on damage that
        // cannot happen here, on a payload whose length is the whole of what decides how dense the
        // code ends up.
        generator.correctionLevel = "M"
        guard let code = generator.outputImage else { return nil }

        // Scaled up before it is rasterised, so no module boundary lands on a fraction of a pixel.
        // The view scales it again, without interpolation, to whatever size it is given.
        let module: CGFloat = 10
        let scaled = code.transformed(by: CGAffineTransform(scaleX: module, y: module))

        // The generator leaves a module of quiet zone around a code, and the standard asks for four,
        // so four full modules are added here. The empty margin is much of what lets a camera find
        // the code at all, and it is not something a layout can be trusted to leave later. Drawn
        // white and opaque, which also settles what the code sits on: black on black is a code no
        // camera reads, and this app's dark appearance is one background away from being exactly
        // that.
        let margin = module * 4
        let field = CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -margin, dy: -margin))
        let drawing = scaled.composited(over: field)
        return CIContext().createCGImage(drawing, from: drawing.extent)
    }
}
