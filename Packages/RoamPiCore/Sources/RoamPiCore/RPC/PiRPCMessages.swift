import Foundation

/// A Pi RPC request encoded as one LF-delimited JSONL frame.
/// Shapes come from Pi's RPC mode documentation: `{"id": "...", "type": "..."}`.
public struct PiRPCRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case getState
        case prompt(String)
        case abort
    }

    static let maximumMessageBytes = 256 * 1024

    public let identifier: String
    public let kind: Kind

    public init(identifier: String, kind: Kind) {
        self.identifier = identifier
        self.kind = kind
    }

    var expectedResponseCommand: String {
        switch kind {
        case .getState: "get_state"
        case .prompt: "prompt"
        case .abort: "abort"
        }
    }

    /// Encodes the request as one bounded frame ending with LF.
    func encodedFrame() throws -> Data {
        let object: [String: JSONValue]
        switch kind {
        case .getState:
            object = ["id": .string(identifier), "type": .string("get_state")]
        case let .prompt(message):
            let bytes = Data(message.utf8).count
            guard bytes <= Self.maximumMessageBytes else {
                throw JSONLFraming.FrameError.frameTooLarge
            }
            object = [
                "id": .string(identifier),
                "type": .string("prompt"),
                "message": .string(message),
            ]
        case .abort:
            object = ["id": .string(identifier), "type": .string("abort")]
        }
        return try JSONLOutgoing.encode(object)
    }
}

/// One decoded inbound frame classified against Pi RPC's documented shapes.
public struct PiRPCFrame: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        /// `{"type": "response", "command": "...", "success": ..., "data": ...}`
        case response(command: String, success: Bool, data: JSONValue?)
        /// Any other object; events stream alongside responses.
        case event(type: String, payload: JSONValue)
    }

    public let identifier: String?
    let body: Body

    /// True when this frame answers the request with the given identifier.
    public func answers(_ identifier: String) -> Bool {
        self.identifier == identifier
    }

    /// True for a successful response with the given command name.
    public func isSuccessResponse(command: String) -> Bool {
        if case let .response(commandName, success, _) = body {
            return commandName == command && success
        }
        return false
    }
}

enum PiRPCFrameDecoder {
    /// Decodes one validated JSON frame into a typed RPC frame.
    static func decode(_ frame: JSONValue) -> PiRPCFrame? {
        guard case let .object(fields) = frame else {
            return nil
        }
        let identifier = fields["id"]?.stringValue
        switch fields["type"]?.stringValue {
        case "response":
            guard let command = fields["command"]?.stringValue,
                  let success = fields["success"]?.boolValue
            else {
                return nil
            }
            return PiRPCFrame(
                identifier: identifier,
                body: .response(command: command, success: success, data: fields["data"])
            )
        case let .some(type):
            return PiRPCFrame(identifier: identifier, body: .event(type: type, payload: .object(fields)))
        case nil:
            return nil
        }
    }
}
