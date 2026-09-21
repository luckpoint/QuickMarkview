// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickMarkview",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QuickMarkview", targets: ["QuickMarkview"])
    ],
    targets: [
        .executableTarget(
            name: "QuickMarkview",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "QuickMarkviewTests",
            dependencies: ["QuickMarkview"]
        )
    ]
)
