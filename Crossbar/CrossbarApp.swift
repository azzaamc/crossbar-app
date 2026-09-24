//
//  CrossbarApp.swift
//  Crossbar
//
//  Created by Azzaam Chaudhry on 9/16/26.
//

import SwiftUI

@main
struct CrossbarApp: App {
    /// The app delegate, which exists for the two things UIKit still owns.
    ///
    /// `@UIApplicationDelegateAdaptor` is the only way a SwiftUI `App` can hand UIKit an object
    /// of its own, and this app needs one for two jobs. PushKit's registry has to be in place
    /// before any screen is, because a push may be what launched the app. The notification
    /// permission and the device token that carries a missed call are granted and issued to the
    /// app rather than to a screen, and both arrive through `UIApplication`. See `AppDelegate`
    /// for why neither is handled in `CallKitController` or `CallSession`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
