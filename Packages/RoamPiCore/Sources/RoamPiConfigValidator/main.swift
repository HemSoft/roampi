import Foundation
import RoamPiCore

private enum ValidatorCommandError: Error, CustomStringConvertible {
    case invalidArguments
    case unreadableFile
    case unexpectedResult

    var description: String {
        switch self {
        case .invalidArguments:
            "usage: RoamPiConfigValidator [--expect code@location] (--machine <file> | --project-root <root> <file>)"
        case .unreadableFile:
            "configuration file could not be read"
        case .unexpectedResult:
            "configuration result did not match the expectation"
        }
    }
}

@main
private enum RoamPiConfigValidatorCommand {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var expectation: (code: String, location: String)?
        if arguments.first == "--expect" {
            guard arguments.count >= 3 else { throw ValidatorCommandError.invalidArguments }
            let value = arguments[1].split(separator: "@", maxSplits: 1).map(String.init)
            guard value.count == 2 else { throw ValidatorCommandError.invalidArguments }
            expectation = (value[0], value[1])
            arguments.removeFirst(2)
        }

        let source: RoamPiConfigurationSource
        let path: String
        if arguments.count == 2, arguments[0] == "--machine" {
            source = .machine
            path = arguments[1]
        } else if arguments.count == 3, arguments[0] == "--project-root" {
            source = .project(root: arguments[1])
            path = arguments[2]
        } else {
            throw ValidatorCommandError.invalidArguments
        }

        guard let data = FileManager.default.contents(atPath: path) else {
            throw ValidatorCommandError.unreadableFile
        }
        let result = RoamPiConfigurationParser.parse(data, source: source)
        if let expectation {
            guard result.configuration == nil,
                  result.diagnostics.contains(where: {
                      $0.code.rawValue == expectation.code && $0.location == expectation.location
                  })
            else {
                throw ValidatorCommandError.unexpectedResult
            }
            print("expected-invalid \(path) \(expectation.code) \(expectation.location)")
        } else {
            guard result.configuration != nil, result.diagnostics.isEmpty else {
                for diagnostic in result.diagnostics {
                    print("invalid \(path) \(diagnostic.code.rawValue) \(diagnostic.location)")
                }
                throw ValidatorCommandError.unexpectedResult
            }
            print("valid \(path)")
        }
    }
}
