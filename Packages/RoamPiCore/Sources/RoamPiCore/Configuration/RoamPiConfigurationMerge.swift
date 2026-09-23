import Foundation

public enum RoamPiFixedInterfaceRoute: String, CaseIterable, Codable, Sendable {
    case settings
    case configurationRecovery
}

public struct DiscoveredRoamPiProject: Equatable, Sendable {
    public let id: String
    public let machineID: String
    public let path: String
    public let name: String

    public init(id: String, machineID: String, path: String, name: String) {
        self.id = id
        self.machineID = machineID
        self.path = path
        self.name = name
    }
}

public struct EffectiveRoamPiConfiguration: Equatable, Sendable {
    public let machines: [RoamPiMachine]
    public let projects: [RoamPiProject]
    public let pages: [RoamPiPage]
    public let dataSources: [EffectiveRoamPiDataSource]
    public let actions: [EffectiveRoamPiAction]
    public let jobs: [RoamPiJob]
    public let fixedInterfaceRoutes: [RoamPiFixedInterfaceRoute]

    public init(
        machines: [RoamPiMachine],
        projects: [RoamPiProject],
        pages: [RoamPiPage],
        dataSources: [EffectiveRoamPiDataSource],
        actions: [EffectiveRoamPiAction],
        jobs: [RoamPiJob]
    ) {
        self.machines = machines
        self.projects = projects
        self.pages = pages
        self.dataSources = dataSources
        self.actions = actions
        self.jobs = jobs
        fixedInterfaceRoutes = RoamPiFixedInterfaceRoute.allCases
    }
}

public enum RoamPiConfigurationMerger {
    public static func merge(
        machine: ValidatedRoamPiConfiguration,
        projects: [ValidatedRoamPiConfiguration],
        discoveredProjects: [DiscoveredRoamPiProject] = []
    ) throws -> EffectiveRoamPiConfiguration {
        guard machine.document.kind == .machine, let machineConfiguration = machine.document.machine else {
            throw RoamPiConfigurationDiagnostic(code: .scopeViolation, location: "$machine")
        }
        guard projects.allSatisfy({ $0.document.kind == .project && $0.document.project != nil }) else {
            throw RoamPiConfigurationDiagnostic(code: .scopeViolation, location: "$projects")
        }
        try validate(discoveredProjects: discoveredProjects)

        let orderedProjectConfigurations = projects.sorted {
            let lhs = $0.document.project?.id ?? ""
            let rhs = $1.document.project?.id ?? ""
            if lhs == rhs {
                return $0.source.filePath < $1.source.filePath
            }
            return lhs < rhs
        }
        var seenProjectConfigurations = Set<String>()
        for configuration in orderedProjectConfigurations {
            guard let identifier = configuration.document.project?.id else { continue }
            guard seenProjectConfigurations.insert(identifier).inserted else {
                throw RoamPiConfigurationDiagnostic(
                    code: .duplicateIdentifier,
                    location: "$projects[?].id"
                )
            }
        }

        try validateProjectSources(
            machine: machineConfiguration,
            projectConfigurations: orderedProjectConfigurations,
            discoveredProjects: discoveredProjects
        )

        let overrides = Dictionary(
            machineConfiguration.projectOverrides.map { ($0.projectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let machines = [machineConfiguration.homeHost] + machineConfiguration.machines
        var effectiveProjects = baseProjects(
            machineConfiguration,
            projectConfigurations: orderedProjectConfigurations,
            discoveredProjects: discoveredProjects
        )
        effectiveProjects = effectiveProjects.map { project in
            guard let override = overrides[project.id] else { return project }
            return RoamPiProject(
                id: project.id,
                machineID: project.machineID,
                path: project.path,
                name: override.name ?? project.name,
                group: override.group ?? project.group,
                visible: override.visible ?? project.visible,
                discovery: project.discovery
            )
        }

        var pages = machine.document.pages
        var dataSources = machine.document.dataSources
        var dataSourceProvenance = Dictionary(uniqueKeysWithValues: machine.document.dataSources.map {
            (
                $0.id,
                (
                    sourceFile: machine.source.filePath,
                    configurationHash: RoamPiActionTrustIdentityBuilder.configurationHash(
                        for: machine.canonicalData
                    )
                )
            )
        })
        var actions = machine.document.actions
        var actionProvenance = Dictionary(uniqueKeysWithValues: machine.document.actions.map {
            (
                $0.id,
                (
                    sourceFile: machine.source.filePath,
                    configurationHash: RoamPiActionTrustIdentityBuilder.configurationHash(
                        for: machine.canonicalData
                    )
                )
            )
        })
        var jobs = machine.document.jobs

        for configuration in orderedProjectConfigurations {
            guard let contribution = configuration.document.project else { continue }
            let override = overrides[contribution.id]
            guard override?.enabled != false else { continue }
            let disabled = Set(override?.disabledContributions ?? [])
            let filtered = filter(configuration.document, disabled: disabled)
            pages.append(contentsOf: filtered.pages.map { namespace($0, projectID: contribution.id) })
            let projectDataSources = filtered.dataSources.map { namespace($0, projectID: contribution.id) }
            let projectActions = filtered.actions.map { namespace($0, projectID: contribution.id) }
            let projectHash = RoamPiActionTrustIdentityBuilder.configurationHash(
                for: configuration.canonicalData
            )
            for dataSource in projectDataSources {
                dataSourceProvenance[dataSource.id] = (
                    sourceFile: configuration.source.filePath,
                    configurationHash: projectHash
                )
            }
            for action in projectActions {
                actionProvenance[action.id] = (
                    sourceFile: configuration.source.filePath,
                    configurationHash: projectHash
                )
            }
            dataSources.append(contentsOf: projectDataSources)
            actions.append(contentsOf: projectActions)
            jobs.append(contentsOf: filtered.jobs.map { namespace($0, projectID: contribution.id) })
        }

        let machineIDs = Set(machines.map(\.id))
        if effectiveProjects.contains(where: { !machineIDs.contains($0.machineID) }) {
            throw RoamPiConfigurationDiagnostic(
                code: .invalidReference,
                location: "$merge.projects[?].machineID"
            )
        }
        if dataSources.contains(where: {
            $0.targetMachineID.map { !machineIDs.contains($0) } == true
        }) {
            throw RoamPiConfigurationDiagnostic(
                code: .invalidReference,
                location: "$merge.dataSources[?].targetMachineID"
            )
        }
        if actions.contains(where: { !machineIDs.contains($0.target.machineID) }) {
            throw RoamPiConfigurationDiagnostic(
                code: .invalidReference,
                location: "$merge.actions[?].target.machineID"
            )
        }

        let effectiveDataSources = try dataSources.map { dataSource in
            guard let provenance = dataSourceProvenance[dataSource.id] else {
                throw RoamPiConfigurationDiagnostic(
                    code: .invalidReference,
                    location: "$merge.dataSources[?].provenance"
                )
            }
            return EffectiveRoamPiDataSource(
                dataSource: dataSource,
                sourceFile: provenance.sourceFile,
                configurationHash: provenance.configurationHash
            )
        }
        let effectiveActions = try actions.map { action in
            guard let provenance = actionProvenance[action.id] else {
                throw RoamPiConfigurationDiagnostic(
                    code: .invalidReference,
                    location: "$merge.actions[?].provenance"
                )
            }
            return EffectiveRoamPiAction(
                action: action,
                sourceFile: provenance.sourceFile,
                configurationHash: provenance.configurationHash
            )
        }
        return EffectiveRoamPiConfiguration(
            machines: machines,
            projects: effectiveProjects,
            pages: pages,
            dataSources: effectiveDataSources,
            actions: effectiveActions,
            jobs: jobs
        )
    }

    private static func validateProjectSources(
        machine: RoamPiMachineConfiguration,
        projectConfigurations: [ValidatedRoamPiConfiguration],
        discoveredProjects: [DiscoveredRoamPiProject]
    ) throws {
        let machineIDs = Set([machine.homeHost.id] + machine.machines.map(\.id))
        let declaredByID = Dictionary(machine.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let discoveredByID = Dictionary(
            discoveredProjects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for configuration in projectConfigurations {
            guard let contribution = configuration.document.project,
                  let sourceMachineID = configuration.source.projectMachineID,
                  let sourceRoot = configuration.source.projectRoot
            else {
                throw RoamPiConfigurationDiagnostic(code: .scopeViolation, location: "$projects[?].source")
            }
            guard machineIDs.contains(sourceMachineID) else {
                throw RoamPiConfigurationDiagnostic(
                    code: .invalidReference,
                    location: "$projects[?].source.machineID"
                )
            }
            if let declared = declaredByID[contribution.id] {
                guard declared.machineID == sourceMachineID, declared.path == sourceRoot else {
                    throw RoamPiConfigurationDiagnostic(code: .scopeViolation, location: "$projects[?].source")
                }
            } else if let discovered = discoveredByID[contribution.id] {
                guard discovered.machineID == sourceMachineID, discovered.path == sourceRoot else {
                    throw RoamPiConfigurationDiagnostic(code: .scopeViolation, location: "$projects[?].source")
                }
            }
        }
    }

    private static func validate(discoveredProjects: [DiscoveredRoamPiProject]) throws {
        var identifiers = Set<String>()
        for (index, project) in discoveredProjects.enumerated() {
            let path = "$discoveredProjects[\(index)]"
            guard isValidIdentifier(project.id) else {
                throw RoamPiConfigurationDiagnostic(code: .invalidValue, location: path + ".id")
            }
            guard identifiers.insert(project.id).inserted else {
                throw RoamPiConfigurationDiagnostic(code: .duplicateIdentifier, location: path + ".id")
            }
            guard isValidIdentifier(project.machineID) else {
                throw RoamPiConfigurationDiagnostic(code: .invalidValue, location: path + ".machineID")
            }
            guard isSafeAbsolutePath(project.path) else {
                throw RoamPiConfigurationDiagnostic(code: .unsafePath, location: path + ".path")
            }
            guard !project.name.isEmpty,
                  project.name.unicodeScalars.count <= 128,
                  !project.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw RoamPiConfigurationDiagnostic(code: .invalidValue, location: path + ".name")
            }
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1 ... 64).contains(bytes.count) && bytes.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 256 && value.hasPrefix("/") &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func baseProjects(
        _ machine: RoamPiMachineConfiguration,
        projectConfigurations: [ValidatedRoamPiConfiguration],
        discoveredProjects: [DiscoveredRoamPiProject]
    ) -> [RoamPiProject] {
        var result: [RoamPiProject] = switch machine.fallbackBehavior {
        case .declaredOnly, .includeDiscovered:
            machine.projects
        case .discoveredOnly:
            []
        }
        var identifiers = Set(result.map(\.id))

        if machine.fallbackBehavior != .declaredOnly {
            for discovered in discoveredProjects.sorted(by: discoveredProjectOrder)
                where identifiers.insert(discovered.id).inserted
            {
                result.append(RoamPiProject(
                    id: discovered.id,
                    machineID: discovered.machineID,
                    path: discovered.path,
                    name: discovered.name,
                    visible: true,
                    discovery: .session
                ))
            }
        }

        for configuration in projectConfigurations {
            guard let contribution = configuration.document.project,
                  let root = configuration.source.projectRoot,
                  let sourceMachineID = configuration.source.projectMachineID
            else { continue }
            if let index = result.firstIndex(where: { $0.id == contribution.id }) {
                guard result[index].discovery == .session else { continue }
                let discovered = result[index]
                result[index] = RoamPiProject(
                    id: discovered.id,
                    machineID: discovered.machineID,
                    path: discovered.path,
                    name: contribution.name ?? discovered.name,
                    group: contribution.group ?? discovered.group,
                    visible: contribution.visible ?? discovered.visible,
                    discovery: .session
                )
            } else {
                _ = identifiers.insert(contribution.id)
                result.append(RoamPiProject(
                    id: contribution.id,
                    machineID: sourceMachineID,
                    path: root,
                    name: contribution.name ?? contribution.id,
                    group: contribution.group,
                    visible: contribution.visible ?? true,
                    discovery: .explicit
                ))
            }
        }
        return result
    }

    private static func discoveredProjectOrder(
        _ lhs: DiscoveredRoamPiProject,
        _ rhs: DiscoveredRoamPiProject
    ) -> Bool {
        if lhs.machineID != rhs.machineID {
            return lhs.machineID < rhs.machineID
        }
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.id < rhs.id
    }

    private static func filter(
        _ document: RoamPiConfigurationDocument,
        disabled: Set<String>
    ) -> (
        pages: [RoamPiPage],
        dataSources: [RoamPiDataSource],
        actions: [RoamPiAction],
        jobs: [RoamPiJob]
    ) {
        let actions = document.actions.filter { !disabled.contains($0.id) }
        let actionIDs = Set(actions.map(\.id))
        let dataSources = document.dataSources.filter { !disabled.contains($0.id) }
        let dataSourceIDs = Set(dataSources.map(\.id))
        let jobs = document.jobs.filter {
            !disabled.contains($0.id) && actionIDs.contains($0.actionID)
        }
        let jobIDs = Set(jobs.map(\.id))
        let pages = document.pages.compactMap {
            filter(
                $0,
                disabled: disabled,
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs
            )
        }
        return (pages, dataSources, actions, jobs)
    }

    private static func filter(
        _ page: RoamPiPage,
        disabled: Set<String>,
        dataSourceIDs: Set<String>,
        actionIDs: Set<String>,
        jobIDs: Set<String>
    ) -> RoamPiPage? {
        guard !disabled.contains(page.id) else { return nil }
        let blocks = page.blocks.compactMap {
            filter(
                $0,
                disabled: disabled,
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs
            )
        }
        let children = page.children.compactMap {
            filter(
                $0,
                disabled: disabled,
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs
            )
        }
        return RoamPiPage(
            id: page.id,
            title: page.title,
            systemImage: page.systemImage,
            blocks: blocks,
            children: children
        )
    }

    private static func filter(
        _ block: RoamPiBlock,
        disabled: Set<String>,
        dataSourceIDs: Set<String>,
        actionIDs: Set<String>,
        jobIDs: Set<String>
    ) -> RoamPiBlock? {
        guard !disabled.contains(block.id) else { return nil }
        if let identifier = block.dataSourceID, !dataSourceIDs.contains(identifier) {
            return nil
        }
        if let identifier = block.actionID, !actionIDs.contains(identifier) {
            return nil
        }
        if let identifier = block.jobID, !jobIDs.contains(identifier) {
            return nil
        }
        let blocks = block.blocks.compactMap {
            filter(
                $0,
                disabled: disabled,
                dataSourceIDs: dataSourceIDs,
                actionIDs: actionIDs,
                jobIDs: jobIDs
            )
        }
        if block.type == .section || block.type == .grid, blocks.isEmpty {
            return nil
        }
        return RoamPiBlock(
            id: block.id,
            type: block.type,
            title: block.title,
            layout: block.layout,
            blocks: blocks,
            dataSourceID: block.dataSourceID,
            content: block.content,
            inputKind: block.inputKind,
            placeholder: block.placeholder,
            actionID: block.actionID,
            jobID: block.jobID
        )
    }

    private static func namespace(_ identifier: String, projectID: String) -> String {
        "project%\(escapedNamespaceComponent(projectID))%\(escapedNamespaceComponent(identifier))"
    }

    private static func escapedNamespaceComponent(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: "%2E")
    }

    private static func namespace(_ page: RoamPiPage, projectID: String) -> RoamPiPage {
        RoamPiPage(
            id: namespace(page.id, projectID: projectID),
            title: page.title,
            systemImage: page.systemImage,
            blocks: page.blocks.map { namespace($0, projectID: projectID) },
            children: page.children.map { namespace($0, projectID: projectID) }
        )
    }

    private static func namespace(_ block: RoamPiBlock, projectID: String) -> RoamPiBlock {
        RoamPiBlock(
            id: namespace(block.id, projectID: projectID),
            type: block.type,
            title: block.title,
            layout: block.layout,
            blocks: block.blocks.map { namespace($0, projectID: projectID) },
            dataSourceID: block.dataSourceID.map { namespace($0, projectID: projectID) },
            content: block.content,
            inputKind: block.inputKind,
            placeholder: block.placeholder,
            actionID: block.actionID.map { namespace($0, projectID: projectID) },
            jobID: block.jobID.map { namespace($0, projectID: projectID) }
        )
    }

    private static func namespace(_ dataSource: RoamPiDataSource, projectID: String) -> RoamPiDataSource {
        RoamPiDataSource(
            id: namespace(dataSource.id, projectID: projectID),
            type: dataSource.type,
            value: dataSource.value,
            builtin: dataSource.builtin,
            command: dataSource.command,
            targetMachineID: dataSource.targetMachineID,
            workingDirectory: dataSource.workingDirectory,
            resultSchema: dataSource.resultSchema
        )
    }

    private static func namespace(_ action: RoamPiAction, projectID: String) -> RoamPiAction {
        RoamPiAction(
            id: namespace(action.id, projectID: projectID),
            title: action.title,
            type: action.type,
            prompt: action.prompt,
            command: action.command,
            target: action.target,
            delivery: action.delivery,
            presentation: action.presentation,
            execution: action.execution,
            cancellation: action.cancellation,
            concurrency: action.concurrency
        )
    }

    private static func namespace(_ job: RoamPiJob, projectID: String) -> RoamPiJob {
        RoamPiJob(
            id: namespace(job.id, projectID: projectID),
            title: job.title,
            actionID: namespace(job.actionID, projectID: projectID),
            retainResult: job.retainResult
        )
    }
}

public struct RoamPiProjectConfigurationInput: Sendable {
    public let machineID: String
    public let root: String
    public let data: Data

    public init(machineID: String, root: String, data: Data) {
        self.machineID = machineID
        self.root = root
        self.data = data
    }
}

public struct RoamPiConfigurationUpdate: Equatable, Sendable {
    public let configuration: EffectiveRoamPiConfiguration?
    public let diagnostics: [RoamPiConfigurationDiagnostic]
    public let adopted: Bool

    public init(
        configuration: EffectiveRoamPiConfiguration?,
        diagnostics: [RoamPiConfigurationDiagnostic],
        adopted: Bool
    ) {
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.adopted = adopted
    }
}

public actor RoamPiConfigurationStore {
    private var lastKnownGood: EffectiveRoamPiConfiguration?

    public init() {}

    public func update(
        machineData: Data,
        projects: [RoamPiProjectConfigurationInput] = [],
        discoveredProjects: [DiscoveredRoamPiProject] = []
    ) -> RoamPiConfigurationUpdate {
        let machineResult = RoamPiConfigurationParser.parse(machineData, source: .machine)
        var diagnostics = machineResult.diagnostics
        var validatedProjects: [ValidatedRoamPiConfiguration] = []
        for project in projects.sorted(by: {
            $0.machineID == $1.machineID ? $0.root < $1.root : $0.machineID < $1.machineID
        }) {
            let result = RoamPiConfigurationParser.parse(
                project.data,
                source: .project(root: project.root, machineID: project.machineID)
            )
            diagnostics.append(contentsOf: result.diagnostics)
            if let configuration = result.configuration {
                validatedProjects.append(configuration)
            }
        }

        guard diagnostics.isEmpty, let machine = machineResult.configuration else {
            return .init(configuration: lastKnownGood, diagnostics: Array(diagnostics.prefix(32)), adopted: false)
        }
        do {
            let merged = try RoamPiConfigurationMerger.merge(
                machine: machine,
                projects: validatedProjects,
                discoveredProjects: discoveredProjects
            )
            lastKnownGood = merged
            return .init(configuration: merged, diagnostics: [], adopted: true)
        } catch let diagnostic as RoamPiConfigurationDiagnostic {
            return .init(configuration: lastKnownGood, diagnostics: [diagnostic], adopted: false)
        } catch {
            return .init(
                configuration: lastKnownGood,
                diagnostics: [.init(code: .invalidValue, location: "$")],
                adopted: false
            )
        }
    }

    public func current() -> EffectiveRoamPiConfiguration? {
        lastKnownGood
    }
}
