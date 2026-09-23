import Foundation

public enum RoamPiConfigurationPaths {
    public static let machine = "~/.pi/agent/.roampi"
    public static let projectFileName = ".roampi"
}

public enum RoamPiConfigurationKind: String, Codable, Sendable {
    case machine
    case project
}

public struct RoamPiConfigurationDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let kind: RoamPiConfigurationKind
    public let machine: RoamPiMachineConfiguration?
    public let project: RoamPiProjectContribution?
    public let pages: [RoamPiPage]
    public let dataSources: [RoamPiDataSource]
    public let actions: [RoamPiAction]
    public let jobs: [RoamPiJob]

    public init(
        version: Int = 1,
        kind: RoamPiConfigurationKind,
        machine: RoamPiMachineConfiguration? = nil,
        project: RoamPiProjectContribution? = nil,
        pages: [RoamPiPage] = [],
        dataSources: [RoamPiDataSource] = [],
        actions: [RoamPiAction] = [],
        jobs: [RoamPiJob] = []
    ) {
        self.version = version
        self.kind = kind
        self.machine = machine
        self.project = project
        self.pages = pages
        self.dataSources = dataSources
        self.actions = actions
        self.jobs = jobs
    }
}

public struct RoamPiMachineConfiguration: Codable, Equatable, Sendable {
    public let homeHost: RoamPiMachine
    public let machines: [RoamPiMachine]
    public let projects: [RoamPiProject]
    public let projectOverrides: [RoamPiProjectOverride]
    public let fallbackBehavior: RoamPiFallbackBehavior

    public init(
        homeHost: RoamPiMachine,
        machines: [RoamPiMachine] = [],
        projects: [RoamPiProject] = [],
        projectOverrides: [RoamPiProjectOverride] = [],
        fallbackBehavior: RoamPiFallbackBehavior = .includeDiscovered
    ) {
        self.homeHost = homeHost
        self.machines = machines
        self.projects = projects
        self.projectOverrides = projectOverrides
        self.fallbackBehavior = fallbackBehavior
    }
}

public struct RoamPiMachine: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: Int
    public let username: String
    public let group: String?
    public let visible: Bool

    public init(
        id: String,
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        group: String? = nil,
        visible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.group = group
        self.visible = visible
    }
}

public enum RoamPiProjectDiscovery: String, Codable, Sendable {
    case explicit
    case session
}

public struct RoamPiProject: Codable, Equatable, Sendable {
    public let id: String
    public let machineID: String
    public let path: String
    public let name: String
    public let group: String?
    public let visible: Bool
    public let discovery: RoamPiProjectDiscovery

    public init(
        id: String,
        machineID: String,
        path: String,
        name: String,
        group: String? = nil,
        visible: Bool = true,
        discovery: RoamPiProjectDiscovery = .explicit
    ) {
        self.id = id
        self.machineID = machineID
        self.path = path
        self.name = name
        self.group = group
        self.visible = visible
        self.discovery = discovery
    }
}

public struct RoamPiProjectContribution: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let group: String?
    public let visible: Bool?

    public init(id: String, name: String? = nil, group: String? = nil, visible: Bool? = nil) {
        self.id = id
        self.name = name
        self.group = group
        self.visible = visible
    }
}

public struct RoamPiProjectOverride: Codable, Equatable, Sendable {
    public let projectID: String
    public let name: String?
    public let group: String?
    public let visible: Bool?
    public let enabled: Bool
    public let disabledContributions: [String]

    public init(
        projectID: String,
        name: String? = nil,
        group: String? = nil,
        visible: Bool? = nil,
        enabled: Bool = true,
        disabledContributions: [String] = []
    ) {
        self.projectID = projectID
        self.name = name
        self.group = group
        self.visible = visible
        self.enabled = enabled
        self.disabledContributions = disabledContributions
    }
}

public enum RoamPiFallbackBehavior: String, Codable, Sendable {
    case declaredOnly
    case includeDiscovered
    case discoveredOnly
}

public struct RoamPiPage: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let blocks: [RoamPiBlock]
    public let children: [RoamPiPage]

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        blocks: [RoamPiBlock] = [],
        children: [RoamPiPage] = []
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.blocks = blocks
        self.children = children
    }
}

public enum RoamPiBlockType: String, CaseIterable, Codable, Sendable {
    case section
    case grid
    case list
    case status
    case markdown
    case input
    case sessions
    case jobs
    case action
}

public struct RoamPiAdaptiveLayout: Codable, Equatable, Sendable {
    public let minimumWidth: Double?
    public let preferredWidth: Double?
    public let compactSpan: Int
    public let regularSpan: Int

    public init(
        minimumWidth: Double? = nil,
        preferredWidth: Double? = nil,
        compactSpan: Int = 12,
        regularSpan: Int = 12
    ) {
        self.minimumWidth = minimumWidth
        self.preferredWidth = preferredWidth
        self.compactSpan = compactSpan
        self.regularSpan = regularSpan
    }
}

public enum RoamPiInputKind: String, Codable, Sendable {
    case text
    case secureText
    case toggle
    case selection
}

public struct RoamPiBlock: Codable, Equatable, Sendable {
    public let id: String
    public let type: RoamPiBlockType
    public let title: String?
    public let layout: RoamPiAdaptiveLayout
    public let blocks: [RoamPiBlock]
    public let dataSourceID: String?
    public let content: String?
    public let inputKind: RoamPiInputKind?
    public let placeholder: String?
    public let actionID: String?
    public let jobID: String?

    public init(
        id: String,
        type: RoamPiBlockType,
        title: String? = nil,
        layout: RoamPiAdaptiveLayout = .init(),
        blocks: [RoamPiBlock] = [],
        dataSourceID: String? = nil,
        content: String? = nil,
        inputKind: RoamPiInputKind? = nil,
        placeholder: String? = nil,
        actionID: String? = nil,
        jobID: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.layout = layout
        self.blocks = blocks
        self.dataSourceID = dataSourceID
        self.content = content
        self.inputKind = inputKind
        self.placeholder = placeholder
        self.actionID = actionID
        self.jobID = jobID
    }
}

public enum RoamPiJSONValue: Codable, Equatable, Sendable {
    case object([String: RoamPiJSONValue])
    case array([RoamPiJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RoamPiJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RoamPiJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum RoamPiValueType: String, Codable, Sendable {
    case object
    case array
    case string
    case number
    case integer
    case boolean
    case null
}

public final class RoamPiValueSchema: Codable, Equatable, Sendable {
    public let type: RoamPiValueType
    public let properties: [String: RoamPiValueSchema]?
    public let required: [String]?
    public let items: RoamPiValueSchema?

    public init(
        type: RoamPiValueType,
        properties: [String: RoamPiValueSchema]? = nil,
        required: [String]? = nil,
        items: RoamPiValueSchema? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.items = items
    }

    public static func == (lhs: RoamPiValueSchema, rhs: RoamPiValueSchema) -> Bool {
        lhs.type == rhs.type &&
            lhs.properties == rhs.properties &&
            lhs.required == rhs.required &&
            lhs.items == rhs.items
    }
}

public enum RoamPiDataSourceType: String, Codable, Sendable {
    case `static`
    case builtin
    case command
}

public enum RoamPiBuiltinData: String, Codable, Sendable {
    case machines
    case projects
    case sessions
    case jobs
    case connectionStatus
}

public struct RoamPiDataSource: Codable, Equatable, Sendable {
    public let id: String
    public let type: RoamPiDataSourceType
    public let value: RoamPiJSONValue?
    public let builtin: RoamPiBuiltinData?
    public let command: String?
    public let targetMachineID: String?
    public let workingDirectory: String?
    public let resultSchema: RoamPiValueSchema?

    public init(
        id: String,
        type: RoamPiDataSourceType,
        value: RoamPiJSONValue? = nil,
        builtin: RoamPiBuiltinData? = nil,
        command: String? = nil,
        targetMachineID: String? = nil,
        workingDirectory: String? = nil,
        resultSchema: RoamPiValueSchema? = nil
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.builtin = builtin
        self.command = command
        self.targetMachineID = targetMachineID
        self.workingDirectory = workingDirectory
        self.resultSchema = resultSchema
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case value
        case builtin
        case command
        case targetMachineID
        case workingDirectory
        case resultSchema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(RoamPiDataSourceType.self, forKey: .type)
        value = container.contains(.value)
            ? try RoamPiJSONValue(from: container.superDecoder(forKey: .value))
            : nil
        builtin = try container.decodeIfPresent(RoamPiBuiltinData.self, forKey: .builtin)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        targetMachineID = try container.decodeIfPresent(String.self, forKey: .targetMachineID)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        resultSchema = try container.decodeIfPresent(RoamPiValueSchema.self, forKey: .resultSchema)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(builtin, forKey: .builtin)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(targetMachineID, forKey: .targetMachineID)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(resultSchema, forKey: .resultSchema)
    }
}

public enum RoamPiActionType: String, Codable, Sendable {
    case prompt
    case command
}

public enum RoamPiPromptDelivery: String, Codable, Sendable {
    case immediate
    case followUp
    case steering
}

public enum RoamPiResultPresentation: String, Codable, Sendable {
    case inline
    case sheet
    case terminal
    case notification
}

public enum RoamPiExecutionMode: String, Codable, Sendable {
    case inline
    case durable
}

public enum RoamPiCancellationPolicy: String, Codable, Sendable {
    case allowed
    case disabled
}

public enum RoamPiConcurrencyPolicy: String, Codable, Sendable {
    case serial
    case rejectNew
    case replaceCurrent
    case parallel
}

public struct RoamPiActionTarget: Codable, Equatable, Sendable {
    public let machineID: String
    public let workingDirectory: String

    public init(machineID: String, workingDirectory: String) {
        self.machineID = machineID
        self.workingDirectory = workingDirectory
    }
}

public struct RoamPiAction: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let type: RoamPiActionType
    public let prompt: String?
    public let command: String?
    public let target: RoamPiActionTarget
    public let delivery: RoamPiPromptDelivery
    public let presentation: RoamPiResultPresentation
    public let execution: RoamPiExecutionMode
    public let cancellation: RoamPiCancellationPolicy
    public let concurrency: RoamPiConcurrencyPolicy

    public init(
        id: String,
        title: String,
        type: RoamPiActionType,
        prompt: String? = nil,
        command: String? = nil,
        target: RoamPiActionTarget,
        delivery: RoamPiPromptDelivery = .immediate,
        presentation: RoamPiResultPresentation = .inline,
        execution: RoamPiExecutionMode = .inline,
        cancellation: RoamPiCancellationPolicy = .allowed,
        concurrency: RoamPiConcurrencyPolicy = .serial
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.prompt = prompt
        self.command = command
        self.target = target
        self.delivery = delivery
        self.presentation = presentation
        self.execution = execution
        self.cancellation = cancellation
        self.concurrency = concurrency
    }
}

public struct RoamPiJob: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let actionID: String
    public let retainResult: Bool

    public init(id: String, title: String, actionID: String, retainResult: Bool = true) {
        self.id = id
        self.title = title
        self.actionID = actionID
        self.retainResult = retainResult
    }
}
