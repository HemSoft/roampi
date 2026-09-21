import Foundation

/// Static, fictional content used by UI tests, screenshots, and App Review.
/// Loading this fixture performs no file or network access.
enum DemoFixture {
    static let dashboard = DashboardSnapshot(
        title: "Good evening",
        subtitle: "Your Pi workspace is ready",
        machines: [
            DemoMachine(
                id: "studio-mini",
                name: "Studio Mini",
                detail: "Primary workspace",
                platform: "macOS 26.5",
                status: .online,
                latency: "18 ms",
                projects: [
                    DemoProject(
                        id: "atlas-mobile",
                        name: "Atlas Mobile",
                        branch: "feature/offline-sync",
                        detail: "3 sessions"
                    ),
                    DemoProject(
                        id: "northstar-api",
                        name: "Northstar API",
                        branch: "main",
                        detail: "1 session"
                    ),
                ],
                sessions: [
                    DemoSession(
                        id: "review-sync",
                        name: "Review offline sync",
                        model: "Claude Sonnet 4.5",
                        status: .running,
                        updated: "Now"
                    ),
                    DemoSession(
                        id: "fix-tests",
                        name: "Fix flaky snapshot tests",
                        model: "GPT-5.4",
                        status: .waiting,
                        updated: "4 min"
                    ),
                    DemoSession(
                        id: "release-notes",
                        name: "Draft release notes",
                        model: "Claude Sonnet 4.5",
                        status: .idle,
                        updated: "1 hr"
                    ),
                ],
                jobs: [
                    DemoJob(
                        id: "test-suite",
                        name: "iOS test suite",
                        detail: "142 of 186 tests",
                        status: .working
                    ),
                    DemoJob(
                        id: "dependency-audit",
                        name: "Dependency audit",
                        detail: "Waiting for test suite",
                        status: .queued
                    ),
                ]
            ),
            DemoMachine(
                id: "build-box",
                name: "Build Box",
                detail: "Shared Linux runner",
                platform: "Ubuntu 26.04",
                status: .relay,
                latency: "64 ms",
                projects: [
                    DemoProject(
                        id: "weather-service",
                        name: "Weather Service",
                        branch: "fix/cache-expiry",
                        detail: "2 sessions"
                    ),
                ],
                sessions: [
                    DemoSession(
                        id: "profile-cache",
                        name: "Profile cache misses",
                        model: "GPT-5.4",
                        status: .running,
                        updated: "2 min"
                    ),
                ],
                jobs: [
                    DemoJob(
                        id: "linux-build",
                        name: "Linux release build",
                        detail: "Artifacts ready",
                        status: .complete
                    ),
                ]
            ),
            DemoMachine(
                id: "travel-air",
                name: "Travel Air",
                detail: "Personal laptop",
                platform: "macOS 26.5",
                status: .offline,
                latency: "Last seen 2 hr",
                projects: [],
                sessions: [],
                jobs: []
            ),
        ]
    )
}
