import CoreFoundation
import Foundation

/// Strict LF-delimited JSONL framing for Pi RPC exchanges.
///
/// Pi documents its RPC mode as strict JSONL with LF as the only record
/// delimiter. This decoder therefore:
///
/// - splits on the byte `0x0A` only, never on CR or Unicode line separators;
/// - tolerates a `\r\n` pair by stripping exactly one trailing `\r` per Pi's
///   framing contract, and rejects every other raw `\r` as a CR-only separator;
/// - does not split on U+2028/U+2029, which are valid inside JSON strings;
///   using one as a record separator yields a frame that is not valid JSON and
///   is rejected as malformed;
/// - rejects empty records and records that are not JSON objects;
/// - stops with `frameTooLarge` once an unterminated buffer exceeds the limit;
/// - rejects a trailing partial frame when the stream ends without a final LF.
///
/// The decoder is one-directional: it never repairs, resynchronizes, or drops
/// content. After a framing error the caller stops the exchange.
enum JSONLFraming {
    /// Maximum size of one frame in bytes. Bounded so a hostile or broken peer
    /// cannot exhaust memory with an unterminated line.
    static let maxFrameBytes = 1_048_576

    enum FrameError: Error, Equatable, Sendable {
        case framingError
        case frameTooLarge
        case malformedJSON
        case trailingPartialFrame
        case streamAlreadyFinished
    }
}

/// Incremental inbound decoder. Feed chunks; collect complete frames.
struct JSONLFrameDecoder: Sendable {
    private var buffer = Data()
    private var finished = false

    mutating func feed(_ chunk: Data) throws -> [Data] {
        guard !finished else {
            throw JSONLFraming.FrameError.streamAlreadyFinished
        }
        buffer.append(chunk)
        return try extractCompleteFrames()
    }

    /// Ends the stream. Any trailing bytes without a final LF are a framing
    /// error; silently accepting a partial frame would hide truncated output.
    mutating func finish() throws {
        finished = true
        guard buffer.isEmpty else {
            buffer.removeAll()
            throw JSONLFraming.FrameError.trailingPartialFrame
        }
    }

    private mutating func extractCompleteFrames() throws -> [Data] {
        var frames: [Data] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            var payload = buffer.subdata(in: buffer.startIndex ..< newline)

            // Tolerate one trailing CR: a peer using \r\n line endings.
            if payload.last == 0x0D {
                payload.removeLast()
            }

            // Any remaining raw \r is a CR-only separator or embedded control
            // character, both framing violations for LF-delimited JSONL.
            if payload.contains(where: { $0 == 0x0D }) {
                buffer.removeAll()
                throw JSONLFraming.FrameError.framingError
            }

            guard payload.count <= JSONLFraming.maxFrameBytes else {
                buffer.removeAll()
                throw JSONLFraming.FrameError.frameTooLarge
            }

            buffer.removeSubrange(buffer.startIndex ... newline)
            frames.append(payload)
            _ = try Self.decode(payload)
        }

        try validateBufferLimit()
        return frames
    }

    private mutating func validateBufferLimit() throws {
        if buffer.count > JSONLFraming.maxFrameBytes {
            buffer.removeAll()
            throw JSONLFraming.FrameError.frameTooLarge
        }
    }

    /// Decodes one complete frame into a JSON object. Called for every frame so
    /// malformed JSON is rejected at the framing boundary.
    static func decode(_ payload: Data) throws -> JSONValue {
        guard !payload.isEmpty else {
            throw JSONLFraming.FrameError.malformedJSON
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            throw JSONLFraming.FrameError.malformedJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw JSONLFraming.FrameError.malformedJSON
        }
        guard case let .object(root) = JSONValue(object) else {
            throw JSONLFraming.FrameError.malformedJSON
        }
        return .object(root)
    }
}

/// A sendable JSON value tree parsed from one frame.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ any: Any) {
        if any is NSNull {
            self = .null
        } else if let value = any as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        } else if let value = any as? String {
            self = .string(value)
        } else if let value = any as? [Any] {
            self = .array(value.map { JSONValue($0) })
        } else if let value = any as? [String: Any] {
            self = .object(value.mapValues { JSONValue($0) })
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(values) = self else {
            return nil
        }
        return values[key]
    }
}

/// Encodes one outbound request frame. Values that would break LF-delimited
/// framing when decoded are escaped so the frame survives its own decoder.
enum JSONLOutgoing {
    static func encode(_ object: [String: JSONValue]) throws -> Data {
        let mirror = object.mapValues(\.anyRepresentation)
        guard JSONSerialization.isValidJSONObject(mirror),
              let data = try? JSONSerialization.data(withJSONObject: mirror)
        else {
            throw JSONLFraming.FrameError.malformedJSON
        }
        var text = String(decoding: data, as: UTF8.self)
        // Keep Unicode line separators inside string values from becoming
        // protocol-relevant bytes.
        text = text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let frame = Data(text.utf8)
        guard frame.count <= JSONLFraming.maxFrameBytes else {
            throw JSONLFraming.FrameError.frameTooLarge
        }
        return frame + Data([0x0A])
    }
}

private extension JSONValue {
    var anyRepresentation: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .number(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map(\.anyRepresentation)
        case let .object(values):
            values.mapValues(\.anyRepresentation)
        }
    }
}
