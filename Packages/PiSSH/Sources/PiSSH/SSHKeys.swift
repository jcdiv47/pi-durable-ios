@preconcurrency import Citadel
import CryptoKit
import Foundation
import NIOSSH

/// Keys: generating the app's Ed25519 key pair, reading imported OpenSSH private keys, and host key fingerprints.
///
/// Only Ed25519 user keys: Citadel signs RSA logins with SHA-1 (`ssh-rsa`), which OpenSSH 8.8 and later refuse by
/// default, and it reads no OpenSSH ECDSA private keys.
public enum SSHKeys {
    /// A new key pair: the OpenSSH private key (for the Keychain) and its public key line (for `authorized_keys`).
    public static func generate(comment: String) -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.makeSSHRepresentation(comment: comment), publicKeyLine(key.publicKey, comment: comment))
    }

    static func publicKeyLine(_ key: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(key.rawRepresentation)
        let line = "ssh-ed25519 \(blob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// What an imported private key is: its type and public key line, read from the key file's header (which is not
    /// encrypted, even when the key is).
    public struct Info: Sendable, Equatable {
        public let type: String
        public let publicKey: String
        public let encrypted: Bool
    }

    public static func info(ofPrivateKey text: String) throws -> Info {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        guard trimmed.hasPrefix(begin), trimmed.hasSuffix(end) else {
            if trimmed.hasPrefix("-----BEGIN") { throw SSHFailure("This is not an OpenSSH key. Convert it with “ssh-keygen -p -f <key>”, or make a new one with “ssh-keygen -t ed25519”.") }
            throw SSHFailure("This doesn't look like a private key. It starts with “\(begin)”.")
        }
        let body = trimmed.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else { throw SSHFailure("The key's text is damaged.") }
        var reader = SSHReader(data)
        guard reader.bytes(15) == Data("openssh-key-v1\0".utf8),
              let cipher = reader.string(), let _ = reader.string(), let _ = reader.string(),
              let count = reader.uint32(), count == 1,
              let blob = reader.string()
        else { throw SSHFailure("The key's text is damaged.") }
        var blobReader = SSHReader(blob)
        guard let type = blobReader.string().map({ String(decoding: $0, as: UTF8.self) }) else { throw SSHFailure("The key's text is damaged.") }
        return Info(type: type, publicKey: "\(type) \(blob.base64EncodedString())", encrypted: String(decoding: cipher, as: UTF8.self) != "none")
    }

    /// Checks that a private key can be used, decrypting it with `passphrase`; returns its public key line.
    @discardableResult
    public static func check(privateKey: String, passphrase: String?) throws -> String {
        let info = try info(ofPrivateKey: privateKey)
        _ = try ed25519(privateKey, passphrase: passphrase, info: info)
        return info.publicKey
    }

    static func ed25519(_ privateKey: String, passphrase: String?, info: Info) throws -> Curve25519.Signing.PrivateKey {
        guard info.type == "ssh-ed25519" else {
            throw SSHFailure("Pi only uses Ed25519 keys, and this is \(info.type). Make one with “ssh-keygen -t ed25519”, or let Pi make one.")
        }
        if info.encrypted && (passphrase ?? "").isEmpty { throw SSHFailure("This key is encrypted. Enter its passphrase.") }
        do {
            return try Curve25519.Signing.PrivateKey(
                sshEd25519: privateKey.trimmingCharacters(in: .whitespacesAndNewlines),
                decryptionKey: info.encrypted ? passphrase.map { Data($0.utf8) } : nil
            )
        } catch {
            throw SSHFailure(info.encrypted ? "The passphrase is wrong, or the key's encryption isn't supported." : "The key can't be read: \(error)")
        }
    }

    static func authentication(user: String, secret: SSHSecret) throws -> SSHAuthenticationMethod {
        switch secret {
        case let .password(password):
            return .passwordBased(username: user, password: password)
        case let .key(privateKey, passphrase):
            let key = try ed25519(privateKey, passphrase: passphrase, info: info(ofPrivateKey: privateKey))
            return .ed25519(username: user, privateKey: key)
        }
    }

    /// An OpenSSH public key line for a key the server sent.
    static func line(_ key: NIOSSHPublicKey) -> String { String(openSSHPublicKey: key) }

    /// The key type and base64 blob of a public key line, without its comment.
    public static func normalized(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true).prefix(2).joined(separator: " ")
    }

    /// `SHA256:<base64 without padding>`, as `ssh-keygen -l` and `ssh` print it.
    public static func fingerprint(ofPublicKey line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }

    /// The key type a public key line starts with, for display: `ssh-ed25519` → `ED25519`.
    public static func typeName(ofPublicKey line: String) -> String {
        switch line.split(separator: " ").first.map(String.init) {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case let type?: type.hasPrefix("ecdsa-sha2-") ? "ECDSA" : type
        case nil: "?"
        }
    }
}

/// An error with a message the user or the model can read.
public struct SSHFailure: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

struct SSHReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func uint32() -> UInt32? {
        bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }

    mutating func string() -> Data? {
        uint32().flatMap { bytes(Int($0)) }
    }
}

extension Data {
    mutating func appendSSHString(_ value: Data) {
        let count = UInt32(value.count)
        append(contentsOf: [UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
        append(value)
    }
}
