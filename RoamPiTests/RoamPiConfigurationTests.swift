import Foundation
import RoamPiCore
import Testing

private final class ConfigurationFixtureBundleMarker {}

@Suite("RoamPi configuration contract")
struct RoamPiConfigurationTests {
    @Test("Machine, project, multi-page, multi-machine, and command examples validate")
    func validExamples() throws {
        let minimal = try RoamPiConfigurationParser.parse(fixture("minimal.roampi"), source: .machine)
        let dashboard = try RoamPiConfigurationParser.parse(fixture("developer-dashboard.roampi"), source: .machine)
        let project = try RoamPiConfigurationParser.parse(
            fixture("project.roampi"),
            source: .project(root: "/Users/developer/Projects/SampleService", machineID: "studio")
        )

        #expect(minimal.configuration != nil)
        #expect(dashboard.configuration?.document.machine?.machines.count == 1)
        #expect(dashboard.configuration?.document.pages.first?.children.count == 1)
        #expect(dashboard.configuration?.document.dataSources.contains(where: { $0.type == .command }) == true)
        #expect(project.configuration?.document.project?.id == "sample-service")
        #expect(minimal.diagnostics.isEmpty)
        #expect(dashboard.diagnostics.isEmpty)
        #expect(project.diagnostics.isEmpty)
    }

    @Test(
        "Invalid fixtures return the expected bounded diagnostic and JSON location",
        arguments: [
            (
                "control-character-name.roampi",
                RoamPiConfigurationDiagnosticCode.invalidValue,
                "$.machine.homeHost.name"
            ),
            ("forward-version.roampi", RoamPiConfigurationDiagnosticCode.unsupportedVersion, "$.version"),
            (
                "duplicate-identifiers.roampi",
                RoamPiConfigurationDiagnosticCode.duplicateIdentifier,
                "$.machine.machines[0].id"
            ),
            (
                "oversized-integer.roampi",
                RoamPiConfigurationDiagnosticCode.invalidValue,
                "$.dataSources[0].value"
            ),
            ("secret-field.roampi", RoamPiConfigurationDiagnosticCode.secretField, "$[?]"),
            ("unsafe-path.roampi", RoamPiConfigurationDiagnosticCode.unsafePath, "$.machine.projects[0].path"),
        ]
    )
    func invalidFixtures(name: String, code: RoamPiConfigurationDiagnosticCode, location: String) throws {
        let result = try RoamPiConfigurationParser.parse(invalidFixture(name), source: .machine)

        #expect(result.configuration == nil)
        #expect(result.diagnostics.contains(.init(code: code, location: location)))
        #expect(result.diagnostics.allSatisfy {
            $0.location.count <= RoamPiConfigurationDiagnostic.maximumLocationLength
        })
    }

    @Test("Static data preserves an explicit JSON null")
    func staticNull() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "null-static",
            "type": "static",
            "value": NSNull(),
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration?.document.dataSources.first?.value == .null)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Static data preserves integers beyond binary floating-point precision")
    func staticLargeInteger() {
        let source = String(decoding: minimalMachineData(), as: UTF8.self)
        let data = Data(source.replacingOccurrences(
            of: #""dataSources":[]"#,
            with: #""dataSources":[{"id":"large-integer","type":"static","value":9007199254740993}]"#
        ).utf8)

        let result = RoamPiConfigurationParser.parse(data, source: .machine)

        #expect(result.configuration?.document.dataSources.first?.value == .integer(9_007_199_254_740_993))
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Exponential integers outside the exact range are rejected")
    func exponentialIntegerRange() {
        let source = String(decoding: minimalMachineData(), as: UTF8.self)
        let data = Data(source.replacingOccurrences(
            of: #""dataSources":[]"#,
            with: #""dataSources":[{"id":"exponential-integer","type":"static","value":1e128}]"#
        ).utf8)

        let result = RoamPiConfigurationParser.parse(data, source: .machine)

        #expect(result.configuration == nil)
        #expect(result.diagnostics == [
            .init(code: .invalidValue, location: "$.dataSources[0].value"),
        ])
    }

    @Test("Duplicate JSON object keys are rejected before decoding")
    func duplicateJSONKeyCanonicalization() {
        let source = String(decoding: minimalMachineData(), as: UTF8.self)
        let data = Data(source.replacingOccurrences(
            of: #""dataSources":[]"#,
            with: #""dataSources":[{"id":"duplicate-value","type":"static","value":{"token":"not-a-real-token"},"\u0076alue":{}}]"#
        ).utf8)

        let result = RoamPiConfigurationParser.parse(data, source: .machine)

        #expect(result.configuration == nil)
        #expect(result.diagnostics == [
            .init(code: .duplicateKey, location: "$[?]"),
        ])
    }

    @Test("Display-name limits count Unicode scalars")
    func displayNameScalarLimit() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        var machine = try #require(object["machine"] as? [String: Any])
        var homeHost = try #require(machine["homeHost"] as? [String: Any])
        homeHost["name"] = "H" + String(repeating: "\u{0301}", count: 128)
        machine["homeHost"] = homeHost
        object["machine"] = machine

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics.contains(.init(
            code: .invalidValue,
            location: "$.machine.homeHost.name"
        )))
    }

    @Test("Undeclared fields are rejected instead of ignored by Codable")
    func undeclaredField() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["downloadedView"] = "not allowed"

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics == [
            .init(code: .undeclaredField, location: "$[?]"),
        ])
    }

    @Test("Nested secret-bearing fields are rejected")
    func nestedSecretField() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "unsafe-static",
            "type": "static",
            "value": ["privateKeyPemBase64": "not-a-real-private-key"],
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics == [
            .init(code: .secretField, location: "$.dataSources[0].value[?]"),
        ])
    }

    @Test("Benign secret-like field names remain valid")
    func benignSecretLikeFields() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "benign-static",
            "type": "static",
            "value": [
                "passwordlessEnabled": true,
                "secretary": "available",
                "tokenCount": 3,
            ],
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration != nil)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Version-suffixed secret fields are rejected")
    func versionSuffixedSecretField() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "unsafe-static",
            "type": "static",
            "value": ["apiKeyV2": "not-a-real-key"],
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration == nil)
        #expect(result.diagnostics == [
            .init(code: .secretField, location: "$.dataSources[0].value[?]"),
        ])
    }

    @Test("Plural credential fields are rejected")
    func pluralCredentialField() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "unsafe-static",
            "type": "static",
            "value": ["sshPrivateKeys": ["not-a-real-key"]],
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration == nil)
        #expect(result.diagnostics == [
            .init(code: .secretField, location: "$.dataSources[0].value[?]"),
        ])
    }

    @Test("Compound secret-key fields are rejected")
    func compoundSecretKeyField() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "unsafe-static",
            "type": "static",
            "value": ["secretKey": "not-a-real-key"],
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration == nil)
        #expect(result.diagnostics == [
            .init(code: .secretField, location: "$.dataSources[0].value[?]"),
        ])
    }

    @Test("Passphrase fields are rejected")
    func passphraseSecretField() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "unsafe-static",
            "type": "static",
            "value": ["passphrase": "not-a-real-passphrase"],
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration == nil)
        #expect(result.diagnostics == [
            .init(code: .secretField, location: "$.dataSources[0].value[?]"),
        ])
    }

    @Test("Undeclared component types fail at their type location")
    func undeclaredComponent() throws {
        let result = try RoamPiConfigurationParser.parse(
            invalidFixture("unknown-component.roampi"),
            source: .project(root: "/Users/developer/Projects/Unknown", machineID: "home")
        )

        #expect(result.diagnostics == [
            .init(code: .undeclaredType, location: "$.pages[0].blocks[0].type"),
        ])
    }

    @Test("Machine configuration merges project contributions in deterministic namespaces")
    func deterministicMergeAndNamespaceIsolation() throws {
        let machine = try #require(try RoamPiConfigurationParser.parse(
            fixture("developer-dashboard.roampi"),
            source: .machine
        ).configuration)
        let project = try #require(try RoamPiConfigurationParser.parse(
            fixture("project.roampi"),
            source: .project(root: "/Users/developer/Projects/SampleService", machineID: "studio")
        ).configuration)

        let merged = try RoamPiConfigurationMerger.merge(
            machine: machine,
            projects: [project],
            discoveredProjects: [
                .init(id: "zeta", machineID: "build-host", path: "/srv/zeta", name: "Zeta"),
                .init(id: "alpha", machineID: "build-host", path: "/srv/alpha", name: "Alpha"),
                .init(id: "roampi-app", machineID: "studio", path: "/wrong", name: "Wrong"),
            ]
        )

        #expect(merged.pages.map(\.id) == ["dashboard", "project%sample-service%service-page"])
        #expect(merged.actions.map(\.action.id).contains("project%sample-service%deploy-preview"))
        #expect(merged.jobs.first(where: { $0.id.hasPrefix("project%sample-service") })?.actionID ==
            "project%sample-service%deploy-preview")
        #expect(merged.projects.map(\.id) == ["roampi-app", "alpha", "zeta", "sample-service"])
        #expect(merged.projects.first(where: { $0.id == "sample-service" })?.machineID == "studio")
        #expect(merged.projects.first?.name == "RoamPi")
        #expect(merged.projects.first?.path == "/Users/developer/Projects/RoamPiDemo")
        #expect(merged.fixedInterfaceRoutes == [.settings, .configurationRecovery])
        let effectiveAction = try #require(merged.actions.first(where: {
            $0.action.id == "project%sample-service%deploy-preview"
        }))
        #expect(effectiveAction.sourceFile == "/Users/developer/Projects/SampleService/.roampi")
        #expect(effectiveAction.configurationHash ==
            RoamPiActionTrustIdentityBuilder.configurationHash(for: project.canonicalData))
        #expect(try RoamPiActionTrustIdentityBuilder.build(
            action: effectiveAction,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/SampleService"
        ).value.count == 64)
        let commandDataSource = try #require(merged.dataSources.first(where: {
            $0.dataSource.id == "test-summary"
        }))
        #expect(commandDataSource.requiresApproval)
        #expect(try RoamPiActionTrustIdentityBuilder.build(
            dataSource: commandDataSource,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo"
        ).value.count == 64)
    }

    @Test("Escaped project namespaces cannot collide")
    func collisionFreeNamespaces() throws {
        let machine = try #require(RoamPiConfigurationParser.parse(minimalMachineData(), source: .machine)
            .configuration)
        let first = try #require(RoamPiConfigurationParser.parse(
            projectActionData(projectID: "a", actionID: "b.c"),
            source: .project(root: "/srv/first", machineID: "home")
        ).configuration)
        let second = try #require(RoamPiConfigurationParser.parse(
            projectActionData(projectID: "a.b", actionID: "c"),
            source: .project(root: "/srv/second", machineID: "home")
        ).configuration)

        let merged = try RoamPiConfigurationMerger.merge(machine: machine, projects: [first, second])

        #expect(Set(merged.actions.map(\.action.id)) == Set([
            "project%a%b%2Ec",
            "project%a%2Eb%c",
        ]))
    }

    @Test("Maximum project identifiers remain approvable after namespacing")
    func maximumNamespacedTrustIdentity() throws {
        let projectID = "a" + String(repeating: ".", count: 63)
        let actionID = "b" + String(repeating: ".", count: 63)
        let machine = try #require(RoamPiConfigurationParser.parse(minimalMachineData(), source: .machine)
            .configuration)
        let project = try #require(RoamPiConfigurationParser.parse(
            projectActionData(projectID: projectID, actionID: actionID),
            source: .project(root: "/srv/maximum", machineID: "home")
        ).configuration)
        let merged = try RoamPiConfigurationMerger.merge(machine: machine, projects: [project])
        let action = try #require(merged.actions.first)

        #expect(action.action.id.utf8.count > 128)
        #expect(try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/srv/maximum"
        ).value.count == 64)
    }

    @Test("Duplicate project diagnostics never expose identifiers")
    func duplicateProjectDiagnosticRedaction() throws {
        let machine = try #require(RoamPiConfigurationParser.parse(minimalMachineData(), source: .machine)
            .configuration)
        let first = try #require(RoamPiConfigurationParser.parse(
            projectData(id: "prod.example.com", pageID: "first-page"),
            source: .project(root: "/srv/first", machineID: "home")
        ).configuration)
        let second = try #require(RoamPiConfigurationParser.parse(
            projectData(id: "prod.example.com", pageID: "second-page"),
            source: .project(root: "/srv/second", machineID: "home")
        ).configuration)

        #expect(throws: RoamPiConfigurationDiagnostic(
            code: .duplicateIdentifier,
            location: "$projects[?].id"
        )) {
            try RoamPiConfigurationMerger.merge(machine: machine, projects: [first, second])
        }
    }

    @Test("Project files cannot claim an existing ID from another source")
    func projectSourceMismatch() throws {
        let machine = try #require(RoamPiConfigurationParser.parse(
            fixture("developer-dashboard.roampi"),
            source: .machine
        ).configuration)
        let project = try #require(RoamPiConfigurationParser.parse(
            projectData(id: "roampi-app", pageID: "claimed-page"),
            source: .project(root: "/srv/other", machineID: "build-host")
        ).configuration)

        #expect(throws: RoamPiConfigurationDiagnostic(
            code: .scopeViolation,
            location: "$projects[?].source"
        )) {
            try RoamPiConfigurationMerger.merge(machine: machine, projects: [project])
        }

        let unknownMachine = try #require(RoamPiConfigurationParser.parse(
            projectData(id: "unmapped-project", pageID: "unmapped-page"),
            source: .project(root: "/srv/unmapped", machineID: "unknown-host")
        ).configuration)
        #expect(throws: RoamPiConfigurationDiagnostic(
            code: .invalidReference,
            location: "$projects[?].source.machineID"
        )) {
            try RoamPiConfigurationMerger.merge(machine: machine, projects: [unknownMachine])
        }
    }

    @Test("Project merge order does not depend on input order")
    func deterministicProjectOrder() throws {
        let machine = try #require(RoamPiConfigurationParser.parse(minimalMachineData(), source: .machine)
            .configuration)
        let alpha = try #require(RoamPiConfigurationParser.parse(
            projectData(id: "alpha", pageID: "alpha-page"),
            source: .project(root: "/srv/alpha", machineID: "home")
        ).configuration)
        let zeta = try #require(RoamPiConfigurationParser.parse(
            projectData(id: "zeta", pageID: "zeta-page"),
            source: .project(root: "/srv/zeta", machineID: "home")
        ).configuration)

        let first = try RoamPiConfigurationMerger.merge(machine: machine, projects: [zeta, alpha])
        let second = try RoamPiConfigurationMerger.merge(machine: machine, projects: [alpha, zeta])

        #expect(first == second)
        #expect(first.pages.map(\.id) == ["project%alpha%alpha-page", "project%zeta%zeta-page"])
    }

    @Test("Machine overrides can disable project actions without dangling controls")
    func projectOverrideDisablesContribution() throws {
        var machineObject = try #require(JSONSerialization.jsonObject(
            with: fixture("developer-dashboard.roampi")
        ) as? [String: Any])
        var machine = try #require(machineObject["machine"] as? [String: Any])
        var overrides = try #require(machine["projectOverrides"] as? [[String: Any]])
        overrides.append([
            "projectID": "sample-service",
            "enabled": true,
            "disabledContributions": ["deploy-preview"],
        ])
        machine["projectOverrides"] = overrides
        machineObject["machine"] = machine
        let machineData = try JSONSerialization.data(withJSONObject: machineObject)
        let validatedMachine = try #require(RoamPiConfigurationParser.parse(machineData, source: .machine)
            .configuration)
        let project = try #require(RoamPiConfigurationParser.parse(
            fixture("project.roampi"),
            source: .project(root: "/Users/developer/Projects/SampleService", machineID: "studio")
        ).configuration)

        let merged = try RoamPiConfigurationMerger.merge(machine: validatedMachine, projects: [project])

        #expect(!merged.actions.contains(where: { $0.action.id.contains("deploy-preview") }))
        #expect(!merged.jobs.contains(where: { $0.id.contains("preview-job") }))
        #expect(!allBlocks(in: merged.pages).contains(where: { $0.id.contains("deploy-control") }))
        #expect(allBlocks(in: merged.pages).contains(where: { $0.id.contains("service-status") }))
    }

    @Test("Project contribution names follow the schema bounds")
    func projectContributionNameValidation() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("project.roampi")
        ) as? [String: Any])
        var project = try #require(object["project"] as? [String: Any])
        project["name"] = ""
        object["project"] = project

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .project(root: "/Users/developer/Projects/SampleService", machineID: "studio")
        )

        #expect(result.diagnostics == [
            .init(code: .invalidValue, location: "$.project.name"),
        ])
    }

    @Test("Optional page system images follow the schema bounds")
    func pageSystemImageValidation() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("developer-dashboard.roampi")
        ) as? [String: Any])
        var pages = try #require(object["pages"] as? [[String: Any]])
        pages[0]["systemImage"] = ""
        object["pages"] = pages

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics.contains(.init(
            code: .invalidValue,
            location: "$.pages[0].systemImage"
        )))
    }

    @Test("Jobs blocks require a job or data source")
    func jobsBlockSourceValidation() throws {
        let result = try RoamPiConfigurationParser.parse(
            invalidFixture("jobs-without-source.roampi"),
            source: .project(root: "/Users/developer/Projects/MissingJobSource", machineID: "home")
        )

        #expect(result.diagnostics.contains(.init(
            code: .missingValue,
            location: "$.pages[0].blocks[0].jobID"
        )))
    }

    @Test("Optional block titles follow the schema bounds")
    func blockTitleValidation() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("developer-dashboard.roampi")
        ) as? [String: Any])
        var pages = try #require(object["pages"] as? [[String: Any]])
        var blocks = try #require(pages[0]["blocks"] as? [[String: Any]])
        blocks[0]["title"] = ""
        pages[0]["blocks"] = blocks
        object["pages"] = pages

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics.contains(.init(
            code: .invalidValue,
            location: "$.pages[0].blocks[0].title"
        )))
    }

    @Test("Job titles follow the schema bounds")
    func jobTitleValidation() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("developer-dashboard.roampi")
        ) as? [String: Any])
        var jobs = try #require(object["jobs"] as? [[String: Any]])
        jobs[0]["title"] = ""
        object["jobs"] = jobs

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics.contains(.init(
            code: .invalidValue,
            location: "$.jobs[0].title"
        )))
    }

    @Test("Command data sources require an explicit working directory")
    func commandDataSourceWorkingDirectory() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("developer-dashboard.roampi")
        ) as? [String: Any])
        var dataSources = try #require(object["dataSources"] as? [[String: Any]])
        dataSources[2].removeValue(forKey: "workingDirectory")
        object["dataSources"] = dataSources

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics.contains(.init(
            code: .missingValue,
            location: "$.dataSources[2].workingDirectory"
        )))
    }

    @Test("Placeholder limits count Unicode scalars")
    func placeholderScalarLimit() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("developer-dashboard.roampi")
        ) as? [String: Any])
        var pages = try #require(object["pages"] as? [[String: Any]])
        var blocks = try #require(pages[0]["blocks"] as? [[String: Any]])
        blocks[0]["placeholder"] = String(repeating: "🧭", count: 100)
        pages[0]["blocks"] = blocks
        object["pages"] = pages

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration != nil)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Result-schema property names are redacted from diagnostics")
    func resultSchemaDiagnosticRedaction() {
        let data = Data(
            #"{"version":1,"kind":"project","project":{"id":"schema-redaction"},"pages":[],"dataSources":[{"id":"command-data","type":"command","command":"true","targetMachineID":"home","workingDirectory":"/srv/project","resultSchema":{"type":"object","properties":{"prod.example.com":{"type":"array"}}}}],"actions":[],"jobs":[]}"#
                .utf8
        )

        let result = RoamPiConfigurationParser.parse(
            data,
            source: .project(root: "/Users/developer/Projects/SchemaRedaction", machineID: "home")
        )

        #expect(result.diagnostics.contains(.init(
            code: .missingValue,
            location: "$.dataSources[0].resultSchema.properties[?].items"
        )))
        #expect(result.diagnostics.allSatisfy { !$0.location.contains("prod.example.com") })
    }

    @Test("Result-schema required names must be unique")
    func resultSchemaRequiredUniqueness() {
        let data = Data(
            #"{"version":1,"kind":"project","project":{"id":"schema-required"},"pages":[],"dataSources":[{"id":"command-data","type":"command","command":"true","targetMachineID":"home","workingDirectory":"/srv/project","resultSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name","name"]}}],"actions":[],"jobs":[]}"#
                .utf8
        )

        let result = RoamPiConfigurationParser.parse(
            data,
            source: .project(root: "/Users/developer/Projects/SchemaRequired", machineID: "home")
        )

        #expect(result.diagnostics.contains(.init(
            code: .duplicateIdentifier,
            location: "$.dataSources[0].resultSchema.required[1]"
        )))
    }

    @Test("Project command data sources reject invalid target identifiers")
    func projectDataSourceTargetIdentifier() {
        let data = Data(
            #"{"version":1,"kind":"project","project":{"id":"target-check"},"pages":[],"dataSources":[{"id":"command-data","type":"command","command":"true","targetMachineID":"bad id","workingDirectory":"/srv/project","resultSchema":{"type":"object"}}],"actions":[],"jobs":[]}"#
                .utf8
        )

        let result = RoamPiConfigurationParser.parse(
            data,
            source: .project(root: "/Users/developer/Projects/TargetCheck", machineID: "home")
        )

        #expect(result.diagnostics.contains(.init(
            code: .invalidValue,
            location: "$.dataSources[0].targetMachineID"
        )))
    }

    @Test("Static values do not inherit layout width bounds")
    func staticNumericValueOutsideLayoutBounds() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "large-measurement",
            "type": "static",
            "value": ["minimumWidth": 10000],
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.configuration != nil)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Optional data-source fields are validated in every variant")
    func optionalDataSourceFieldValidation() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("minimal.roampi")
        ) as? [String: Any])
        object["dataSources"] = [[
            "id": "static-with-invalid-path",
            "type": "static",
            "value": true,
            "workingDirectory": "relative",
        ]]

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics.contains(.init(
            code: .unsafePath,
            location: "$.dataSources[0].workingDirectory"
        )))
    }

    @Test("Adaptive layout rejects preferred widths below minimum widths")
    func adaptiveLayoutValidation() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: fixture("developer-dashboard.roampi")
        ) as? [String: Any])
        var pages = try #require(object["pages"] as? [[String: Any]])
        var page = pages[0]
        var blocks = try #require(page["blocks"] as? [[String: Any]])
        var block = blocks[0]
        block["layout"] = [
            "minimumWidth": 400,
            "preferredWidth": 200,
            "compactSpan": 12,
            "regularSpan": 8,
        ]
        blocks[0] = block
        page["blocks"] = blocks
        pages[0] = page
        object["pages"] = pages

        let result = try RoamPiConfigurationParser.parse(
            JSONSerialization.data(withJSONObject: object),
            source: .machine
        )

        #expect(result.diagnostics.contains(.init(
            code: .invalidValue,
            location: "$.pages[0].blocks[0].layout.preferredWidth"
        )))
    }

    @Test("Action trust identity changes with every trust-bound value")
    func actionTrustIdentity() throws {
        let configuration = try #require(RoamPiConfigurationParser.parse(
            fixture("developer-dashboard.roampi"),
            source: .machine
        ).configuration)
        let action = try #require(configuration.document.actions.first(where: { $0.id == "run-tests" }))
        let original = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo",
            canonicalConfiguration: configuration.canonicalData
        )
        let changedAction = RoamPiAction(
            id: action.id,
            title: action.title,
            type: .command,
            command: "./scripts/test-different-demo.sh",
            target: action.target,
            delivery: action.delivery,
            presentation: action.presentation,
            execution: action.execution,
            cancellation: action.cancellation,
            concurrency: action.concurrency
        )
        let changedSource = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: "/Users/developer/Projects/RoamPiDemo/.roampi",
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo",
            canonicalConfiguration: configuration.canonicalData
        )
        let changedCommand = try RoamPiActionTrustIdentityBuilder.build(
            action: changedAction,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo",
            canonicalConfiguration: configuration.canonicalData
        )
        let changedHost = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(host: "other.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo",
            canonicalConfiguration: configuration.canonicalData
        )
        let changedUsername = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(host: "studio.example.test", username: "operator", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo",
            canonicalConfiguration: configuration.canonicalData
        )
        let changedPort = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 2222),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo",
            canonicalConfiguration: configuration.canonicalData
        )
        let changedDirectory = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/Other",
            canonicalConfiguration: configuration.canonicalData
        )
        var changedConfiguration = configuration.canonicalData
        changedConfiguration.append(0x20)
        let changedHash = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/RoamPiDemo",
            canonicalConfiguration: changedConfiguration
        )

        #expect(Set([
            original.value,
            changedSource.value,
            changedCommand.value,
            changedHost.value,
            changedUsername.value,
            changedPort.value,
            changedDirectory.value,
            changedHash.value,
        ]).count == 8)
        let unicodeDestination = try RoamPiActionTrustIdentityBuilder.build(
            action: action,
            sourceFile: RoamPiConfigurationPaths.machine,
            resolvedDestination: .init(
                host: "studio.example.test",
                username: String(repeating: "é", count: 64),
                port: 22
            ),
            resolvedWorkingDirectory: "/" + String(repeating: "é", count: 255),
            canonicalConfiguration: configuration.canonicalData
        )

        #expect(original.value.count == 64)
        #expect(original.configurationHash.count == 64)
        #expect(unicodeDestination.value.count == 64)
    }

    @Test("Invalid updates preserve the last-known-good configuration and fixed routes")
    func lastKnownGoodReplacement() async throws {
        let store = RoamPiConfigurationStore()
        let accepted = try await store.update(machineData: fixture("developer-dashboard.roampi"))
        let rejected = try await store.update(machineData: invalidFixture("forward-version.roampi"))

        #expect(accepted.adopted)
        #expect(!rejected.adopted)
        #expect(rejected.configuration == accepted.configuration)
        #expect(rejected.diagnostics == [.init(code: .unsupportedVersion, location: "$.version")])
        #expect(rejected.configuration?.fixedInterfaceRoutes == [.settings, .configurationRecovery])
    }

    @Test("An invalid project update also preserves the complete last-known-good merge")
    func invalidProjectPreservesMerge() async throws {
        let store = RoamPiConfigurationStore()
        let accepted = try await store.update(
            machineData: fixture("developer-dashboard.roampi"),
            projects: [
                .init(
                    machineID: "studio",
                    root: "/Users/developer/Projects/SampleService",
                    data: fixture("project.roampi")
                ),
            ]
        )
        let rejected = try await store.update(
            machineData: fixture("developer-dashboard.roampi"),
            projects: [
                .init(
                    machineID: "studio",
                    root: "/Users/developer/Projects/SampleService",
                    data: invalidFixture("unknown-component.roampi")
                ),
            ]
        )

        #expect(accepted.adopted)
        #expect(!rejected.adopted)
        #expect(rejected.configuration == accepted.configuration)
        #expect(rejected.diagnostics == [
            .init(code: .undeclaredType, location: "$.pages[0].blocks[0].type"),
        ])
        let retainedAction = try #require(rejected.configuration?.actions.first(where: {
            $0.action.id == "project%sample-service%deploy-preview"
        }))
        #expect(try RoamPiActionTrustIdentityBuilder.build(
            action: retainedAction,
            resolvedDestination: .init(host: "studio.example.test", username: "developer", port: 22),
            resolvedWorkingDirectory: "/Users/developer/Projects/SampleService"
        ).configurationHash == retainedAction.configurationHash)
    }

    @Test("Unsafe discovered projects cannot replace last-known-good configuration")
    func unsafeDiscoveredProject() async throws {
        let store = RoamPiConfigurationStore()
        let accepted = try await store.update(machineData: fixture("minimal.roampi"))
        let rejected = try await store.update(
            machineData: fixture("minimal.roampi"),
            discoveredProjects: [
                .init(id: "unsafe", machineID: "home", path: "../../tmp", name: "Unsafe"),
            ]
        )

        #expect(accepted.adopted)
        #expect(!rejected.adopted)
        #expect(rejected.configuration == accepted.configuration)
        #expect(rejected.diagnostics == [
            .init(code: .unsafePath, location: "$discoveredProjects[0].path"),
        ])
    }

    @Test("Duplicate discovered project identifiers reject the complete update")
    func duplicateDiscoveredProjectIdentifiers() async throws {
        let store = RoamPiConfigurationStore()
        let accepted = try await store.update(machineData: fixture("developer-dashboard.roampi"))
        let rejected = try await store.update(
            machineData: fixture("developer-dashboard.roampi"),
            discoveredProjects: [
                .init(id: "shared-project", machineID: "studio", path: "/srv/studio", name: "Studio Project"),
                .init(id: "shared-project", machineID: "build-host", path: "/srv/build", name: "Build Project"),
            ]
        )

        #expect(accepted.adopted)
        #expect(!rejected.adopted)
        #expect(rejected.configuration == accepted.configuration)
        #expect(rejected.diagnostics == [
            .init(code: .duplicateIdentifier, location: "$discoveredProjects[1].id"),
        ])
    }

    @Test("Source scope mismatches are rejected")
    func sourceScope() throws {
        let result = try RoamPiConfigurationParser.parse(
            fixture("project.roampi"),
            source: .machine
        )

        #expect(result.configuration == nil)
        #expect(result.diagnostics == [.init(code: .scopeViolation, location: "$.kind")])
    }

    @Test("Excessive nesting stops before decoding")
    func excessiveNesting() throws {
        var nested: Any = "leaf"
        for _ in 0 ..< 34 {
            nested = ["child": nested]
        }
        let data = try JSONSerialization.data(withJSONObject: ["nested": nested])

        let result = RoamPiConfigurationParser.parse(data, source: .machine)

        #expect(result.configuration == nil)
        #expect(result.diagnostics.first?.code == .nestingTooDeep)
        #expect(result.diagnostics.first?.location.count ?? 0 <=
            RoamPiConfigurationDiagnostic.maximumLocationLength)
    }

    @Test("Malformed input reports no source content")
    func malformedInput() {
        let result = RoamPiConfigurationParser.parse(
            Data(#"{"version":1,"prompt":"private text""#.utf8),
            source: .machine
        )

        #expect(result.diagnostics == [.init(code: .malformedJSON, location: "$")])
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: ConfigurationFixtureBundleMarker.self).url(
            forResource: name,
            withExtension: nil,
            subdirectory: "examples"
        ))
        return try Data(contentsOf: url)
    }

    private func invalidFixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: ConfigurationFixtureBundleMarker.self).url(
            forResource: name,
            withExtension: nil,
            subdirectory: "examples/invalid"
        ))
        return try Data(contentsOf: url)
    }

    private func minimalMachineData() -> Data {
        Data(
            #"{"version":1,"kind":"machine","machine":{"homeHost":{"id":"home","name":"Home","host":"home.example.test","port":22,"username":"operator","visible":true},"machines":[],"projects":[],"projectOverrides":[],"fallbackBehavior":"includeDiscovered"},"pages":[],"dataSources":[],"actions":[],"jobs":[]}"#
                .utf8
        )
    }

    private func projectData(id: String, pageID: String) -> Data {
        Data(
            #"{"version":1,"kind":"project","project":{"id":"\#(id)"},"pages":[{"id":"\#(pageID)","title":"Page","blocks":[],"children":[]}],"dataSources":[],"actions":[],"jobs":[]}"#
                .utf8
        )
    }

    private func projectActionData(projectID: String, actionID: String) -> Data {
        Data(
            #"{"version":1,"kind":"project","project":{"id":"\#(projectID)"},"pages":[],"dataSources":[],"actions":[{"id":"\#(actionID)","title":"Action","type":"command","command":"true","target":{"machineID":"home","workingDirectory":"/srv/project"},"delivery":"immediate","presentation":"inline","execution":"inline","cancellation":"allowed","concurrency":"serial"}],"jobs":[]}"#
                .utf8
        )
    }

    private func allBlocks(in pages: [RoamPiPage]) -> [RoamPiBlock] {
        pages.flatMap { page in
            page.blocks.flatMap(flatten) + allBlocks(in: page.children)
        }
    }

    private func flatten(_ block: RoamPiBlock) -> [RoamPiBlock] {
        [block] + block.blocks.flatMap(flatten)
    }
}
