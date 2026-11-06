// swift-tools-version: 6.0
// AliasSupport: the Swift client of ALIAS, for iOS and macOS. An app adds
// .package(url: "https://github.com/emdzej/alias-client-swift", from: "X.Y.Z") and depends on AliasSupport
// (the client) and AliasSupportUI (the SwiftUI views). Published from ALIAS's clients/swift at each
// release; its tests run there, against the service.
import PackageDescription

let package = Package(
    name: "AliasSupport",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "AliasSupport", targets: ["AliasSupport"]),
        .library(name: "AliasSupportUI", targets: ["AliasSupportUI"]),
    ],
    targets: [
        .target(name: "AliasSupport"),
        .target(name: "AliasSupportUI", dependencies: ["AliasSupport"]),
    ]
)
