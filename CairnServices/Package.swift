// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CairnServices",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "CairnServices", targets: ["CairnServices"])
  ],
  dependencies: [
    .package(path: "../MeshCore")
  ],
  targets: [
    .target(
      name: "CairnServices",
      dependencies: ["MeshCore"]
    ),
    .testTarget(
      name: "CairnServicesTests",
      dependencies: [
        "CairnServices",
        .product(name: "MeshCoreTestSupport", package: "MeshCore")
      ]
    )
  ]
)
