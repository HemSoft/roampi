@testable import RoamPi
import Testing

@Suite("Deterministic demo fixture")
struct DemoFixtureTests {
    @Test("Fixture contains stable fictional dashboard data")
    func fixtureContents() {
        let snapshot = DemoFixture.dashboard

        #expect(snapshot.title == "Good evening")
        #expect(snapshot.machines.map(\.id) == ["studio-mini", "build-box", "travel-air"])
        #expect(snapshot.machines.flatMap(\.projects).count == 3)
        #expect(snapshot.machines.flatMap(\.sessions).count == 4)
        #expect(snapshot.machines.flatMap(\.jobs).count == 3)
        #expect(snapshot.machines.allSatisfy { !$0.name.isEmpty && !$0.platform.isEmpty })
    }

    @Test("Fixture summary derives from machine state")
    func fixtureSummary() {
        let snapshot = DemoFixture.dashboard

        #expect(snapshot.availableMachineCount == 2)
        #expect(snapshot.activeSessionCount == 2)
        #expect(snapshot.pendingJobCount == 2)
    }

    @Test("Initial dashboard selects the first machine")
    func initialDashboardState() {
        let state = DashboardState.initial(snapshot: DemoFixture.dashboard)

        #expect(state.selectedMachineID == "studio-mini")
    }

    @Test("Empty dashboard has no initial selection")
    func emptyDashboardState() {
        let state = DashboardState.initial(snapshot: .empty)

        #expect(state.selectedMachineID == nil)
    }
}
