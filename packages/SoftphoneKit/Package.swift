// swift-tools-version:6.0
import PackageDescription

// SoftphoneKit: everything that is not UI. Wraps linphone-sdk (ADR-0001) behind CallEngine,
// talks to the control plane (PlatformAPI, later phases) and keeps credentials in the Keychain.
// iOS only: the linphone-sdk-swift-ios binaries are iOS xcframeworks, so `swift test` on macOS
// does not work; run the tests through the app's SoftphoneTests target on a simulator (make test).
let package = Package(
    name: "SoftphoneKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SoftphoneKit", targets: ["SoftphoneKit"]),
    ],
    dependencies: [
        // Pinned exactly (S12/R1). "-novideo" = same SDK without the video codecs (ADR-0001).
        // GitHub mirror of gitlab.linphone.org/BC/public/linphone-sdk-swift-ios (same tags); the GitLab
        // host refused connections repeatedly on 2026-09-14. Binaries come from download.linphone.org.
        .package(url: "https://github.com/BelledonneCommunications/linphone-sdk-swift-ios.git", exact: "5.5.21-novideo"),
    ],
    targets: [
        .target(
            name: "SoftphoneKit",
            dependencies: [
                .product(name: "linphonesw", package: "linphone-sdk-swift-ios"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
