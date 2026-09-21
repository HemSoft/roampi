import Foundation

struct DashboardSnapshot: Equatable, Sendable {
    let title: String
    let subtitle: String
    let machines: [DemoMachine]

    static let empty = DashboardSnapshot(
        title: "Welcome to RoamPi",
        subtitle: "Add a remote machine when connectivity support is available.",
        machines: []
    )

    var availableMachineCount: Int {
        machines.filter { $0.status != .offline }.count
    }

    var activeSessionCount: Int {
        machines.flatMap(\.sessions).filter { $0.status == .running }.count
    }

    var pendingJobCount: Int {
        machines.flatMap(\.jobs).filter { $0.status == .queued || $0.status == .working }.count
    }
}

struct DemoMachine: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let platform: String
    let status: ConnectionStatus
    let latency: String
    let projects: [DemoProject]
    let sessions: [DemoSession]
    let jobs: [DemoJob]
}

struct DemoProject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let branch: String
    let detail: String
}

struct DemoSession: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let model: String
    let status: SessionStatus
    let updated: String
}

struct DemoJob: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let status: JobStatus
}

enum ConnectionStatus: String, Equatable, Sendable {
    case online = "Online"
    case relay = "Via relay"
    case offline = "Offline"
}

enum SessionStatus: String, Equatable, Sendable {
    case running = "Running"
    case waiting = "Waiting"
    case idle = "Idle"
}

enum JobStatus: String, Equatable, Sendable {
    case working = "Working"
    case queued = "Queued"
    case complete = "Complete"
}

struct DashboardState: Equatable, Sendable {
    let selectedMachineID: DemoMachine.ID?

    static func initial(snapshot: DashboardSnapshot) -> DashboardState {
        DashboardState(selectedMachineID: snapshot.machines.first?.id)
    }
}
