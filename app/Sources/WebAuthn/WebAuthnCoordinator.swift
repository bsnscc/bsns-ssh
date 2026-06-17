import Foundation
import AuthenticationServices
import UIKit
import BsnsSSHCore

enum WebAuthnError: LocalizedError {
    case busy
    case unsupportedOS
    case noAnchor
    case unexpectedCredential
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Another security-key request is already in progress."
        case .unsupportedOS: return "FIDO2 security keys require iOS 16 or later."
        case .noAnchor: return "No window available to present the security-key prompt."
        case .unexpectedCredential: return "The security key returned an unexpected response."
        case .cancelled: return "The security-key request was cancelled."
        case let .failed(detail): return "Security key error — \(detail)"
        }
    }
}

/// Drives FIDO2 security keys through Apple's WebAuthn API
/// (`ASAuthorizationSecurityKeyPublicKeyCredentialProvider`), which handles CTAP2
/// over USB-C / NFC / Lightning. Registration yields an `sk-ecdsa-sha2-nistp256`
/// public key; each sign is a WebAuthn assertion turned into a
/// `webauthn-sk-ecdsa-sha2-nistp256@openssh.com` signature (see
/// `BsnsSSHCore.WebAuthnSignature`). The private key never leaves the token.
///
/// The relying-party id is a fixed domain (`tools.bsns.cc`) we control; it becomes
/// the `application=` field baked into the key. (Apple's WebAuthn API requires a
/// domain rpId — an `ssh:`-style application string isn't usable here.)
@MainActor
final class WebAuthnCoordinator: NSObject {
    static let shared = WebAuthnCoordinator()
    static let relyingPartyID = "tools.bsns.cc"

    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    /// Register a new resident credential; returns the SSH public-key blob, the
    /// credential id (needed for later assertions), and the application (rpId).
    func enroll(name: String) async throws -> (publicBlob: Data, credentialID: Data, application: String) {
        guard #available(iOS 16.0, *) else { throw WebAuthnError.unsupportedOS }
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID)
        var challenge = Data(count: 32)
        _ = challenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let userID = Data((name.isEmpty ? "bsns" : name).utf8)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, displayName: name, name: name, userID: userID)
        request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]

        let authorization = try await perform(request)
        guard let reg = authorization.credential
            as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration,
              let attestation = reg.rawAttestationObject else {
            throw WebAuthnError.unexpectedCredential
        }
        let blob = try WebAuthnSignature.publicKeyBlob(
            fromAttestationObject: attestation, application: Self.relyingPartyID)
        return (blob, reg.credentialID, Self.relyingPartyID)
    }

    /// Produce a `webauthn-sk-ecdsa` SSH signature blob over `data` using the
    /// credential identified by `credentialID`. Blocks on a user tap (+ PIN/UV if
    /// the key requires it). The returned blob is complete (its own format string +
    /// trailer) — the caller sends it verbatim via `libssh2_userauth_publickey_raw`.
    func assert(data: Data, credentialID: Data) async throws -> Data {
        guard #available(iOS 16.0, *) else { throw WebAuthnError.unsupportedOS }
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: data)
        request.allowedCredentials = [
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                credentialID: credentialID, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
        ]

        let authorization = try await perform(request)
        guard let assertion = authorization.credential
            as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion,
              let signature = assertion.signature else {
            throw WebAuthnError.unexpectedCredential
        }
        let (flags, counter) = try WebAuthnSignature.authenticatorFlagsAndCounter(assertion.rawAuthenticatorData)
        // Forward the authenticator's extension bytes verbatim — the server folds
        // them into the signed message and the ED flag must agree with their presence.
        let extensions = WebAuthnSignature.authenticatorExtensions(assertion.rawAuthenticatorData)
        let origin = Self.origin(fromClientDataJSON: assertion.rawClientDataJSON)
            ?? "https://\(Self.relyingPartyID)"
        return try WebAuthnSignature.signatureBlob(
            derSignature: signature, flags: flags, counter: counter,
            origin: origin, clientDataJSON: assertion.rawClientDataJSON, extensions: extensions)
    }

    // Run one ASAuthorization request, bridging the delegate callbacks to async.
    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        guard continuation == nil else { throw WebAuthnError.busy }
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    /// Parse the `origin` field out of the WebAuthn clientDataJSON.
    private static func origin(fromClientDataJSON data: Data) -> String? {
        struct ClientData: Decodable { let origin: String }
        return (try? JSONDecoder().decode(ClientData.self, from: data))?.origin
    }
}

extension WebAuthnCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            finish(.failure(WebAuthnError.cancelled))
        } else {
            finish(.failure(WebAuthnError.failed(error.localizedDescription)))
        }
    }
}

extension WebAuthnCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }
}
