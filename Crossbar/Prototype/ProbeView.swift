#if DEBUG
import SwiftUI

/// The instruments, kept out of the product's way but still reachable.
///
/// This is how the wire contract, the audio session and the signalling paths get
/// re-measured without ringing anyone — the seam probe, the backend reachability check,
/// the signalling instrument, and the control-plane debug surface, all in one scroll.
struct ProbeView: View {
    @StateObject private var model = CallProbeModel()

    var body: some View {
        AudioSeamView(probe: model.seamProbe, model: model)
    }
}
#endif
