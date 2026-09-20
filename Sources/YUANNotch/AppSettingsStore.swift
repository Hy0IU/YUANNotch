import Combine
import Foundation

enum TriggerMode: String, CaseIterable, Identifiable {
    case hover
    case click

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover:
            return "Hover"
        case .click:
            return "Click"
        }
    }

    var systemImage: String {
        switch self {
        case .hover:
            return "cursorarrow.motionlines"
        case .click:
            return "cursorarrow.click.2"
        }
    }
}

/// Which surface the drawer shows. Defined in DrawerMode.swift.
@MainActor
final class AppSettingsStore: ObservableObject {
    /// Persisted, so the drawer reopens on the mode it was left in.
    ///
    /// Because this writes through on every assignment, a *temporary* mode
    /// change must never go through here — see
    /// `NotebookWorkspaceState.fileDragForcesNotesMode`.
    @Published var drawerMode: DrawerMode {
        didSet {
            UserDefaults.standard.set(drawerMode.rawValue, forKey: Self.drawerModeKey)
        }
    }

    @Published var triggerMode: TriggerMode {
        didSet {
            UserDefaults.standard.set(triggerMode.rawValue, forKey: Self.triggerModeKey)
        }
    }

    @Published var hoverActivationDelay: Double {
        didSet {
            UserDefaults.standard.set(hoverActivationDelay, forKey: Self.hoverActivationDelayKey)
        }
    }

    @Published var customExpandedSize: CGSize? {
        didSet {
            if let size = customExpandedSize {
                UserDefaults.standard.set(size.width, forKey: Self.expandedWidthKey)
                UserDefaults.standard.set(size.height, forKey: Self.expandedHeightKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.expandedWidthKey)
                UserDefaults.standard.removeObject(forKey: Self.expandedHeightKey)
            }
        }
    }

    @Published var isFileShelfEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isFileShelfEnabled, forKey: Self.fileShelfEnabledKey)
        }
    }

    /// Corner radii of the fully expanded panel. The compact notch shape
    /// stays fixed; the reveal animation interpolates toward these values.
    @Published var expandedTopCornerRadius: Double {
        didSet {
            UserDefaults.standard.set(expandedTopCornerRadius, forKey: Self.expandedTopCornerRadiusKey)
        }
    }

    @Published var expandedBottomCornerRadius: Double {
        didSet {
            UserDefaults.standard.set(expandedBottomCornerRadius, forKey: Self.expandedBottomCornerRadiusKey)
        }
    }

    /// Master switch for the Apple Reminders integration. The integration is
    /// the only source of reminders for this app, so with it off the reminders
    /// panel has nothing to read or write.
    @Published var isAppleRemindersSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAppleRemindersSyncEnabled, forKey: Self.appleRemindersEnabledKey)
        }
    }

    /// The list reminders are read from and written to. Single source of truth
    /// for the selected list — the settings page and the reminders panel both
    /// read and write this one value, never a copy.
    @Published var remindersCalendarIdentifier: String? {
        didSet {
            if let identifier = remindersCalendarIdentifier {
                UserDefaults.standard.set(identifier, forKey: Self.appleRemindersListIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.appleRemindersListIDKey)
            }
        }
    }

    /// How the reminders panel orders the rows inside each group. Read by
    /// `ReminderStore.groupedItems` and written by the panel's sort menu —
    /// the settings page and the panel share this one value, never a copy,
    /// and it survives both a mode switch and a relaunch.
    ///
    /// The default is `ReminderSortOrder.added`: the list is a working
    /// surface, so what was just added is what should be found first.
    @Published var reminderSortOrder: ReminderSortOrder = .added {
        didSet {
            UserDefaults.standard.set(reminderSortOrder.rawValue, forKey: Self.reminderSortOrderKey)
        }
    }

    static let defaultExpandedTopCornerRadius: Double = 10
    static let defaultExpandedBottomCornerRadius: Double = 20
    static let defaultHoverActivationDelay: Double = 0.30
    static let hoverActivationDelayRange: ClosedRange<Double> = 0...2

    private static let triggerModeKey = "yuanNotch.triggerMode"
    private static let drawerModeKey = "yuanNotch.drawerMode"
    private static let hoverActivationDelayKey = "yuanNotch.hoverActivationDelay"
    private static let expandedWidthKey = "yuanNotch.expandedWidth"
    private static let expandedHeightKey = "yuanNotch.expandedHeight"
    private static let fileShelfEnabledKey = "yuanNotch.fileShelfEnabled"
    private static let expandedTopCornerRadiusKey = "yuanNotch.expandedTopCornerRadius"
    private static let expandedBottomCornerRadiusKey = "yuanNotch.expandedBottomCornerRadius"
    private static let appleRemindersEnabledKey = "yuanNotch.appleReminders.enabled"
    private static let appleRemindersListIDKey = "yuanNotch.appleReminders.listID"
    private static let reminderSortOrderKey = "yuanNotch.appleReminders.sortOrder"

    init() {
        drawerMode = UserDefaults.standard.string(forKey: Self.drawerModeKey)
            .flatMap(DrawerMode.init(rawValue:)) ?? .notes

        let rawMode = UserDefaults.standard.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover

        let storedHoverDelay = UserDefaults.standard.object(forKey: Self.hoverActivationDelayKey) == nil
            ? Self.defaultHoverActivationDelay
            : UserDefaults.standard.double(forKey: Self.hoverActivationDelayKey)
        hoverActivationDelay = min(
            max(storedHoverDelay, Self.hoverActivationDelayRange.lowerBound),
            Self.hoverActivationDelayRange.upperBound
        )

        let w = UserDefaults.standard.double(forKey: Self.expandedWidthKey)
        let h = UserDefaults.standard.double(forKey: Self.expandedHeightKey)
        customExpandedSize = (w > 0 && h > 0) ? CGSize(width: w, height: h) : nil

        isFileShelfEnabled = UserDefaults.standard.object(forKey: Self.fileShelfEnabledKey) as? Bool ?? true

        expandedTopCornerRadius = Self.loadRadius(
            forKey: Self.expandedTopCornerRadiusKey,
            fallback: Self.defaultExpandedTopCornerRadius
        )
        expandedBottomCornerRadius = Self.loadRadius(
            forKey: Self.expandedBottomCornerRadiusKey,
            fallback: Self.defaultExpandedBottomCornerRadius
        )

        isAppleRemindersSyncEnabled = UserDefaults.standard
            .object(forKey: Self.appleRemindersEnabledKey) as? Bool ?? false
        remindersCalendarIdentifier = UserDefaults.standard
            .string(forKey: Self.appleRemindersListIDKey)
        reminderSortOrder = UserDefaults.standard
            .string(forKey: Self.reminderSortOrderKey)
            .flatMap(ReminderSortOrder.init(rawValue:)) ?? .added
    }

    private static func loadRadius(forKey key: String, fallback: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let value = UserDefaults.standard.double(forKey: key)
        return value >= 0 ? value : fallback
    }
}
