//
//  CrossbarApp.swift
//  Crossbar
//
//  Created by Azzaam Chaudhry on 9/16/26.
//

import SwiftUI

@main
struct CrossbarApp: App {
    /// The app delegate, which exists for one reason: PushKit.
    ///
    /// `@UIApplicationDelegateAdaptor` is the only way a SwiftUI `App` can hand UIKit an object
    /// of its own, and PushKit needs one — the registry that receives a VoIP push has to be in
    /// place before any screen is, because the push may be what launched the app. See
    /// `AppDelegate` for why the push handling is not in `CallKitController` or `CallSession`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
