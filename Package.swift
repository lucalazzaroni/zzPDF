// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "zzPDF",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "zzPDF", targets: ["zzPDF"])
    ],
    targets: [
        .executableTarget(
            name: "zzPDF",
            path: "Sources/zzPDF"
        )
    ]
)
