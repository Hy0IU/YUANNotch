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
            defaults.set(drawerMode.rawValue, forKey: Self.drawerModeKey)
        }
    }

    @Published var triggerMode: TriggerMode {
        didSet {
            defaults.set(triggerMode.rawValue, forKey: Self.triggerModeKey)
        }
    }

    @Published var hoverActivationDelay: Double {
        didSet {
            defaults.set(hoverActivationDelay, forKey: Self.hoverActivationDelayKey)
        }
    }

    @Published var customExpandedSize: CGSize? {
        didSet {
            if let size = customExpandedSize {
                defaults.set(size.width, forKey: Self.expandedWidthKey)
                defaults.set(size.height, forKey: Self.expandedHeightKey)
            } else {
                defaults.removeObject(forKey: Self.expandedWidthKey)
                defaults.removeObject(forKey: Self.expandedHeightKey)
            }
        }
    }

    @Published var isFileShelfEnabled: Bool {
        didSet {
            defaults.set(isFileShelfEnabled, forKey: Self.fileShelfEnabledKey)
        }
    }

    /// Corner radii of the fully expanded panel. The compact notch shape
    /// stays fixed; the reveal animation interpolates toward these values.
    @Published var expandedTopCornerRadius: Double {
        didSet {
            defaults.set(expandedTopCornerRadius, forKey: Self.expandedTopCornerRadiusKey)
        }
    }

    @Published var expandedBottomCornerRadius: Double {
        didSet {
            defaults.set(expandedBottomCornerRadius, forKey: Self.expandedBottomCornerRadiusKey)
        }
    }

    /// Master switch for the Apple Reminders integration. The integration is
    /// the only source of reminders for this app, so with it off the reminders
    /// panel has nothing to read or write.
    @Published var isAppleRemindersSyncEnabled: Bool {
        didSet {
            defaults.set(isAppleRemindersSyncEnabled, forKey: Self.appleRemindersEnabledKey)
        }
    }

    /// The list reminders are read from and written to. Single source of truth
    /// for the selected list — the settings page and the reminders panel both
    /// read and write this one value, never a copy.
    @Published var remindersCalendarIdentifier: String? {
        didSet {
            if let identifier = remindersCalendarIdentifier {
                defaults.set(identifier, forKey: Self.appleRemindersListIDKey)
            } else {
                defaults.removeObject(forKey: Self.appleRemindersListIDKey)
            }
        }
    }

    /// The reminder lists pinned into the drawer's capsule strip, in display
    /// order. These are views onto EventKit calendars, not calendars of their
    /// own: adding one must never create or mutate anything in Reminders.app.
    @Published var reminderListViewIdentifiers: [String] {
        didSet {
            if reminderListViewIdentifiers.isEmpty {
                defaults.removeObject(forKey: Self.appleRemindersListViewsKey)
            } else {
                defaults.set(
                    reminderListViewIdentifiers,
                    forKey: Self.appleRemindersListViewsKey
                )
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
            defaults.set(reminderSortOrder.rawValue, forKey: Self.reminderSortOrderKey)
        }
    }

    /// The interface text scale is shared by the app's controls and settings.
    @Published var interfaceTextSize: InterfaceTextSize {
        didSet {
            defaults.set(interfaceTextSize.rawValue, forKey: Self.interfaceTextSizeKey)
        }
    }

    /// Note text has its own point size, independent of the interface scale.
    @Published var noteFontSize: Double {
        didSet {
            let normalized = AppTypography.normalizedNoteFontSize(noteFontSize)
            if noteFontSize != normalized {
                noteFontSize = normalized
            }
            defaults.set(normalized, forKey: Self.noteFontSizeKey)
        }
    }

    var typography: AppTypography {
        AppTypography(interfaceSize: interfaceTextSize, noteFontSize: CGFloat(noteFontSize))
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
    private static let appleRemindersListViewsKey = "yuanNotch.appleReminders.listViews"
    private static let reminderSortOrderKey = "yuanNotch.appleReminders.sortOrder"
    static let interfaceTextSizeKey = "yuanNotch.typography.interfaceSize"
    static let noteFontSizeKey = "yuanNotch.typography.noteFontSize"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        drawerMode = defaults.string(forKey: Self.drawerModeKey)
            .flatMap(DrawerMode.init(rawValue:)) ?? .notes

        let rawMode = defaults.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover

        let storedHoverDelay = defaults.object(forKey: Self.hoverActivationDelayKey) == nil
            ? Self.defaultHoverActivationDelay
            : defaults.double(forKey: Self.hoverActivationDelayKey)
        hoverActivationDelay = min(
            max(storedHoverDelay, Self.hoverActivationDelayRange.lowerBound),
            Self.hoverActivationDelayRange.upperBound
        )

        let w = defaults.double(forKey: Self.expandedWidthKey)
        let h = defaults.double(forKey: Self.expandedHeightKey)
        customExpandedSize = (w > 0 && h > 0) ? CGSize(width: w, height: h) : nil

        isFileShelfEnabled = defaults.object(forKey: Self.fileShelfEnabledKey) as? Bool ?? true

        expandedTopCornerRadius = Self.loadRadius(
            defaults: defaults,
            forKey: Self.expandedTopCornerRadiusKey,
            fallback: Self.defaultExpandedTopCornerRadius
        )
        expandedBottomCornerRadius = Self.loadRadius(
            defaults: defaults,
            forKey: Self.expandedBottomCornerRadiusKey,
            fallback: Self.defaultExpandedBottomCornerRadius
        )

        isAppleRemindersSyncEnabled = defaults
            .object(forKey: Self.appleRemindersEnabledKey) as? Bool ?? false
        let storedReminderListID = defaults
            .string(forKey: Self.appleRemindersListIDKey)
        remindersCalendarIdentifier = storedReminderListID
        reminderListViewIdentifiers = defaults
            .stringArray(forKey: Self.appleRemindersListViewsKey)
            ?? storedReminderListID.map { [$0] }
            ?? []
        reminderSortOrder = defaults
            .string(forKey: Self.reminderSortOrderKey)
            .flatMap(ReminderSortOrder.init(rawValue:)) ?? .added

        interfaceTextSize = defaults.string(forKey: Self.interfaceTextSizeKey)
            .flatMap(InterfaceTextSize.init(rawValue:)) ?? .standard
        let storedNoteFontSize = (defaults.object(forKey: Self.noteFontSizeKey) as? NSNumber)?.doubleValue
            ?? AppTypography.defaultNoteFontSize
        noteFontSize = AppTypography.normalizedNoteFontSize(storedNoteFontSize)
    }

    private static func loadRadius(defaults: UserDefaults, forKey key: String, fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.double(forKey: key)
        return value >= 0 ? value : fallback
    }
}
