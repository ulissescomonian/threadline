import CryptoKit
import Foundation

public protocol SyncEnvelopeCodec: Sendable {
    func seal(
        _ conversation: ProviderConversation,
        originDeviceID: String,
        createdAt: Date
    ) throws -> SyncEnvelope

    func open(_ envelope: SyncEnvelope) throws -> ProviderConversation
}

public struct PlaintextEnvelopeCodec: SyncEnvelopeCodec {
    public init() {}

    public func seal(
        _ conversation: ProviderConversation,
        originDeviceID: String,
        createdAt: Date = Date()
    ) throws -> SyncEnvelope {
        let payload = try Self.encoder.encode(conversation)
        guard payload.count <= SyncEnvelopeLimits.maximumPayloadBytes else {
            throw ThreadlineError.invalidPayload("Conversation exceeds the safe sync envelope size limit")
        }
        let hash = Self.sha256(payload)
        let envelope = SyncEnvelope(
            id: "conversation:\(conversation.summary.id):\(hash)",
            objectType: "conversation",
            logicalVersion: SyncEnvelopeLimits.legacyFormatVersion,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            encryptedPayload: payload,
            payloadHash: hash
        )
        try Self.validatePayload(conversation, in: envelope)
        return envelope
    }

    public func open(_ envelope: SyncEnvelope) throws -> ProviderConversation {
        try SyncEnvelopeLimits.validate(envelope)
        guard Self.sha256(envelope.encryptedPayload) == envelope.payloadHash else {
            throw ThreadlineError.invalidPayload("Sync envelope payload failed its integrity check")
        }
        do {
            let conversation = try Self.decoder.decode(ProviderConversation.self, from: envelope.encryptedPayload)
            try Self.validatePayload(conversation, in: envelope)
            return conversation
        } catch {
            throw ThreadlineError.invalidPayload("Could not decode conversation envelope: \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validatePayload(_ conversation: ProviderConversation, in envelope: SyncEnvelope) throws {
        guard envelope.objectType == "conversation" else {
            throw ThreadlineError.invalidPayload("Unsupported sync object type: \(envelope.objectType)")
        }
        guard !conversation.summary.id.isEmpty,
              conversation.summary.originDeviceID == envelope.originDeviceID else {
            throw ThreadlineError.invalidPayload("Sync envelope origin does not match its conversation payload")
        }
        let expectedID = "conversation:\(conversation.summary.id):\(envelope.payloadHash)"
        guard envelope.id == expectedID else {
            throw ThreadlineError.invalidPayload("Sync envelope identifier does not match its conversation payload")
        }
        guard conversation.events.allSatisfy({ $0.conversationID == conversation.summary.id }) else {
            throw ThreadlineError.invalidPayload("A sync event references the wrong conversation")
        }
    }
}

public struct EncryptedEnvelopeCodec: SyncEnvelopeCodec {
    private let key: SymmetricKey

    public init(keyData: Data) throws {
        guard keyData.count == 32 else {
            throw ThreadlineError.encryption("The master key must contain exactly 32 bytes")
        }
        self.key = SymmetricKey(data: keyData)
    }

    public func seal(
        _ conversation: ProviderConversation,
        originDeviceID: String,
        createdAt: Date = Date()
    ) throws -> SyncEnvelope {
        do {
            let cleartext = try Self.encoder.encode(conversation)
            guard cleartext.count <= SyncEnvelopeLimits.maximumPayloadBytes else {
                throw ThreadlineError.invalidPayload("Conversation exceeds the safe sync envelope size limit")
            }
            let hash = PlaintextEnvelopeCodec.sha256(cleartext)
            let envelopeID = "conversation:\(conversation.summary.id):\(hash)"
            let prototype = SyncEnvelope(
                id: envelopeID,
                objectType: "conversation",
                logicalVersion: SyncEnvelopeLimits.authenticatedFormatVersion,
                originDeviceID: originDeviceID,
                createdAt: createdAt,
                encryptedPayload: Data(),
                payloadHash: hash
            )
            try PlaintextEnvelopeCodec.validatePayload(conversation, in: prototype)
            let sealed = try AES.GCM.seal(
                cleartext,
                using: key,
                authenticating: try Self.authenticationData(for: prototype)
            )
            guard let combined = sealed.combined else {
                throw ThreadlineError.encryption("AES-GCM did not produce a combined payload")
            }
            guard combined.count <= SyncEnvelopeLimits.maximumPayloadBytes else {
                throw ThreadlineError.invalidPayload("Encrypted conversation exceeds the safe sync envelope size limit")
            }
            return SyncEnvelope(
                id: envelopeID,
                objectType: "conversation",
                logicalVersion: SyncEnvelopeLimits.authenticatedFormatVersion,
                originDeviceID: originDeviceID,
                createdAt: createdAt,
                encryptedPayload: combined,
                payloadHash: hash
            )
        } catch let error as ThreadlineError {
            throw error
        } catch {
            throw ThreadlineError.encryption("Could not encrypt conversation: \(error.localizedDescription)")
        }
    }

    public func open(_ envelope: SyncEnvelope) throws -> ProviderConversation {
        try SyncEnvelopeLimits.validate(envelope)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.encryptedPayload)
            let cleartext: Data
            switch envelope.logicalVersion {
            case SyncEnvelopeLimits.authenticatedFormatVersion:
                cleartext = try AES.GCM.open(
                    box,
                    using: key,
                    authenticating: try Self.authenticationData(for: envelope)
                )
            case SyncEnvelopeLimits.legacyFormatVersion:
                // Compatibility path for envelopes emitted before canonical AAD
                // was introduced. New envelopes never use this format.
                cleartext = try AES.GCM.open(box, using: key)
            default:
                throw ThreadlineError.invalidPayload(
                    "Unsupported encrypted envelope version: \(envelope.logicalVersion)"
                )
            }
            guard PlaintextEnvelopeCodec.sha256(cleartext) == envelope.payloadHash else {
                throw ThreadlineError.invalidPayload("Decrypted sync payload failed its integrity check")
            }
            let conversation = try Self.decoder.decode(ProviderConversation.self, from: cleartext)
            try PlaintextEnvelopeCodec.validatePayload(conversation, in: envelope)
            return conversation
        } catch let error as ThreadlineError {
            throw error
        } catch {
            throw ThreadlineError.encryption("Could not decrypt conversation: \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private struct AuthenticationFields: Encodable {
        let envelopeID: String
        let objectType: String
        let logicalVersion: Int
        let originDeviceID: String
        let createdAtMilliseconds: Int64
        let payloadHash: String
    }

    private static func authenticationData(for envelope: SyncEnvelope) throws -> Data {
        let fields = AuthenticationFields(
            envelopeID: envelope.id,
            objectType: envelope.objectType,
            logicalVersion: envelope.logicalVersion,
            originDeviceID: envelope.originDeviceID,
            createdAtMilliseconds: Int64((envelope.createdAt.timeIntervalSince1970 * 1_000).rounded()),
            payloadHash: envelope.payloadHash
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(fields)
    }
}
