// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CairnUpdateKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CairnUpdateKit", targets: ["CairnUpdateKit"]),
        .executable(name: "cairn-update", targets: ["cairn-update"]),
    ],
    targets: [
        .target(name: "CairnUpdateKit"),
        .executableTarget(name: "cairn-update", dependencies: ["CairnUpdateKit"]),
        .testTarget(name: "CairnUpdateKitTests", dependencies: ["CairnUpdateKit"]),
    ]
)
