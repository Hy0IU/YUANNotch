import SwiftUI

/// Switch between the drawer's notes, reminders, schedule and daily-plan surfaces.
///
/// Labels collapse to icons where the row cannot afford them. Who decides is
/// `NotebookToolbarLayout`, because the
/// row also carries the tab pager, the settings button and, in notes mode,
/// "Clear", and only that one place knows what all of them add up to.
///
/// It lives in a file of its own since it is the control the toolbar's reserve
/// has to budget for: `Scripts/toolbar-layout-probe.sh` compiles this file and
/// measures the two widths `NotebookToolbarLayout` assumes, so the numbers stop
/// being a claim about the fonts and become a check.
struct DrawerModeToggle: View {
    let mode: DrawerMode
    let showsLabels: Bool
    var usesMenu = false
    let onSelect: (DrawerMode) -> Void
    @Environment(\.appTypography) private var typography

    var body: some View {
        if usesMenu {
            Menu {
                ForEach(DrawerMode.allCases) { candidate in
                    Button {
                        onSelect(candidate)
                    } label: {
                        Label(candidate.title, systemImage: candidate.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .semibold))
                }
                .frame(width: 34, height: max(24, typography.lineHeight(.control) + 4))
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show \(mode.title) · switch tab")
            .accessibilityLabel("Switch tab, \(mode.title)")
        } else {
            segments
        }
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(DrawerMode.allCases) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: candidate.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                        if showsLabels {
                            Text(candidate.title)
                                .appText(.control, weight: candidate == mode ? .semibold : .regular)
                        }
                    }
                    .foregroundStyle(.white.opacity(candidate == mode ? 0.88 : 0.48))
                    .padding(.horizontal, showsLabels ? 7 : 6)
                    .frame(height: max(24, typography.lineHeight(.control) + 4))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(candidate == mode ? 0.1 : 0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(candidate.title)")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.045))
        )
    }
}
