// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Strand", platforms: [.macOS(.v14)], products: [.executable(name: "Strand", targets: ["Strand"])], dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")], targets: [
.target(name: "StrandCore"),
.executableTarget(name: "Strand", dependencies: ["StrandCore", .product(name: "Sparkle", package: "Sparkle")], exclude: ["Resources"], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
.executableTarget(name: "StrandChecks", dependencies: ["StrandCore"], path: "Tests/StrandCoreTests")])
