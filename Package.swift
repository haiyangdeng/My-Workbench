// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyWorkbench",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WorkbenchCore", targets: ["WorkbenchCore"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.0")],
    targets: [
        .target(name: "WorkbenchCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ],
    swiftLanguageModes: [.v5]
)
