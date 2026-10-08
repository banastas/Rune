// swift-tools-version: 6.0
// M0 spikes. Throwaway code; the real engine is written in M1 (PRD §4, §8).
//   nib-spike           S1: what iCloud Drive does for a plain file on macOS 27
//   nib-textspike       S2: TextKit 1 vs TextKit 2 at scratch sizes
//   nib-launch-appkit   S2: launch time and idle memory, AppKit lifecycle
//   nib-launch-swiftui  S2: the same with the SwiftUI App lifecycle
import PackageDescription

let package = Package(
    name: "nib-spike",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "nib-spike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "nib-textspike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "nib-launch-appkit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "nib-launch-swiftui", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
