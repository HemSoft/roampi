import SwiftUI

struct DashboardView: View {
    let snapshot: DashboardSnapshot

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedMachineID: DemoMachine.ID?

    init(snapshot: DashboardSnapshot) {
        self.snapshot = snapshot
        _selectedMachineID = State(initialValue: DashboardState.initial(snapshot: snapshot).selectedMachineID)
    }

    private var selectedMachine: DemoMachine {
        snapshot.machines.first(where: { $0.id == selectedMachineID }) ?? snapshot.machines[0]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DashboardBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        DashboardHeader(snapshot: snapshot)
                        SummaryStrip(snapshot: snapshot)

                        if horizontalSizeClass == .regular {
                            regularLayout
                        } else {
                            compactLayout
                        }
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 30 : 18)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("demo-dashboard")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Label("RoamPi", systemImage: "terminal.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {}) {
                        Image(systemName: "bell")
                    }
                    .accessibilityLabel("Notifications")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .tint(Color.accentColor)
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Machines", detail: "Fictional demo fleet")

                ForEach(snapshot.machines) { machine in
                    MachineButton(
                        machine: machine,
                        isSelected: machine.id == selectedMachine.id,
                        action: { selectedMachineID = machine.id }
                    )
                }
            }
            .frame(width: 300)

            MachineDetail(machine: selectedMachine, isCompact: false)
                .id(selectedMachine.id)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: selectedMachine.id)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Machines", detail: "Tap to switch workspace")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(snapshot.machines) { machine in
                            MachineButton(
                                machine: machine,
                                isSelected: machine.id == selectedMachine.id,
                                action: { selectedMachineID = machine.id }
                            )
                            .frame(width: 250)
                        }
                    }
                }
                .contentMargins(.horizontal, 1, for: .scrollContent)
            }

            MachineDetail(machine: selectedMachine, isCompact: true)
                .id(selectedMachine.id)
        }
        .animation(.easeInOut(duration: 0.2), value: selectedMachine.id)
    }
}

private struct DashboardHeader: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(snapshot.subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryStrip: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        HStack(spacing: 10) {
            SummaryPill(value: "\(snapshot.availableMachineCount)", label: "available", icon: "network")
            SummaryPill(value: "\(snapshot.activeSessionCount)", label: "active", icon: "sparkles")
            SummaryPill(value: "\(snapshot.pendingJobCount)", label: "jobs", icon: "clock.arrow.circlepath")
        }
        .accessibilityIdentifier("dashboard-summary")
    }
}

private struct SummaryPill: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}

private struct MachineButton: View {
    let machine: DemoMachine
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(machine.status.color.opacity(0.14))
                    Image(systemName: machine.status == .offline ? "laptopcomputer.slash" : "desktopcomputer")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(machine.status.color)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(machine.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(machine.status.color)
                            .frame(width: 6, height: 6)
                        Text(machine.status.rawValue)
                        Text("·")
                        Text(machine.latency)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("machine-\(machine.id)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct MachineDetail: View {
    let machine: DemoMachine
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(machine.name)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("\(machine.platform) · \(machine.status.rawValue)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: machine.status)
            }

            if machine.status == .offline {
                OfflineCard()
            } else {
                LazyVGrid(
                    columns: isCompact ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ProjectsCard(projects: machine.projects)
                    SessionsCard(sessions: machine.sessions)
                    JobsCard(jobs: machine.jobs)
                        .gridCellColumns(isCompact ? 1 : 2)
                }
            }
        }
        .padding(isCompact ? 0 : 22)
        .background(isCompact ? Color.clear : Color.cardBackground, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            if !isCompact {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.cardBorder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("machine-detail-\(machine.id)")
    }
}

private struct ProjectsCard: View {
    let projects: [DemoProject]

    var body: some View {
        DashboardCard(title: "Projects", icon: "folder.fill", count: projects.count) {
            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.name)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(project.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Label(project.branch, systemImage: "arrow.triangle.branch")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                if project.id != projects.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct SessionsCard: View {
    let sessions: [DemoSession]

    var body: some View {
        DashboardCard(title: "Pi sessions", icon: "sparkles", count: sessions.count) {
            ForEach(sessions) { session in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(session.status.color)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(session.model) · \(session.updated)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(session.status.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(session.status.color)
                }
                .accessibilityElement(children: .combine)

                if session.id != sessions.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct JobsCard: View {
    let jobs: [DemoJob]

    var body: some View {
        DashboardCard(title: "Recent jobs", icon: "checklist", count: jobs.count) {
            ForEach(jobs) { job in
                HStack(spacing: 12) {
                    Image(systemName: job.status.icon)
                        .foregroundStyle(job.status.color)
                        .symbolEffect(.pulse, isActive: job.status == .working)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.name)
                            .font(.subheadline.weight(.semibold))
                        Text(job.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(job.status.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(job.status.color)
                }
                .accessibilityElement(children: .combine)

                if job.id != jobs.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            content
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }
}

private struct StatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.rawValue)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(status.color.opacity(0.12), in: Capsule())
    }
}

private struct OfflineCard: View {
    var body: some View {
        ContentUnavailableView(
            "Machine unavailable",
            systemImage: "wifi.slash",
            description: Text("Demo data keeps this machine offline to show the disconnected state.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DashboardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            Circle()
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.1 : 0.07))
                .frame(width: 420, height: 420)
                .blur(radius: 3)
                .offset(x: 190, y: -330)
        }
        .ignoresSafeArea()
    }
}

private extension ConnectionStatus {
    var color: Color {
        switch self {
        case .online: .green
        case .relay: .orange
        case .offline: .secondary
        }
    }
}

private extension SessionStatus {
    var color: Color {
        switch self {
        case .running: Color.accentColor
        case .waiting: .orange
        case .idle: .secondary
        }
    }
}

private extension JobStatus {
    var color: Color {
        switch self {
        case .working: Color.accentColor
        case .queued: .orange
        case .complete: .green
        }
    }

    var icon: String {
        switch self {
        case .working: "arrow.trianglehead.2.clockwise.rotate.90"
        case .queued: "clock"
        case .complete: "checkmark.circle.fill"
        }
    }
}

private extension Color {
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardBorder = Color.primary.opacity(0.08)
}
