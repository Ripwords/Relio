// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaxKit",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "TaxKit", targets: ["TaxKit"])
    ],
    targets: [
        .target(
            name: "TaxKit",
            resources: [.copy("Resources/Rules")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TaxKitTests",
            dependencies: ["TaxKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
