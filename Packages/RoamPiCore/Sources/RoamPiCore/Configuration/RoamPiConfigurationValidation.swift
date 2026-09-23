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
    case project(root: String)

    public var filePath: String {
        switch self {
        case .machine:
            RoamPiConfigurationPaths.machine
        case let .project(root):
            root.hasSuffix("/")
                ? root + RoamPiConfigurationPaths.projectFileName
                : root + "/" + RoamPiConfigurationPaths.projectFileName
        }
    }

    public var projectRoot: String? {
        guard case let .project(root) = self else { return nil }
        return root
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

public enum RoamPiConfigurationParser {
    public static let maximumDocumentBytes = 1_048_576
    private static let maximumDiagnostics = 32
    private static let prohibitedKeys: Set<String> = [
        "accesstoken", "apikey", "authorization", "credential", "credentials",
        "password", "privatekey", "providerkey", "secret", "token",
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
        scanForSecretFields(object, path: "$", diagnostics: &diagnostics)
        if let version = object["version"] as? NSNumber, version.intValue != 1 {
            append(.unsupportedVersion, at: "$.version", to: &diagnostics)
        }
        validateDeclaredTypes(object, diagnostics: &diagnostics)
        guard diagnostics.isEmpty else {
            return .init(configuration: nil, diagnostics: diagnostics)
        }

        let document: RoamPiConfigurationDocument
        do {
            document = try JSONDecoder().decode(RoamPiConfigurationDocument.self, from: data)
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

        let canonicalData: Data
        do {
            canonicalData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            return .init(
                configuration: nil,
                diagnostics: [.init(code: .malformedJSON, location: "$")]
            )
        }
        return .init(
            configuration: .init(document: document, source: source, canonicalData: canonicalData),
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
        if machine.host.isEmpty || machine.host.count > 253 || containsControlCharacter(machine.host) {
            append(.invalidValue, at: path + ".host", to: &diagnostics)
        }
        if !(1 ... 65535).contains(machine.port) {
            append(.invalidValue, at: path + ".port", to: &diagnostics)
        }
        if machine.username.isEmpty || machine.username.count > 64 || containsControlCharacter(machine.username) {
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
            } else if let content = block.content, content.utf8.count > 65536 {
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
        if let placeholder = block.placeholder, placeholder.utf8.count > 256 {
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
            if dataSource.command?.isEmpty != false {
                append(.missingValue, at: path + ".command", to: &diagnostics)
            } else if let command = dataSource.command, command.utf8.count > 65536 {
                append(.invalidValue, at: path + ".command", to: &diagnostics)
            }
            if dataSource.targetMachineID?.isEmpty != false {
                append(.missingValue, at: path + ".targetMachineID", to: &diagnostics)
            }
            if let directory = dataSource.workingDirectory {
                if !isSafeAbsolutePath(directory) {
                    append(.unsafePath, at: path + ".workingDirectory", to: &diagnostics)
                }
            } else {
                append(.missingValue, at: path + ".workingDirectory", to: &diagnostics)
            }
            if dataSource.resultSchema == nil {
                append(.missingValue, at: path + ".resultSchema", to: &diagnostics)
            } else if let schema = dataSource.resultSchema {
                validateValueSchema(schema, at: path + ".resultSchema", depth: 0, diagnostics: &diagnostics)
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
        switch schema.type {
        case .object:
            let properties = schema.properties ?? [:]
            for required in schema.required ?? [] where properties[required] == nil {
                append(.invalidReference, at: path + ".required", to: &diagnostics)
            }
            for key in properties.keys.sorted() {
                if let child = properties[key] {
                    validateValueSchema(
                        child,
                        at: path + ".properties." + key,
                        depth: depth + 1,
                        diagnostics: &diagnostics
                    )
                }
            }
        case .array:
            if let items = schema.items {
                validateValueSchema(items, at: path + ".items", depth: depth + 1, diagnostics: &diagnostics)
            } else {
                append(.missingValue, at: path + ".items", to: &diagnostics)
            }
        case .string, .number, .integer, .boolean, .null:
            break
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
            } else if let prompt = action.prompt, prompt.utf8.count > 65536 {
                append(.invalidValue, at: path + ".prompt", to: &diagnostics)
            }
        case .command:
            if action.command?.isEmpty != false || action.prompt != nil {
                append(.invalidValue, at: path + ".command", to: &diagnostics)
            } else if let command = action.command, command.utf8.count > 65536 {
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
        guard depth <= 32 else {
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
        guard isValidIdentifier(key) else { return base + "[?]" }
        return base + "." + key
    }

    private static func isProhibitedKey(_ value: String) -> Bool {
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return prohibitedKeys.contains(where: { normalized == $0 || normalized.hasSuffix($0) })
    }

    private static func isValidDisplayName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && !containsControlCharacter(value)
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
        guard value.hasPrefix("/"), value.utf8.count <= 256, !containsControlCharacter(value) else {
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
