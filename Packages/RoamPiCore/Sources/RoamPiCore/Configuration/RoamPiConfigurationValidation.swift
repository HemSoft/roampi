import Foundation

public enum RoamPiConfigurationDiagnosticCode: String, Codable, Sendable {
    case documentTooLarge = "document_too_large"
    case nestingTooDeep = "nesting_too_deep"
    case malformedJSON = "malformed_json"
    case unsupportedVersion = "unsupported_version"
    case secretField = "secret_field"
    case missingValue = "missing_value"
    case invalidValue = "invalid_value"
    case duplicateIdentifier = "duplicate_identifier"
    case duplicateKey = "duplicate_key"
    case unsafePath = "unsafe_path"
    case undeclaredType = "undeclared_type"
    case undeclaredField = "undeclared_field"
    case invalidReference = "invalid_reference"
    case scopeViolation = "scope_violation"
}

public struct RoamPiConfigurationDiagnostic: Error, Codable, Equatable, Sendable {
    public static let maximumLocationLength = 160

    public let code: RoamPiConfigurationDiagnosticCode
    public let location: String

    public init(code: RoamPiConfigurationDiagnosticCode, location: String) {
        self.code = code
        self.location = String(location.prefix(Self.maximumLocationLength))
    }
}

public enum RoamPiConfigurationSource: Equatable, Sendable {
    case machine
    case project(root: String, machineID: String)

    public var filePath: String {
        switch self {
        case .machine:
            RoamPiConfigurationPaths.machine
        case let .project(root, _):
            root.hasSuffix("/")
                ? root + RoamPiConfigurationPaths.projectFileName
                : root + "/" + RoamPiConfigurationPaths.projectFileName
        }
    }

    public var projectRoot: String? {
        guard case let .project(root, _) = self else { return nil }
        return root
    }

    public var projectMachineID: String? {
        guard case let .project(_, machineID) = self else { return nil }
        return machineID
    }
}

public struct ValidatedRoamPiConfiguration: Equatable, Sendable {
    public let document: RoamPiConfigurationDocument
    public let source: RoamPiConfigurationSource
    public let canonicalData: Data

    public init(
        document: RoamPiConfigurationDocument,
        source: RoamPiConfigurationSource,
        canonicalData: Data
    ) {
        self.document = document
        self.source = source
        self.canonicalData = canonicalData
    }
}

public struct RoamPiConfigurationParseResult: Equatable, Sendable {
    public let configuration: ValidatedRoamPiConfiguration?
    public let diagnostics: [RoamPiConfigurationDiagnostic]

    public init(
        configuration: ValidatedRoamPiConfiguration?,
        diagnostics: [RoamPiConfigurationDiagnostic]
    ) {
        self.configuration = configuration
        self.diagnostics = diagnostics
    }
}

private final class RoamPiConfigurationIdentifierRegistry {
    private var locations: [String: String] = [:]

    func register(
        _ identifier: String,
        at path: String,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        let isValid = !identifier.isEmpty && identifier.utf8.count <= 64 && identifier.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
        guard isValid else {
            if diagnostics.count < 32 {
                diagnostics.append(.init(code: .invalidValue, location: path))
            }
            return
        }
        if locations[identifier] != nil {
            if diagnostics.count < 32 {
                diagnostics.append(.init(code: .duplicateIdentifier, location: path))
            }
        } else {
            locations[identifier] = path
        }
    }
}

private struct RoamPiJSONDuplicateKeyScanner {
    private enum ScanError: Error {
        case malformed
    }

    private let bytes: [UInt8]
    private var index = 0
    private(set) var containsUnsupportedNumber = false
    private(set) var containsRoundedInvertedWidth = false
    private var lastNumberToken: String?

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func containsDuplicateKey() throws -> Bool {
        skipWhitespace()
        let duplicate = try parseValue(path: [])
        if duplicate {
            return true
        }
        skipWhitespace()
        guard index == bytes.count else { throw ScanError.malformed }
        return false
    }

    private mutating func parseValue(path: [String]) throws -> Bool {
        skipWhitespace()
        guard let byte = current else { throw ScanError.malformed }
        switch byte {
        case 123:
            return try parseObject(path: path)
        case 91:
            return try parseArray(path: path)
        case 34:
            _ = try parseString()
            return false
        default:
            parsePrimitive(widthBounded: isWidthPath(path))
            return false
        }
    }

    private mutating func parseObject(path: [String]) throws -> Bool {
        index += 1
        skipWhitespace()
        if consume(125) {
            return false
        }
        var keys = Set<String>()
        var widthTokens: [String: String] = [:]
        while true {
            skipWhitespace()
            let key = try parseString()
            if !keys.insert(key).inserted {
                return true
            }
            skipWhitespace()
            guard consume(58) else { throw ScanError.malformed }
            skipWhitespace()
            let isDirectNumber = current == 45 || current.map { (48 ... 57).contains($0) } == true
            lastNumberToken = nil
            if try parseValue(path: path + [key]) {
                return true
            }
            if isDirectNumber, isLayoutPath(path), let token = lastNumberToken {
                widthTokens[key] = token
            }
            skipWhitespace()
            if consume(125) {
                checkWidthOrder(widthTokens)
                return false
            }
            guard consume(44) else { throw ScanError.malformed }
        }
    }

    private mutating func parseArray(path: [String]) throws -> Bool {
        index += 1
        skipWhitespace()
        if consume(93) {
            return false
        }
        while true {
            if try parseValue(path: path + ["[]"]) {
                return true
            }
            skipWhitespace()
            if consume(93) {
                return false
            }
            guard consume(44) else { throw ScanError.malformed }
        }
    }

    private mutating func parseString() throws -> String {
        guard consume(34) else { throw ScanError.malformed }
        let contentStart = index
        var escaped = false
        while let byte = current {
            if escaped {
                escaped = false
                index += 1
            } else if byte == 92 {
                escaped = true
                index += 1
            } else if byte == 34 {
                let contentEnd = index
                index += 1
                var quoted = Data([34])
                quoted.append(contentsOf: bytes[contentStart ..< contentEnd])
                quoted.append(34)
                return try JSONDecoder().decode(String.self, from: quoted)
            } else {
                index += 1
            }
        }
        throw ScanError.malformed
    }

    private func isLayoutPath(_ path: [String]) -> Bool {
        path.first == "pages" && Array(path.suffix(3)) == ["blocks", "[]", "layout"]
    }

    private func isWidthPath(_ path: [String]) -> Bool {
        guard let key = path.last else { return false }
        return isLayoutPath(Array(path.dropLast())) &&
            ["minimumWidth", "preferredWidth", "maximumWidth"].contains(key)
    }

    private mutating func checkWidthOrder(_ tokens: [String: String]) {
        guard let minimum = tokens["minimumWidth"],
              let preferred = tokens["preferredWidth"],
              Double(minimum) == Double(preferred),
              comparePositiveNumbers(preferred, minimum) == .orderedAscending
        else { return }
        containsRoundedInvertedWidth = true
    }

    private func comparePositiveNumbers(_ left: String, _ right: String) -> ComparisonResult {
        guard let leftParts = normalizedPositiveNumber(left),
              let rightParts = normalizedPositiveNumber(right)
        else { return .orderedSame }
        if leftParts.power != rightParts.power {
            return leftParts.power < rightParts.power ? .orderedAscending : .orderedDescending
        }
        let count = max(leftParts.digits.count, rightParts.digits.count)
        let leftDigits = leftParts.digits + Array(repeating: Character("0"), count: count - leftParts.digits.count)
        let rightDigits = rightParts.digits + Array(repeating: Character("0"), count: count - rightParts.digits.count)
        if leftDigits == rightDigits {
            return .orderedSame
        }
        return leftDigits.lexicographicallyPrecedes(rightDigits) ? .orderedAscending : .orderedDescending
    }

    private func normalizedPositiveNumber(_ token: String) -> (power: Int, digits: [Character])? {
        guard !token.hasPrefix("-") else { return nil }
        let parts = token.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count <= 2 else { return nil }
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else { return nil }
            exponent = parsed
        } else {
            exponent = 0
        }
        let coefficient = parts[0]
        let integerDigits = coefficient.firstIndex(of: ".").map {
            coefficient.distance(from: coefficient.startIndex, to: $0)
        } ?? coefficient.count
        let digits = coefficient.filter(\.isNumber)
        guard let firstNonzero = digits.firstIndex(where: { $0 != "0" }) else {
            return (0, ["0"])
        }
        let leadingZeros = digits.distance(from: digits.startIndex, to: firstNonzero)
        let (power, overflow) = exponent.addingReportingOverflow(integerDigits - 1 - leadingZeros)
        guard !overflow else { return nil }
        return (power, Array(digits[firstNonzero...]))
    }

    private mutating func parsePrimitive(widthBounded: Bool) {
        let start = index
        while let byte = current, ![9, 10, 13, 32, 44, 93, 125].contains(byte) {
            index += 1
        }
        guard start < index, bytes[start] == 45 || (48 ... 57).contains(bytes[start]) else { return }
        let token = String(decoding: bytes[start ..< index], as: UTF8.self)
        lastNumberToken = token
        let significand = token.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
        let hasNonzeroDigit = significand.contains(where: { ("1" ... "9").contains($0) })
        guard let value = Double(token),
              value.isFinite,
              value != 0 || !hasNonzeroDigit,
              isMathematicallyIntegral(token) || value.rounded(.towardZero) != value,
              hasSupportedMinimumMagnitude(token),
              !widthBounded || isAtMostMaximumWidth(token)
        else {
            containsUnsupportedNumber = true
            return
        }
    }

    private func isMathematicallyIntegral(_ token: String) -> Bool {
        let unsigned = token.hasPrefix("-") ? String(token.dropFirst()) : token
        let parts = unsigned.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count <= 2 else { return false }
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else { return false }
            exponent = parsed
        } else {
            exponent = 0
        }
        let coefficient = parts[0]
        let fractionalDigits = coefficient.firstIndex(of: ".").map {
            coefficient.distance(from: coefficient.index(after: $0), to: coefficient.endIndex)
        } ?? 0
        let (scale, overflow) = exponent.subtractingReportingOverflow(fractionalDigits)
        guard !overflow else { return false }
        if scale >= 0 {
            return true
        }
        guard scale != Int.min else { return false }
        let digits = coefficient.filter(\.isNumber)
        let requiredZeros = -scale
        return requiredZeros <= digits.count && digits.suffix(requiredZeros).allSatisfy { $0 == "0" }
    }

    private func isAtMostMaximumWidth(_ token: String) -> Bool {
        if token.hasPrefix("-") {
            return true
        }
        let parts = token.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count <= 2 else { return false }
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else { return false }
            exponent = parsed
        } else {
            exponent = 0
        }
        let coefficient = parts[0]
        let integerDigits = coefficient.firstIndex(of: ".").map {
            coefficient.distance(from: coefficient.startIndex, to: $0)
        } ?? coefficient.count
        let digits = coefficient.filter(\.isNumber)
        guard let firstNonzero = digits.firstIndex(where: { $0 != "0" }) else { return true }
        let leadingZeros = digits.distance(from: digits.startIndex, to: firstNonzero)
        let (basePower, overflow) = exponent.addingReportingOverflow(integerDigits - 1 - leadingZeros)
        guard !overflow else { return false }
        if basePower != 3 {
            return basePower < 3
        }

        let significantDigits = digits[firstNonzero...]
        let comparisonDigits = Array(significantDigits.prefix(4)) +
            Array(repeating: Character("0"), count: max(0, 4 - significantDigits.count))
        let maximumDigits = Array("4096")
        if comparisonDigits != maximumDigits {
            return comparisonDigits.lexicographicallyPrecedes(maximumDigits)
        }
        return significantDigits.dropFirst(4).allSatisfy { $0 == "0" }
    }

    private func hasSupportedMinimumMagnitude(_ token: String) -> Bool {
        let unsigned = token.hasPrefix("-") ? String(token.dropFirst()) : token
        let parts = unsigned.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count <= 2 else { return false }
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else { return false }
            exponent = parsed
        } else {
            exponent = 0
        }
        let coefficient = parts[0]
        let integerDigits = coefficient.firstIndex(of: ".").map {
            coefficient.distance(from: coefficient.startIndex, to: $0)
        } ?? coefficient.count
        let digits = coefficient.filter(\.isNumber)
        guard let firstNonzero = digits.firstIndex(where: { $0 != "0" }) else { return true }
        let leadingZeros = digits.distance(from: digits.startIndex, to: firstNonzero)
        let (basePower, overflow) = exponent.addingReportingOverflow(integerDigits - 1 - leadingZeros)
        guard !overflow else { return false }
        if basePower != -324 {
            return basePower > -324
        }
        return digits[firstNonzero] >= "5"
    }

    private mutating func skipWhitespace() {
        while let byte = current, [9, 10, 13, 32].contains(byte) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}

public enum RoamPiConfigurationParser {
    public static let maximumDocumentBytes = 1_048_576
    private static let maximumDiagnostics = 32
    private static let prohibitedKeys: Set<String> = [
        "accesskeyid", "accesstoken", "apikey", "authorization", "clientsecret", "credential", "credentials",
        "mnemonic", "passcode", "passphrase", "passwd", "password", "privatekey", "providerkey", "pwd", "secret",
        "secretaccesskey",
        "secretkey", "seedphrase", "token",
    ]
    private static let prohibitedKeyQualifiers: Set<String> = [
        "base64", "content", "contents", "data", "encoded", "file", "hash", "header", "json", "material", "path", "pem",
        "string", "value",
    ]

    public static func parse(
        _ data: Data,
        source: RoamPiConfigurationSource
    ) -> RoamPiConfigurationParseResult {
        guard data.count <= maximumDocumentBytes else {
            return .init(
                configuration: nil,
                diagnostics: [.init(code: .documentTooLarge, location: "$")]
            )
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .init(
                configuration: nil,
                diagnostics: [.init(code: .malformedJSON, location: "$")]
            )
        }
        guard let object = raw as? [String: Any] else {
            return .init(
                configuration: nil,
                diagnostics: [.init(code: .invalidValue, location: "$")]
            )
        }

        var diagnostics: [RoamPiConfigurationDiagnostic] = []
        validateNesting(object, path: "$", depth: 0, diagnostics: &diagnostics)
        guard diagnostics.isEmpty else {
            return .init(configuration: nil, diagnostics: diagnostics)
        }
        do {
            var scanner = RoamPiJSONDuplicateKeyScanner(data: data)
            if try scanner.containsDuplicateKey() {
                return .init(
                    configuration: nil,
                    diagnostics: [.init(code: .duplicateKey, location: "$[?]")]
                )
            }
            if scanner.containsUnsupportedNumber || scanner.containsRoundedInvertedWidth {
                return .init(
                    configuration: nil,
                    diagnostics: [.init(code: .invalidValue, location: "$[?]")]
                )
            }
        } catch {
            return .init(
                configuration: nil,
                diagnostics: [.init(code: .malformedJSON, location: "$")]
            )
        }
        scanForSecretFields(object, path: "$", diagnostics: &diagnostics)
        if let version = object["version"] as? NSNumber, version.intValue != 1 {
            append(.unsupportedVersion, at: "$.version", to: &diagnostics)
        }
        if let schemaURI = object["$schema"], !(schemaURI is String) {
            append(.invalidValue, at: "$.$schema", to: &diagnostics)
        }
        validateDeclaredTypes(object, diagnostics: &diagnostics)
        guard diagnostics.isEmpty else {
            return .init(configuration: nil, diagnostics: diagnostics)
        }

        let canonicalInput: Data
        do {
            canonicalInput = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            return .init(
                configuration: nil,
                diagnostics: [.init(code: .malformedJSON, location: "$")]
            )
        }

        let document: RoamPiConfigurationDocument
        do {
            document = try JSONDecoder().decode(RoamPiConfigurationDocument.self, from: canonicalInput)
        } catch let error as DecodingError {
            return .init(configuration: nil, diagnostics: [diagnostic(for: error)])
        } catch {
            return .init(
                configuration: nil,
                diagnostics: [.init(code: .invalidValue, location: "$")]
            )
        }

        do {
            let encoded = try JSONEncoder().encode(document)
            let encodedObject = try JSONSerialization.jsonObject(with: encoded)
            scanForUndeclaredFields(
                object,
                encoded: encodedObject,
                path: "$",
                allowsSchemaKey: true,
                diagnostics: &diagnostics
            )
        } catch {
            append(.invalidValue, at: "$", to: &diagnostics)
        }
        validate(document, source: source, diagnostics: &diagnostics)
        guard diagnostics.isEmpty else {
            return .init(configuration: nil, diagnostics: diagnostics)
        }

        return .init(
            configuration: .init(document: document, source: source, canonicalData: canonicalInput),
            diagnostics: []
        )
    }

    private static func validate(
        _ document: RoamPiConfigurationDocument,
        source: RoamPiConfigurationSource,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        guard document.version == 1 else {
            append(.unsupportedVersion, at: "$.version", to: &diagnostics)
            return
        }

        switch (document.kind, source) {
        case (.machine, .machine):
            guard document.machine != nil, document.project == nil else {
                append(.scopeViolation, at: "$", to: &diagnostics)
                return
            }
        case (.project, .project):
            guard document.project != nil, document.machine == nil else {
                append(.scopeViolation, at: "$", to: &diagnostics)
                return
            }
        default:
            append(.scopeViolation, at: "$.kind", to: &diagnostics)
            return
        }

        let identifierRegistry = RoamPiConfigurationIdentifierRegistry()

        if let machine = document.machine {
            validateMachine(
                machine.homeHost,
                at: "$.machine.homeHost",
                registry: identifierRegistry,
                diagnostics: &diagnostics
            )
            for (index, item) in machine.machines.enumerated() {
                validateMachine(
                    item,
                    at: "$.machine.machines[\(index)]",
                    registry: identifierRegistry,
                    diagnostics: &diagnostics
                )
            }
            let machineIDs = Set([machine.homeHost.id] + machine.machines.map(\.id))
            for (index, project) in machine.projects.enumerated() {
                let path = "$.machine.projects[\(index)]"
                identifierRegistry.register(project.id, at: path + ".id", diagnostics: &diagnostics)
                if !machineIDs.contains(project.machineID) {
                    append(.invalidReference, at: path + ".machineID", to: &diagnostics)
                }
                if project.discovery != .explicit {
                    append(.invalidValue, at: path + ".discovery", to: &diagnostics)
                }
                if !isSafeAbsolutePath(project.path) {
                    append(.unsafePath, at: path + ".path", to: &diagnostics)
                }
                if !isValidDisplayName(project.name) {
                    append(.invalidValue, at: path + ".name", to: &diagnostics)
                }
                if let group = project.group, !isValidDisplayName(group) {
                    append(.invalidValue, at: path + ".group", to: &diagnostics)
                }
            }
            for (index, dataSource) in document.dataSources.enumerated() {
                if let target = dataSource.targetMachineID, !machineIDs.contains(target) {
                    append(.invalidReference, at: "$.dataSources[\(index)].targetMachineID", to: &diagnostics)
                }
            }
            for (index, action) in document.actions.enumerated()
                where !machineIDs.contains(action.target.machineID)
            {
                append(.invalidReference, at: "$.actions[\(index)].target.machineID", to: &diagnostics)
            }
            var overrideIDs = Set<String>()
            for (index, override) in machine.projectOverrides.enumerated() {
                let path = "$.machine.projectOverrides[\(index)]"
                if !isValidIdentifier(override.projectID) {
                    append(.invalidValue, at: path + ".projectID", to: &diagnostics)
                } else if !overrideIDs.insert(override.projectID).inserted {
                    append(.duplicateIdentifier, at: path + ".projectID", to: &diagnostics)
                }
                if let name = override.name, !isValidDisplayName(name) {
                    append(.invalidValue, at: path + ".name", to: &diagnostics)
                }
                if let group = override.group, !isValidDisplayName(group) {
                    append(.invalidValue, at: path + ".group", to: &diagnostics)
                }
                var disabledIDs = Set<String>()
                for (disabledIndex, identifier) in override.disabledContributions.enumerated() {
                    if !isValidIdentifier(identifier) {
                        append(
                            .invalidValue,
                            at: path + ".disabledContributions[\(disabledIndex)]",
                            to: &diagnostics
                        )
                    } else if !disabledIDs.insert(identifier).inserted {
                        append(
                            .duplicateIdentifier,
                            at: path + ".disabledContributions[\(disabledIndex)]",
                            to: &diagnostics
                        )
                    }
                }
            }
        }

        if let project = document.project {
            identifierRegistry.register(project.id, at: "$.project.id", diagnostics: &diagnostics)
            if let name = project.name, !isValidDisplayName(name) {
                append(.invalidValue, at: "$.project.name", to: &diagnostics)
            }
            if let group = project.group, !isValidDisplayName(group) {
                append(.invalidValue, at: "$.project.group", to: &diagnostics)
            }
            if let root = source.projectRoot, !isSafeAbsolutePath(root) {
                append(.unsafePath, at: "$source.projectRoot", to: &diagnostics)
            }
            if let machineID = source.projectMachineID, !isValidIdentifier(machineID) {
                append(.invalidValue, at: "$source.projectMachineID", to: &diagnostics)
            }
        }

        for (index, page) in document.pages.enumerated() {
            validatePage(
                page,
                at: "$.pages[\(index)]",
                registry: identifierRegistry,
                diagnostics: &diagnostics
            )
        }
        for (index, dataSource) in document.dataSources.enumerated() {
            validateDataSource(
                dataSource,
                at: "$.dataSources[\(index)]",
                registry: identifierRegistry,
                diagnostics: &diagnostics
            )
        }
        for (index, action) in document.actions.enumerated() {
            validateAction(
                action,
                at: "$.actions[\(index)]",
                registry: identifierRegistry,
                diagnostics: &diagnostics
            )
        }
        for (index, job) in document.jobs.enumerated() {
            let path = "$.jobs[\(index)]"
            identifierRegistry.register(job.id, at: path + ".id", diagnostics: &diagnostics)
            if !isValidDisplayName(job.title) {
                append(.invalidValue, at: path + ".title", to: &diagnostics)
            }
            if !document.actions.contains(where: { $0.id == job.actionID }) {
                append(.invalidReference, at: path + ".actionID", to: &diagnostics)
            }
        }

        let dataSourceIDs = Set(document.dataSources.map(\.id))
        let actionIDs = Set(document.actions.map(\.id))
        let jobIDs = Set(document.jobs.map(\.id))
        for (index, page) in document.pages.enumerated() {
            validateReferences(
                page,
                at: "$.pages[\(index)]",
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs,
                diagnostics: &diagnostics
            )
        }
    }

    private static func validateMachine(
        _ machine: RoamPiMachine,
        at path: String,
        registry: RoamPiConfigurationIdentifierRegistry,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        registry.register(machine.id, at: path + ".id", diagnostics: &diagnostics)
        if !isValidDisplayName(machine.name) {
            append(.invalidValue, at: path + ".name", to: &diagnostics)
        }
        if let group = machine.group, !isValidDisplayName(group) {
            append(.invalidValue, at: path + ".group", to: &diagnostics)
        }
        if machine.host.isEmpty || machine.host.unicodeScalars.count > 253 || containsControlCharacter(machine.host) {
            append(.invalidValue, at: path + ".host", to: &diagnostics)
        }
        if !(1 ... 65535).contains(machine.port) {
            append(.invalidValue, at: path + ".port", to: &diagnostics)
        }
        if machine.username.isEmpty || machine.username.unicodeScalars
            .count > 64 || containsControlCharacter(machine.username)
        {
            append(.invalidValue, at: path + ".username", to: &diagnostics)
        }
    }

    private static func validatePage(
        _ page: RoamPiPage,
        at path: String,
        registry: RoamPiConfigurationIdentifierRegistry,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        registry.register(page.id, at: path + ".id", diagnostics: &diagnostics)
        if !isValidDisplayName(page.title) {
            append(.invalidValue, at: path + ".title", to: &diagnostics)
        }
        if let systemImage = page.systemImage, !isValidDisplayName(systemImage) {
            append(.invalidValue, at: path + ".systemImage", to: &diagnostics)
        }
        for (index, block) in page.blocks.enumerated() {
            validateBlock(
                block,
                at: path + ".blocks[\(index)]",
                registry: registry,
                diagnostics: &diagnostics
            )
        }
        for (index, child) in page.children.enumerated() {
            validatePage(
                child,
                at: path + ".children[\(index)]",
                registry: registry,
                diagnostics: &diagnostics
            )
        }
    }

    private static func validateBlock(
        _ block: RoamPiBlock,
        at path: String,
        registry: RoamPiConfigurationIdentifierRegistry,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        registry.register(block.id, at: path + ".id", diagnostics: &diagnostics)
        if let title = block.title, !isValidDisplayName(title) {
            append(.invalidValue, at: path + ".title", to: &diagnostics)
        }
        validateLayout(block.layout, at: path + ".layout", diagnostics: &diagnostics)
        switch block.type {
        case .section, .grid:
            if block.blocks.isEmpty {
                append(.missingValue, at: path + ".blocks", to: &diagnostics)
            }
        case .list, .status:
            if block.dataSourceID == nil {
                append(.missingValue, at: path + ".dataSourceID", to: &diagnostics)
            }
        case .markdown:
            if block.content?.isEmpty != false {
                append(.missingValue, at: path + ".content", to: &diagnostics)
            } else if let content = block.content, content.unicodeScalars.count > 65536 {
                append(.invalidValue, at: path + ".content", to: &diagnostics)
            }
        case .input:
            if block.inputKind == nil {
                append(.missingValue, at: path + ".inputKind", to: &diagnostics)
            }
        case .action:
            if block.actionID == nil {
                append(.missingValue, at: path + ".actionID", to: &diagnostics)
            }
        case .jobs:
            if block.jobID == nil, block.dataSourceID == nil {
                append(.missingValue, at: path + ".jobID", to: &diagnostics)
            }
        case .sessions:
            break
        }
        if let placeholder = block.placeholder, placeholder.unicodeScalars.count > 256 {
            append(.invalidValue, at: path + ".placeholder", to: &diagnostics)
        }
        for (index, child) in block.blocks.enumerated() {
            validateBlock(
                child,
                at: path + ".blocks[\(index)]",
                registry: registry,
                diagnostics: &diagnostics
            )
        }
    }

    private static func validateLayout(
        _ layout: RoamPiAdaptiveLayout,
        at path: String,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        if let minimum = layout.minimumWidth, !minimum.isFinite || minimum <= 0 || minimum > 4096 {
            append(.invalidValue, at: path + ".minimumWidth", to: &diagnostics)
        }
        if let preferred = layout.preferredWidth,
           !preferred.isFinite || preferred <= 0 || preferred > 4096
        {
            append(.invalidValue, at: path + ".preferredWidth", to: &diagnostics)
        }
        if let minimum = layout.minimumWidth,
           let preferred = layout.preferredWidth,
           preferred < minimum
        {
            append(.invalidValue, at: path + ".preferredWidth", to: &diagnostics)
        }
        if !(1 ... 12).contains(layout.compactSpan) {
            append(.invalidValue, at: path + ".compactSpan", to: &diagnostics)
        }
        if !(1 ... 12).contains(layout.regularSpan) {
            append(.invalidValue, at: path + ".regularSpan", to: &diagnostics)
        }
    }

    private static func validateDataSource(
        _ dataSource: RoamPiDataSource,
        at path: String,
        registry: RoamPiConfigurationIdentifierRegistry,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        registry.register(dataSource.id, at: path + ".id", diagnostics: &diagnostics)
        if let command = dataSource.command {
            if command.isEmpty {
                append(.missingValue, at: path + ".command", to: &diagnostics)
            } else if command.unicodeScalars.count > 65536 {
                append(.invalidValue, at: path + ".command", to: &diagnostics)
            }
        }
        if let target = dataSource.targetMachineID, !isValidIdentifier(target) {
            append(.invalidValue, at: path + ".targetMachineID", to: &diagnostics)
        }
        if let directory = dataSource.workingDirectory, !isSafeAbsolutePath(directory) {
            append(.unsafePath, at: path + ".workingDirectory", to: &diagnostics)
        }
        if let schema = dataSource.resultSchema {
            validateValueSchema(schema, at: path + ".resultSchema", depth: 0, diagnostics: &diagnostics)
        }

        switch dataSource.type {
        case .static:
            if dataSource.value == nil {
                append(.missingValue, at: path + ".value", to: &diagnostics)
            }
        case .builtin:
            if dataSource.builtin == nil {
                append(.missingValue, at: path + ".builtin", to: &diagnostics)
            }
        case .command:
            if dataSource.command == nil {
                append(.missingValue, at: path + ".command", to: &diagnostics)
            }
            if dataSource.targetMachineID == nil {
                append(.missingValue, at: path + ".targetMachineID", to: &diagnostics)
            }
            if dataSource.workingDirectory == nil {
                append(.missingValue, at: path + ".workingDirectory", to: &diagnostics)
            }
            if dataSource.resultSchema == nil {
                append(.missingValue, at: path + ".resultSchema", to: &diagnostics)
            }
        }
    }

    private static func validateValueSchema(
        _ schema: RoamPiValueSchema,
        at path: String,
        depth: Int,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        guard depth <= 16 else {
            append(.invalidValue, at: path, to: &diagnostics)
            return
        }
        let properties = schema.properties ?? [:]
        var requiredNames = Set<String>()
        for (index, required) in (schema.required ?? []).enumerated() {
            if !requiredNames.insert(required).inserted {
                append(.duplicateIdentifier, at: path + ".required[\(index)]", to: &diagnostics)
            } else if properties[required] == nil {
                append(.invalidReference, at: path + ".required[\(index)]", to: &diagnostics)
            }
        }
        for key in properties.keys.sorted() {
            if let child = properties[key] {
                validateValueSchema(
                    child,
                    at: path + ".properties[?]",
                    depth: depth + 1,
                    diagnostics: &diagnostics
                )
            }
        }
        if let items = schema.items {
            validateValueSchema(items, at: path + ".items", depth: depth + 1, diagnostics: &diagnostics)
        } else if schema.type == .array {
            append(.missingValue, at: path + ".items", to: &diagnostics)
        }
    }

    private static func validateAction(
        _ action: RoamPiAction,
        at path: String,
        registry: RoamPiConfigurationIdentifierRegistry,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        registry.register(action.id, at: path + ".id", diagnostics: &diagnostics)
        if !isValidDisplayName(action.title) {
            append(.invalidValue, at: path + ".title", to: &diagnostics)
        }
        switch action.type {
        case .prompt:
            if action.prompt?.isEmpty != false || action.command != nil {
                append(.invalidValue, at: path + ".prompt", to: &diagnostics)
            } else if let prompt = action.prompt, prompt.unicodeScalars.count > 65536 {
                append(.invalidValue, at: path + ".prompt", to: &diagnostics)
            }
        case .command:
            if action.command?.isEmpty != false || action.prompt != nil {
                append(.invalidValue, at: path + ".command", to: &diagnostics)
            } else if let command = action.command, command.unicodeScalars.count > 65536 {
                append(.invalidValue, at: path + ".command", to: &diagnostics)
            }
        }
        if !isValidIdentifier(action.target.machineID) {
            append(.invalidValue, at: path + ".target.machineID", to: &diagnostics)
        }
        if !isSafeAbsolutePath(action.target.workingDirectory) {
            append(.unsafePath, at: path + ".target.workingDirectory", to: &diagnostics)
        }
    }

    private static func validateReferences(
        _ page: RoamPiPage,
        at path: String,
        dataSourceIDs: Set<String>,
        actionIDs: Set<String>,
        jobIDs: Set<String>,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        for (index, block) in page.blocks.enumerated() {
            validateReferences(
                block,
                at: path + ".blocks[\(index)]",
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs,
                diagnostics: &diagnostics
            )
        }
        for (index, child) in page.children.enumerated() {
            validateReferences(
                child,
                at: path + ".children[\(index)]",
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs,
                diagnostics: &diagnostics
            )
        }
    }

    private static func validateReferences(
        _ block: RoamPiBlock,
        at path: String,
        dataSourceIDs: Set<String>,
        actionIDs: Set<String>,
        jobIDs: Set<String>,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        if let identifier = block.dataSourceID, !dataSourceIDs.contains(identifier) {
            append(.invalidReference, at: path + ".dataSourceID", to: &diagnostics)
        }
        if let identifier = block.actionID, !actionIDs.contains(identifier) {
            append(.invalidReference, at: path + ".actionID", to: &diagnostics)
        }
        if let identifier = block.jobID, !jobIDs.contains(identifier) {
            append(.invalidReference, at: path + ".jobID", to: &diagnostics)
        }
        for (index, child) in block.blocks.enumerated() {
            validateReferences(
                child,
                at: path + ".blocks[\(index)]",
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs,
                diagnostics: &diagnostics
            )
        }
    }

    private static func validateNesting(
        _ value: Any,
        path: String,
        depth: Int,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        guard depth <= 64 else {
            append(.nestingTooDeep, at: path, to: &diagnostics)
            return
        }
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                if let child = object[key] {
                    validateNesting(
                        child,
                        path: jsonPath(path, key: key),
                        depth: depth + 1,
                        diagnostics: &diagnostics
                    )
                }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                validateNesting(
                    child,
                    path: path + "[\(index)]",
                    depth: depth + 1,
                    diagnostics: &diagnostics
                )
            }
        }
    }

    private static func scanForUndeclaredFields(
        _ value: Any,
        encoded: Any,
        path: String,
        allowsSchemaKey: Bool,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        guard diagnostics.count < maximumDiagnostics else { return }
        if let object = value as? [String: Any], let encodedObject = encoded as? [String: Any] {
            for key in object.keys.sorted() {
                if allowsSchemaKey, key == "$schema" {
                    continue
                }
                let keyPath = jsonPath(path, key: key)
                guard let encodedValue = encodedObject[key] else {
                    append(.undeclaredField, at: keyPath, to: &diagnostics)
                    continue
                }
                if let child = object[key] {
                    scanForUndeclaredFields(
                        child,
                        encoded: encodedValue,
                        path: keyPath,
                        allowsSchemaKey: false,
                        diagnostics: &diagnostics
                    )
                }
            }
        } else if let array = value as? [Any], let encodedArray = encoded as? [Any] {
            for index in array.indices where encodedArray.indices.contains(index) {
                scanForUndeclaredFields(
                    array[index],
                    encoded: encodedArray[index],
                    path: path + "[\(index)]",
                    allowsSchemaKey: false,
                    diagnostics: &diagnostics
                )
            }
        }
    }

    private static func scanForSecretFields(
        _ value: Any,
        path: String,
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        guard diagnostics.count < maximumDiagnostics else { return }
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                let keyPath = jsonPath(path, key: key)
                if isProhibitedKey(key) {
                    append(.secretField, at: keyPath, to: &diagnostics)
                } else if let child = object[key] {
                    scanForSecretFields(child, path: keyPath, diagnostics: &diagnostics)
                }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                scanForSecretFields(child, path: path + "[\(index)]", diagnostics: &diagnostics)
            }
        }
    }

    private static func validateDeclaredTypes(
        _ object: [String: Any],
        diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        let allowedBlocks = Set(RoamPiBlockType.allRawValues)
        func checkBlocks(_ blocks: Any?, at path: String) {
            guard let blocks = blocks as? [[String: Any]] else { return }
            for (index, block) in blocks.enumerated() {
                let blockPath = path + "[\(index)]"
                if let type = block["type"] as? String, !allowedBlocks.contains(type) {
                    append(.undeclaredType, at: blockPath + ".type", to: &diagnostics)
                }
                checkBlocks(block["blocks"], at: blockPath + ".blocks")
            }
        }
        func checkPages(_ pages: Any?, at path: String) {
            guard let pages = pages as? [[String: Any]] else { return }
            for (index, page) in pages.enumerated() {
                let pagePath = path + "[\(index)]"
                checkBlocks(page["blocks"], at: pagePath + ".blocks")
                checkPages(page["children"], at: pagePath + ".children")
            }
        }
        checkPages(object["pages"], at: "$.pages")
    }

    private static func diagnostic(for error: DecodingError) -> RoamPiConfigurationDiagnostic {
        switch error {
        case let .keyNotFound(key, context):
            .init(code: .missingValue, location: codingPath(context.codingPath + [key]))
        case let .typeMismatch(_, context):
            .init(code: .invalidValue, location: codingPath(context.codingPath))
        case let .valueNotFound(_, context):
            .init(code: .missingValue, location: codingPath(context.codingPath))
        case let .dataCorrupted(context):
            .init(code: .invalidValue, location: codingPath(context.codingPath))
        @unknown default:
            .init(code: .invalidValue, location: "$")
        }
    }

    private static func codingPath(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("$") { partial, key in
            if let index = key.intValue {
                partial + "[\(index)]"
            } else {
                jsonPath(partial, key: key.stringValue)
            }
        }
    }

    private static func jsonPath(_ base: String, key: String) -> String {
        guard diagnosticKeyAllowlist.contains(key) else { return base + "[?]" }
        return base + "." + key
    }

    private static let diagnosticKeyAllowlist: Set<String> = [
        "actionID", "actions", "blocks", "builtin", "cancellation", "children", "command", "compactSpan",
        "concurrency", "content", "dataSourceID", "dataSources", "delivery", "disabledContributions", "discovery",
        "enabled", "execution", "fallbackBehavior", "group", "homeHost", "host", "id", "inputKind", "items",
        "jobID", "jobs", "kind", "layout", "machine", "machineID", "machines", "minimumWidth", "name", "pages",
        "path", "placeholder", "port", "preferredWidth", "presentation", "project", "projectID", "projectOverrides",
        "projects", "prompt", "properties", "regularSpan", "required", "resultSchema", "schedule", "systemImage",
        "target", "targetMachineID", "title", "type", "username", "value", "version", "visible", "workingDirectory",
    ]

    private static func isProhibitedKey(_ value: String) -> Bool {
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        if prohibitedKeys.contains(normalized) || prohibitedKeys.contains(where: { key in
            normalized.hasSuffix(key) || normalized.hasSuffix(key + "s") || normalized.hasSuffix(key + "es")
        }) {
            return true
        }
        return prohibitedKeys.contains { key in
            guard normalized.hasPrefix(key) else { return false }
            return isProhibitedQualifierSequence(String(normalized.dropFirst(key.count)))
        }
    }

    private static func isProhibitedQualifierSequence(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var remainder = value[...]
        while !remainder.isEmpty {
            if remainder == "s" || remainder == "es" || remainder.allSatisfy(\.isNumber) {
                return true
            }
            if remainder.hasPrefix("v"), remainder.dropFirst().allSatisfy(\.isNumber), remainder.count > 1 {
                return true
            }
            guard let qualifier = prohibitedKeyQualifiers.first(where: { remainder.hasPrefix($0) }) else {
                return false
            }
            remainder = remainder.dropFirst(qualifier.count)
        }
        return true
    }

    private static func isValidDisplayName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 128 && !containsControlCharacter(value)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value.unicodeScalars.count <= 256, !containsControlCharacter(value) else {
            return false
        }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func append(
        _ code: RoamPiConfigurationDiagnosticCode,
        at location: String,
        to diagnostics: inout [RoamPiConfigurationDiagnostic]
    ) {
        guard diagnostics.count < maximumDiagnostics else { return }
        diagnostics.append(.init(code: code, location: location))
    }
}

private extension RawRepresentable where RawValue == String, Self: CaseIterable {
    static var allRawValues: [String] {
        allCases.map(\.rawValue)
    }
}
