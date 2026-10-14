// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Leaf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Leaf", targets: ["Leaf"])],
    targets: [
        .executableTarget(
            name: "Leaf",
            path: ".",
            exclude: [
                "Tests", "scripts", "docs", "dist", "README.md", "LICENSE",
                "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md"
            ],
            sources: ["Sources/Leaf"],
            resources: [
                .copy("Resources/Welcome.pdf"),
                .copy("Resources/LeafMark.png"),
                .copy("Resources/Leaf.icns")
            ]
        ),
        .testTarget(name: "LeafTests", dependencies: ["Leaf"], path: "Tests/LeafTests")
    ]
)
