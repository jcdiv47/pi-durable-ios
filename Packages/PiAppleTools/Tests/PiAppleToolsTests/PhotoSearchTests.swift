import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import PiAppleTools

/// `App/Models`, where `scripts/fetch-mobileclip.sh` puts the encoders and the tokenizer.
private let models = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../App/Models").standardizedFileURL
private let haveTokenizer = FileManager.default.fileExists(atPath: models.appending(path: "clip-vocab.json").path)
private let haveModels = FileManager.default.fileExists(atPath: models.appending(path: "MobileCLIPText.mlpackage").path)

private func tokenizer() throws -> CLIPTokenizer {
    try CLIPTokenizer(vocab: models.appending(path: "clip-vocab.json"), merges: models.appending(path: "clip-merges.txt"))
}

/// One compile per test run; compiling the text encoder takes a few seconds.
private let encoder: Result<ClipEncoder, Error> = Result {
    let image = try MLModel.compileModel(at: models.appending(path: "MobileCLIPImage.mlpackage"))
    let text = try MLModel.compileModel(at: models.appending(path: "MobileCLIPText.mlpackage"))
    return try ClipEncoder(image: image, text: text, vocab: models.appending(path: "clip-vocab.json"), merges: models.appending(path: "clip-merges.txt"))
}

private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
    return context.makeImage()!
}

@Suite("CLIP tokenizer", .enabled(if: haveTokenizer))
struct CLIPTokenizerTests {
    @Test("Encodes like OpenAI's CLIP: start, BPE pieces, end, zero padding to 77")
    func knownIds() throws {
        let ids = try tokenizer().encode("A photo of a CAT")
        #expect(Array(ids.prefix(7)) == [49406, 320, 1125, 539, 320, 2368, 49407])
        #expect(ids.count == 77)
        #expect(ids.dropFirst(7).allSatisfy { $0 == 0 })
    }

    @Test("Long text is cut to 75 tokens between the markers; unusual characters still encode")
    func long() throws {
        let tokenizer = try tokenizer()
        let ids = tokenizer.encode(String(repeating: "whiteboard diagram ", count: 100))
        #expect(ids.count == 77 && ids.first == 49406 && ids.last == 49407)
        let mixed = tokenizer.encode("café receipt ¥1,980 🍜 拉面")
        #expect(mixed.first == 49406 && mixed.contains(49407) && mixed.filter { $0 != 0 }.count > 6)
    }
}

@Suite("Photo vectors")
struct PhotoVectorsTests {
    private func unit(_ hot: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: ClipEncoder.dimensions)
        vector[hot] = 1
        return vector
    }

    private func entry(_ id: String, day: Int, favorite: Bool = false) -> PhotoVectors.Entry {
        PhotoVectors.Entry(id: id, created: Date(timeIntervalSince1970: Double(day) * 86_400), modified: nil, favorite: favorite, screenshot: false)
    }

    @Test("Ranks by similarity, filters by date and flags, and survives a save")
    func searchAndSave() throws {
        var index = PhotoVectors(model: "test")
        index.upsert(entry("a", day: 1), vector: unit(0))
        index.upsert(entry("b", day: 5, favorite: true), vector: unit(1))
        index.upsert(entry("c", day: 9), vector: zip(unit(0), unit(1)).map { ($0 + $1) / Float(2).squareRoot() })
        #expect(index.search(unit(0), limit: 2).map(\.entry.id) == ["a", "c"])
        #expect(index.search(unit(0), filter: .init(favoritesOnly: true), limit: 5).map(\.entry.id) == ["b"])
        #expect(index.search(unit(0), filter: .init(from: Date(timeIntervalSince1970: 3 * 86_400)), limit: 5).map(\.entry.id) == ["c", "b"])

        index.upsert(entry("a", day: 1), vector: unit(2))
        index.retain(["a", "c"])
        #expect(index.count == 2)
        #expect(index.search(unit(2), limit: 1).first?.entry.id == "a")

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try index.save(to: directory)
        let loaded = PhotoVectors.load(from: directory, model: "test")
        #expect(loaded.entries == index.entries)
        #expect(loaded.search(unit(2), limit: 1).first?.entry.id == "a")
        // Another model's vectors don't mix in.
        #expect(PhotoVectors.load(from: directory, model: "other").count == 0)
    }
}

@Suite("MobileCLIP on this machine", .enabled(if: haveModels), .serialized)
struct ClipEncoderTests {
    @Test("Text and image land in one space: each color matches its own words best", .timeLimit(.minutes(2)))
    func colors() throws {
        let clip = try encoder.get()
        let red = try clip.embed(image: solid(0.9, 0.05, 0.05))
        let blue = try clip.embed(image: solid(0.05, 0.1, 0.9))
        #expect(red.count == 512)
        #expect(abs(red.reduce(0) { $0 + $1 * $1 } - 1) < 0.01)
        let redText = try clip.embed(text: "a plain red square")
        let blueText = try clip.embed(text: "a plain blue square")
        let dot = { (a: [Float], b: [Float]) in zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(dot(red, redText) > dot(red, blueText))
        #expect(dot(blue, blueText) > dot(blue, redText))
    }
}
