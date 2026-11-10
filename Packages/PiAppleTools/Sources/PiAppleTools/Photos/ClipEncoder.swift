import CoreGraphics
import CoreML
import Foundation
import Vision

/// MobileCLIP's two Core ML encoders: an image or a text query to a unit-length
/// 512-dimensional vector in the same space, so a dot product is their cosine similarity.
public final class ClipEncoder: @unchecked Sendable {
    public static let dimensions = 512

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let imageConstraint: MLImageConstraint
    // Core ML predictions on one model are serialized; indexing and a search may overlap.
    private let lock = NSLock()

    /// Compiled models (`.mlmodelc`) and the tokenizer's files.
    public init(image: URL, text: URL, vocab: URL, merges: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        imageModel = try MLModel(contentsOf: image, configuration: configuration)
        textModel = try MLModel(contentsOf: text, configuration: configuration)
        tokenizer = try CLIPTokenizer(vocab: vocab, merges: merges)
        guard let input = imageModel.modelDescription.inputDescriptionsByName.values.first?.imageConstraint else {
            throw AppleToolError("The MobileCLIP image model takes no image.")
        }
        imageConstraint = input
    }

    public convenience init(_ files: ClipModelFiles) throws {
        try self.init(image: files.image, text: files.text, vocab: files.vocab, merges: files.merges)
    }

    public func embed(text: String) throws -> [Float] {
        let ids = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        for (index, id) in ids.enumerated() { array[index] = NSNumber(value: id) }
        let name = textModel.modelDescription.inputDescriptionsByName.keys.first ?? "text"
        let input = try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: array)])
        return try lock.withLock { try Self.vector(textModel.prediction(from: input)) }
    }

    /// The image center-cropped to the encoder's square input.
    public func embed(image: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(
            cgImage: image,
            constraint: imageConstraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
        )
        let name = imageModel.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let input = try MLDictionaryFeatureProvider(dictionary: [name: value])
        return try lock.withLock { try Self.vector(imageModel.prediction(from: input)) }
    }

    private static func vector(_ output: MLFeatureProvider) throws -> [Float] {
        guard let name = output.featureNames.first, let array = output.featureValue(for: name)?.multiArrayValue, array.count == dimensions else {
            throw AppleToolError("MobileCLIP returned no embedding.")
        }
        var vector = (0 ..< array.count).map { array[$0].floatValue }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { vector = vector.map { $0 / norm } }
        return vector
    }
}
