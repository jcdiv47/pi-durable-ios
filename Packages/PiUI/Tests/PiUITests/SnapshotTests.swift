import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import PiUI

/// Renders every component in every family it supports and every appearance (Lock Screen families are
/// always tinted) into one sheet per component, and the sample specs likewise, then compares each sheet
/// with its reference in Tests/PiUITests/Snapshots. A missing reference is recorded; `PI_RECORD_SNAPSHOTS=1`
/// re-records them all. References are macOS renders: compare on the same OS release that recorded them.
@Suite("Snapshots", .serialized)
@MainActor
struct SnapshotTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Snapshots")
    static let record = ProcessInfo.processInfo.environment["PI_RECORD_SNAPSHOTS"] == "1"

    init() {
        // Times in the fixtures render as wall-clock times; pin the zone so references match anywhere.
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
    }

    @Test("Component sheets", arguments: Catalog.components.map(\.name))
    func component(_ name: String) throws {
        let families = SurfaceFamily.allCases.filter { Catalog.component(name)!.families.contains($0) }
        let spec = SurfaceSpec(Fixtures.single(name, families: families.filter { $0 != .card }))
        try assertSnapshot(Sheet(spec: spec, families: families, data: Fixtures.data), named: "component-\(name)")
    }

    @Test("Sample spec sheets", arguments: Fixtures.specNames)
    func sample(_ name: String) throws {
        let spec = SurfaceSpec(Fixtures.spec(name))
        try assertSnapshot(Sheet(spec: spec, families: spec.families, data: Fixtures.data), named: "spec-\(name)")
    }

    @Test("Missing data renders placeholders, not nothing")
    func missingData() throws {
        let spec = SurfaceSpec(Fixtures.spec("morning"))
        try assertSnapshot(Sheet(spec: spec, families: spec.families, data: SurfaceData(now: Fixtures.data.now)), named: "spec-morning-nodata")
    }

    @Test("Overflowing content is reported")
    func overflow() {
        let items: JSONValue = .array((1 ... 8).map { ["title": .string("Item \($0)"), "subtitle": "detail"] })
        let spec = SurfaceSpec(["families": ["systemSmall"], "slots": [["c": "Timeline", "items": items, "maxItems": 8]]])
        let warnings = SurfacePreview.layoutWarnings(spec, family: .systemSmall, data: .empty)
        #expect(warnings.first?.contains("systemSmall") == true)
        #expect(SurfacePreview.layoutWarnings(SurfaceSpec(Fixtures.spec("morning")), family: .systemMedium, data: Fixtures.data).isEmpty)
    }

    struct Sheet: View {
        let spec: SurfaceSpec
        let families: [SurfaceFamily]
        let data: SurfaceData

        var body: some View {
            let full = families.filter { !$0.isAccessory }
            let accessories = families.filter(\.isAccessory)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(full.isEmpty ? [] : SurfaceAppearance.allCases, id: \.self) { appearance in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(full) { family in FramedSurface(spec: spec, family: family, appearance: appearance, data: data) }
                    }
                }
                if !accessories.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(accessories) { family in FramedSurface(spec: spec, family: family, appearance: .tinted, data: data) }
                    }
                }
            }
            .padding(12)
            .background(Color(white: 0.55))
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
        }
    }

    func assertSnapshot(_ view: some View, named name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "\(name) did not render")
        let png = try #require(SurfacePreview.pngData(image))
        let reference = Self.directory.appendingPathComponent("\(name).png")
        guard !Self.record, let expected = try? Data(contentsOf: reference) else {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try png.write(to: reference)
            return
        }
        let difference = Self.difference(png, expected)
        if difference > 0.002 {
            let actual = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).actual.png")
            try png.write(to: actual)
            Issue.record("\(name) differs from its reference in \(String(format: "%.2f", difference * 100))% of pixels; actual: \(actual.path)")
        }
    }

    /// Share of pixels that differ visibly (any channel by more than 8 of 255); 1 when the sizes differ.
    static func difference(_ a: Data, _ b: Data) -> Double {
        guard let left = pixels(a), let right = pixels(b), left.width == right.width, left.height == right.height else { return 1 }
        var differing = 0
        for index in stride(from: 0, to: left.bytes.count, by: 4) {
            for channel in 0 ..< 4 where abs(Int(left.bytes[index + channel]) - Int(right.bytes[index + channel])) > 8 {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(left.width * left.height)
    }

    static func pixels(_ png: Data) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }
}
