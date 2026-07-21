import Foundation

/// Creates stable, bounded transport batches without reordering envelopes.
/// The byte budget is based on the encrypted payload because that is the
/// contract enforced by every Threadline transport.
public enum SyncEnvelopeBatcher {
    public static func prefix(
        _ envelopes: [SyncEnvelope],
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> [SyncEnvelope] {
        guard maximumCount > 0, maximumBytes > 0 else {
            throw ThreadlineError.invalidPayload(
                "Synchronization batch limits must be greater than zero."
            )
        }

        var selected: [SyncEnvelope] = []
        selected.reserveCapacity(min(envelopes.count, maximumCount))
        var selectedBytes = 0
        for envelope in envelopes {
            if selected.count == maximumCount { break }
            try SyncEnvelopeLimits.validate(envelope)
            guard envelope.encryptedPayload.count <= maximumBytes else {
                throw ThreadlineError.invalidPayload(
                    "A single encrypted conversation exceeds the transport batch limit."
                )
            }
            let (nextBytes, overflow) = selectedBytes.addingReportingOverflow(
                envelope.encryptedPayload.count
            )
            guard !overflow else {
                throw ThreadlineError.invalidPayload(
                    "The synchronization batch byte count overflowed."
                )
            }
            if !selected.isEmpty, nextBytes > maximumBytes { break }
            selected.append(envelope)
            selectedBytes = nextBytes
        }
        return selected
    }

    public static func batches(
        _ envelopes: [SyncEnvelope],
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> [[SyncEnvelope]] {
        guard maximumCount > 0, maximumBytes > 0 else {
            throw ThreadlineError.invalidPayload(
                "Synchronization batch limits must be greater than zero."
            )
        }

        var result: [[SyncEnvelope]] = []
        var current: [SyncEnvelope] = []
        current.reserveCapacity(min(envelopes.count, maximumCount))
        var currentBytes = 0

        for envelope in envelopes {
            try SyncEnvelopeLimits.validate(envelope)
            guard envelope.encryptedPayload.count <= maximumBytes else {
                throw ThreadlineError.invalidPayload(
                    "A single encrypted conversation exceeds the transport batch limit."
                )
            }
            let (nextBytes, overflow) = currentBytes.addingReportingOverflow(
                envelope.encryptedPayload.count
            )
            guard !overflow else {
                throw ThreadlineError.invalidPayload(
                    "The synchronization batch byte count overflowed."
                )
            }
            if !current.isEmpty,
               (current.count == maximumCount || nextBytes > maximumBytes) {
                result.append(current)
                current = []
                current.reserveCapacity(min(envelopes.count, maximumCount))
                currentBytes = 0
            }
            current.append(envelope)
            currentBytes += envelope.encryptedPayload.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
