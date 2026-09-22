/// Which surface the drawer shows.
///
/// A file of its own rather than a neighbour of `AppSettingsStore`: the toolbar
/// probe compiles this type (with `DrawerModeToggle`) to measure what the toggle
/// costs, and it can only do that if the type does not drag the settings store,
/// UserDefaults and Combine in behind it.
enum DrawerMode: String, CaseIterable, Identifiable {
    case notes
    case reminders
    case plans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        case .plans: return "Plans"
        }
    }

    var systemImage: String {
        switch self {
        case .notes: return "square.and.pencil"
        case .reminders: return "checklist"
        case .plans: return "timer"
        }
    }
}
