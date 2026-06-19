import Foundation
import UIKit
import CoreNFC
import CryptoKit
import Security
import YubiKit
import BsnsSSHCore

enum Fido2Error: LocalizedError {
    case locked
    case unsupportedKey
    case noConnection
    case noCredential
    case stageFailed(stage: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .locked:
            return "Enter the security key's FIDO2 PIN in Keys, then try again."
        case .unsupportedKey:
            return "That security key did not return an ES256 P-256 FIDO2 credential."
        case .noConnection:
            return "Couldn't reach a FIDO2 security key. On iPad, plug it into USB-C; on iPhone, plug it in or hold it to the top to tap over NFC."
        case .noCredential:
            return "No portable bsns.SSH FIDO2 credential was found on that security key."
        case let .stageFailed(stage, detail):
            return "Security key \(stage) failed - \(detail)"
        }
    }
}

private func fidoDetail(_ error: Error) -> String {
    if let fido = error as? Fido2Error {
        return fido.errorDescription ?? String(describing: fido)
    }
    if let ctap = error as? CTAP2.SessionError {
        switch ctap {
        case let .ctapError(code, _):
            return "CTAP \(code)"
        case let .failedResponse(response, _):
            return "card status \(response.responseStatus.status)"
        case let .connectionError(connection, _):
            return "connection \(connection)"
        case let .fidoConnectionError(connection, _):
            return "FIDO connection \(connection)"
        case let .illegalArgument(message, _),
             let .responseParseError(message, _),
             let .dataProcessingError(message, _):
            return message
        default:
            return String(describing: ctap)
        }
    }
    let ns = error as NSError
    var parts: [String] = []
    let desc = ns.localizedDescription
    if !desc.isEmpty, !desc.lowercased().contains("couldn’t be completed"),
       !desc.lowercased().contains("couldn't be completed") {
        parts.append(desc)
    }
    parts.append("\(ns.domain) \(ns.code)")
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        parts.append("<- \(underlying.domain) \(underlying.code)")
    }
    return parts.joined(separator: " · ")
}

private func needsPinRetry(_ error: Error) -> Bool {
    guard let ctap = error as? CTAP2.SessionError,
          case let .ctapError(code, _) = ctap else { return false }
    switch code {
    case .puatRequired, .pinAuthInvalid, .pinTokenExpired, .operationDenied, .unsupportedOption, .invalidOption:
        return true
    default:
        return false
    }
}

/// Native CTAP2/OpenSSH FIDO2 driver for portable security-key credentials.
/// Uses the same application string as Android (`ssh:bsns`) so the public key
/// and signature format match across phones when the resident credential is the
/// same credential on the same physical key.
@MainActor
@Observable
final class Fido2Coordinator {
    static let shared = Fido2Coordinator()
    nonisolated static let application = "ssh:bsns"
    private static let relyingPartyName = "bsns.SSH"

    struct Enrollment {
        let publicBlob: Data
        let credentialID: Data
        let application: String
    }

    private var pin: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
    }

    func lock() { pin = nil }

    private func open() async throws -> SmartCardConnection {
        do {
            if let device = try await USBSmartCardConnection.availableDevices().first {
                do { return try await USBSmartCardConnection(slot: device) }
                catch { throw Fido2Error.stageFailed(stage: "USB-C connection", detail: fidoDetail(error)) }
            }
        } catch let e as Fido2Error {
            throw e
        } catch {
            throw Fido2Error.stageFailed(stage: "USB-C enumeration", detail: fidoDetail(error))
        }
        guard NFCReaderSession.readingAvailable else { throw Fido2Error.noConnection }
        do { return try await NFCSmartCardConnection(alertMessage: "Hold your security key to the top of your phone") }
        catch { throw Fido2Error.stageFailed(stage: "NFC connection", detail: fidoDetail(error)) }
    }

    private func openSession() async throws -> (SmartCardConnection, CTAP2.Session) {
        let conn = try await open()
        do {
            let session = try await CTAP2.Session.makeSession(connection: conn, application: .fido2)
            return (conn, session)
        } catch {
            await conn.close(error: nil)
            throw Fido2Error.stageFailed(stage: "FIDO2 applet select", detail: fidoDetail(error))
        }
    }

    func enroll(pin: String, name: String) async throws -> Enrollment {
        let pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else { throw Fido2Error.locked }
        let (conn, session) = try await openSession()
        defer { Task { await conn.close(error: nil) } }

        let token: CTAP2.Token
        do {
            token = try await session.getPinUVToken(
                using: .pin(pin),
                permissions: [.makeCredential],
                rpId: Self.application)
        } catch {
            throw Fido2Error.stageFailed(stage: "PIN verify", detail: fidoDetail(error))
        }

        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = label.isEmpty ? "bsns" : label
        let params = CTAP2.MakeCredential.Parameters(
            clientDataHash: try Self.randomData(count: 32),
            rp: WebAuthn.RelyingParty(id: Self.application, name: Self.relyingPartyName),
            user: WebAuthn.User(id: try Self.randomData(count: 16),
                                name: displayName,
                                displayName: displayName),
            pubKeyCredParams: [.es256],
            rk: true
        )

        do {
            let response = try await session.makeCredential(parameters: params, token: token).value
            guard let credential = response.authenticatorData.attestedCredentialData else {
                throw Fido2Error.unsupportedKey
            }
            let blob = try Self.publicBlob(from: credential.credentialPublicKey, application: Self.application)
            self.pin = pin
            return Enrollment(publicBlob: blob, credentialID: credential.credentialId, application: Self.application)
        } catch let e as Fido2Error {
            throw e
        } catch {
            throw Fido2Error.stageFailed(stage: "credential creation", detail: fidoDetail(error))
        }
    }

    func importResident(pin: String) async throws -> [Enrollment] {
        let pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else { throw Fido2Error.locked }
        let (conn, session) = try await openSession()
        defer { Task { await conn.close(error: nil) } }

        let token: CTAP2.Token
        do {
            token = try await session.getPinUVToken(
                using: .pin(pin),
                permissions: [.credentialManagement])
        } catch {
            throw Fido2Error.stageFailed(stage: "PIN verify", detail: fidoDetail(error))
        }

        do {
            let credentialManagement = try await session.credentialManagement(token: token)
            var enrollments: [Enrollment] = []
            for try await rp in credentialManagement.rps where rp.rp.id == Self.application {
                for try await credential in credentialManagement.credentials(for: rp.rpIdHash) {
                    let blob = try Self.publicBlob(from: credential.publicKey, application: Self.application)
                    enrollments.append(Enrollment(publicBlob: blob,
                                                  credentialID: credential.credentialId.id,
                                                  application: Self.application))
                }
            }
            guard !enrollments.isEmpty else { throw Fido2Error.noCredential }
            self.pin = pin
            return enrollments
        } catch let e as Fido2Error {
            throw e
        } catch {
            throw Fido2Error.stageFailed(stage: "resident credential import", detail: fidoDetail(error))
        }
    }

    func assert(data: Data, credentialID: Data, application: String) async throws -> Data {
        let (conn, session) = try await openSession()
        defer { Task { await conn.close(error: nil) } }

        let clientDataHash = Data(SHA256.hash(data: data))
        let params = CTAP2.GetAssertion.Parameters(
            rpId: application,
            clientDataHash: clientDataHash,
            allowList: [WebAuthn.CredentialDescriptor(id: credentialID)],
            up: true
        )

        do {
            let response = try await session.getAssertion(parameters: params).value
            return try Self.signatureBlob(from: response)
        } catch {
            guard needsPinRetry(error) else {
                throw Fido2Error.stageFailed(stage: "assertion", detail: fidoDetail(error))
            }
        }

        guard let pin else { throw Fido2Error.locked }
        do {
            let token = try await session.getPinUVToken(
                using: .pin(pin),
                permissions: [.getAssertion],
                rpId: application)
            let response = try await session.getAssertion(parameters: params, token: token).value
            return try Self.signatureBlob(from: response)
        } catch {
            self.pin = nil
            throw Fido2Error.stageFailed(stage: "PIN assertion", detail: fidoDetail(error))
        }
    }

    private static func signatureBlob(from response: CTAP2.GetAssertion.Response) throws -> Data {
        let rawRS = try WebAuthnSignature.rawRS(fromDER: response.signature)
        return SSHKeyFormat.skEcdsaSignatureBlob(
            rawRS: rawRS,
            flags: response.authenticatorData.flags.rawValue,
            counter: response.authenticatorData.signCount)
    }

    private static func publicBlob(from key: COSE.Key, application: String) throws -> Data {
        guard case let .ec2(alg, _, crv, x, y) = key,
              alg == .es256, crv == 1, x.count == 32, y.count == 32 else {
            throw Fido2Error.unsupportedKey
        }
        return SSHKeyFormat.skEcdsaPublicBlob(x963Point: Data([0x04]) + x + y,
                                              application: application)
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        if status != errSecSuccess {
            throw Fido2Error.stageFailed(stage: "random generation", detail: "OSStatus \(status)")
        }
        return data
    }
}
