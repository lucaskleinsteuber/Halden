import CryptoKit
import Foundation
import Security

/// The server's certificate is its own, not from a certificate authority. The app trusts exactly
/// the one whose SHA-256 it was given when pairing (or that the person confirmed when signing in
/// with a password), like `tls::Fingerprint` on the server: SHA-256 of the certificate (DER),
/// lowercase hex.
public enum Fingerprint {
    public static func of(certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public static func of(trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        return of(certificate: leaf)
    }

    public static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    /// Groups of four, as `halden status` shows it: `3FA9 0C1D …`.
    public static func display(_ value: String) -> String {
        let upper = value.uppercased()
        return stride(from: 0, to: upper.count, by: 4).map { offset -> String in
            let start = upper.index(upper.startIndex, offsetBy: offset)
            let end = upper.index(start, offsetBy: min(4, upper.distance(from: start, to: upper.endIndex)))
            return String(upper[start..<end])
        }.joined(separator: " ")
    }
}

/// What a connection trusts.
public enum Trust: Sendable, Equatable {
    /// Only the certificate with this fingerprint.
    case pinned(String)
    /// Any certificate, but its fingerprint is noted: only to show it to the person before they
    /// sign in with a password, never to send anything secret.
    case inspect
}

/// Checks the server's certificate for every connection of a session.
final class TrustDelegate: NSObject, URLSessionDelegate, Sendable {
    let trust: Trust
    private let seen = Seen()

    init(trust: Trust) {
        self.trust = trust
    }

    /// The fingerprint of the last certificate presented (for `.inspect`).
    var lastFingerprint: String? { seen.value }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust,
            let fingerprint = Fingerprint.of(trust: serverTrust)
        else {
            return (.cancelAuthenticationChallenge, nil)
        }
        seen.value = fingerprint
        switch trust {
        case .pinned(let expected) where expected.lowercased() == fingerprint:
            return (.useCredential, URLCredential(trust: serverTrust))
        case .inspect:
            return (.useCredential, URLCredential(trust: serverTrust))
        case .pinned:
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}

/// A small thread-safe box.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
