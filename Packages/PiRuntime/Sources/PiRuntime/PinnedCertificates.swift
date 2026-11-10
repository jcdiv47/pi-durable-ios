import CryptoKit
import Foundation
import os
import Security

/// Servers with their own certificates (Proxmox's, from its cluster CA) that the user trusted by the certificate's
/// SHA-256 fingerprint in Settings. For a pinned host only the leaf certificate's fingerprint
/// counts: not its names, not its chain. Every other host keeps the system's checks.
public enum PinnedCertificates {
    private static let pins = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// The trusted fingerprint per host, set from Swift only.
    public static func set(_ pins: [String: String]) {
        let normalized = pins.reduce(into: [String: String]()) { result, pin in
            if let fingerprint = normalize(pin.value) { result[pin.key.lowercased()] = fingerprint }
        }
        self.pins.withLock { $0 = normalized }
    }

    public static func pin(for host: String) -> String? {
        pins.withLock { $0[host.lowercased()] }
    }

    /// `2E:86:E9:…`, as Proxmox shows it (`ssl_fingerprint`, the web UI's Certificates panel) and `openssl x509
    /// -fingerprint -sha256` prints it.
    public static func fingerprint(of certificate: SecCertificate) -> String {
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// A pasted fingerprint in the same form, or nil if it isn't 32 bytes of hex.
    public static func normalize(_ text: String) -> String? {
        let hex = text.uppercased().filter(\.isHexDigit)
        guard hex.count == 64, text.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == " " }) else { return nil }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }

    static func leaf(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    enum Check: Equatable {
        /// The system decides.
        case notPinned
        case match
        /// The fingerprint the server sent.
        case mismatch(String)
    }

    static func check(_ trust: SecTrust, host: String) -> Check {
        guard let pinned = pin(for: host) else { return .notPinned }
        guard let leaf = leaf(of: trust) else { return .mismatch("none") }
        let actual = fingerprint(of: leaf)
        return actual == pinned ? .match : .mismatch(actual)
    }

    /// Answers a server-trust challenge: a pinned host by its fingerprint, others by the system. `mismatch` hears the
    /// fingerprint of a pinned host's wrong certificate, before the challenge is refused.
    static func handle(
        _ challenge: URLAuthenticationChallenge,
        mismatch: (String) -> Void = { _ in }
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        switch check(trust, host: challenge.protectionSpace.host) {
        case .notPinned: return (.performDefaultHandling, nil)
        case .match: return (.useCredential, URLCredential(trust: trust))
        case let .mismatch(actual):
            mismatch(actual)
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    public static func mismatchMessage(host: String, actual: String) -> String {
        "The certificate of \(host) isn't the one trusted in Settings (it sent SHA-256 \(actual)). Nothing was sent. "
            + "If the server renewed its certificate, trust the new one in Settings."
    }
}

/// The certificate a server sends, read without trusting it.
public struct CertificateInfo: Sendable, Equatable {
    public let fingerprint: String
    /// The certificate's subject, as the system summarizes it (its common name).
    public let subject: String?
    /// Whether the system would trust it without a pin.
    public let systemTrusted: Bool
}

public enum CertificateProbe {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Connects only far enough to read the server's certificate, then refuses it, so nothing (no token, no request) is
    /// sent to a server the user hasn't confirmed.
    public static func fetch(_ url: URL, timeout: TimeInterval = 10) async throws -> CertificateInfo {
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw Failure(description: "The address must start with https://.") }
        let reader = Reader()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: url)
        } catch {
            if let info = reader.info.withLock({ $0 }) { return info }
            throw Failure(description: "Couldn't reach \(url.host() ?? "the server"): \(error.localizedDescription)")
        }
        if let info = reader.info.withLock({ $0 }) { return info }
        throw Failure(description: "The server sent no certificate.")
    }

    private final class Reader: NSObject, URLSessionTaskDelegate {
        let info = OSAllocatedUnfairLock<CertificateInfo?>(initialState: nil)

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let leaf = PinnedCertificates.leaf(of: trust) else { return completionHandler(.cancelAuthenticationChallenge, nil) }
            let trusted = SecTrustEvaluateWithError(trust, nil)
            info.withLock {
                $0 = CertificateInfo(
                    fingerprint: PinnedCertificates.fingerprint(of: leaf),
                    subject: SecCertificateCopySubjectSummary(leaf) as String?,
                    systemTrusted: trusted
                )
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// A URLSession delegate that honors the pins, for Swift's own requests to a pinned host (Settings' connection test).
public final class PinnedTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let mismatch = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The fingerprint of the last refused certificate, if a pin refused one.
    public var refusedFingerprint: String? { mismatch.withLock { $0 } }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = PinnedCertificates.handle(challenge) { [mismatch] actual in mismatch.withLock { $0 = actual } }
        completionHandler(disposition, credential)
    }
}
