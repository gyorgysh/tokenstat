// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Which half of the editor is on screen. Phone uses one at a time. iPad
/// shows both.
enum AutomationFieldsSection: Hashable {
    case writing
    case settings
}

/// Creation and editing use the same writing space and settings vocabulary.
struct AutomationFieldsView: View {
    @Binding var fields: AutomationEditorDraft
    let backends: [AgentBackend]
    let folderName: String
    let folderLocked: Bool
    let folders: [WorkspaceFolder]
    let wide: Bool
    let minimumHeight: CGFloat
    let draftStatus: String
    var showValidation = true
    var hostName: String = ""
    var timezone: String = ""
    var nextCaption: String? = nil
    var section: AutomationFieldsSection? = nil

    var body: some View {
        switch section {
        case .writing:
            writing(minimumHeight: minimumHeight, fills: true)
        case .settings:
            settings
        case nil:
            if wide {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    writing(minimumHeight: minimumHeight, fills: false)
                    ThemeRule.vertical
                    settings.frame(width: 280)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    writing(minimumHeight: minimumHeight, fills: false)
                    settings
                }
            }
        }
    }

    private func writing(minimumHeight: CGFloat, fills: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TextField(L10n.text("apple.automationfieldsview.job_name.be810260"), text: $fields.name, axis: .vertical)
                .font(Theme.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.text("apple.automationfieldsview.job_name.be810260"))
            ThemeRule()
            Text(fields.backend == "sh" ? L10n.text("apple.automationfieldsview.command.71316697") : L10n.text("apple.automationfieldsview.prompt.5c391238"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            TextEditor(text: $fields.prompt)
                .font(Theme.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: fills ? nil : minimumHeight)
                .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
                .accessibilityLabel(fields.backend == "sh" ? L10n.text("apple.automationfieldsview.job_command.25d04df2") : L10n.text("apple.automationfieldsview.job_prompt.ac4bfabd"))
            Text(draftStatus)
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if section != .settings {
                Text(L10n.text("apple.automationfieldsview.job_settings.4aefa68c")).font(Theme.callout.weight(.semibold))
            }
            if folderLocked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("apple.automationfieldsview.folder.74ccd433"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    Text(folderName)
                        .font(Theme.callout)
                    Text(L10n.text("apple.automationfieldsview.this_job_runs_in_this_folder_on_the_connec.91eeb5c8"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
            } else {
                AppMenuPicker(title: L10n.text("apple.automationfieldsview.folder.74ccd433"), options: folderOptions, selection: $fields.workspaceID)
            }
            AppMenuPicker(
                title: L10n.text("apple.automationfieldsview.agent.11b39c93"),
                options: backendOptions,
                selection: Binding(
                    get: { fields.backend },
                    set: { value in
                        guard value != fields.backend else { return }
                        fields.backend = value
                        fields.model = ""
                        fields.effort = ""
                    }
                )
            )
            if let backend = backends.first(where: { $0.id == fields.backend }) {
                if !backend.models.isEmpty || !fields.model.isEmpty {
                    FavoriteModelPicker(
                        backendID: backend.id,
                        models: backend.models,
                        extra: fields.model,
                        preservesSavedSelection: true,
                        selection: $fields.model
                    )
                }
                if !backend.efforts.isEmpty || !fields.effort.isEmpty {
                    AppMenuPicker(
                        title: L10n.text("apple.automationfieldsview.effort.4387e5d3"),
                        options: effortOptions(backend.efforts, preserving: fields.effort),
                        selection: $fields.effort
                    )
                }
                if !fields.model.isEmpty && !backend.models.contains(fields.model) {
                    Text(L10n.text("apple.automationfieldsview.this_computer_does_not_list_the_saved_mode.479cd2e2"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
            } else if !fields.model.isEmpty || !fields.effort.isEmpty {
                Text([fields.model, fields.effort].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            ThemeRule()
            AutomationScheduleFields(
                fields: $fields,
                hostName: hostName,
                timezone: timezone,
                nextCaption: nextCaption
            )
            ThemeRule()
            AutomationBudgetFields(fields: $fields)
            if showValidation, let validation = fields.validation {
                Text(validation)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private var folderOptions: [(value: String, label: String)] {
        var values = [(value: "", label: L10n.text("apple.automationfieldsview.choose_a_folder.5c71b8cd"))] + folders.map { (value: $0.id, label: $0.name) }
        if !values.contains(where: { $0.value == fields.workspaceID }) {
            values.append((fields.workspaceID, L10n.text("apple.automationfieldsview.unavailable_folder.6454a349")))
        }
        return values
    }

    private var backendOptions: [(value: String, label: String)] {
        var values = [(value: "", label: L10n.text("apple.automationfieldsview.choose_an_agent.b6890bc2"))] + backends.map { (value: $0.id, label: $0.label) }
        if !values.contains(where: { $0.value == fields.backend }) {
            values.append((fields.backend, L10n.text("apple.automationfieldsview.0_unavailable.1212b25c", "\(fields.backend)")))
        }
        return values
    }

    private func effortOptions(_ values: [String], preserving value: String) -> [(value: String, label: String)] {
        [(value: "", label: L10n.text("apple.automationfieldsview.default.21b111cb"))]
            + (values.contains(value) || value.isEmpty ? values : values + [value])
            .map { (value: $0, label: values.contains($0) ? $0 : L10n.text("apple.automationfieldsview.0_saved_choice.8193b80c", "\($0)")) }
    }
}

/// Frequency block shared by the Mac sheet and the mobile editor.
struct AutomationScheduleFields<Draft: JobScheduleEditing>: View {
    @Binding var fields: Draft
    var hostName: String = ""
    var timezone: String = ""
    var nextCaption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("apple.automationfieldsview.frequency.16b6668d"))
                .font(Theme.sectionHeader)
                .foregroundStyle(Theme.controlGlyph)
                .padding(.bottom, Theme.Space.xs)

            VStack(spacing: 0) {
                frequencyRow(L10n.text("apple.automationfieldsview.repeat.b6b7a006")) {
                    AppMenuPicker(
                        title: "",
                        options: ScheduleKind.allCases.map { (value: $0, label: $0.label) },
                        selection: $fields.scheduleKind
                    )
                    .frame(maxWidth: 180)
                }

                if fields.scheduleKind == .interval {
                    ThemeRule()
                    frequencyRow(L10n.text("apple.automationfieldsview.every.9b8617fd")) {
                        AppMenuPicker(
                            title: "",
                            options: intervalOptions,
                            selection: intervalSelection
                        )
                        .frame(maxWidth: 180)
                    }
                }

                if fields.scheduleKind == .weekly {
                    ThemeRule()
                    frequencyRow(L10n.text("apple.automationfieldsview.on.13001175")) {
                        AppMenuPicker(
                            title: "",
                            options: (0..<7).map { (value: $0, label: JobScheduleCopy.weekdayNames[$0]) },
                            selection: Binding(
                                get: { fields.weekday },
                                set: { value in
                                    fields.weekday = value
                                    fields.weeklyDayEdited = true
                                }
                            )
                        )
                        .frame(maxWidth: 180)
                    }
                    if !fields.weeklyDayEdited, fields.weeklyDays != 0 {
                        Text(fields.weeklyDayLabel)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.bottom, Theme.Space.s)
                    }
                }

                if fields.scheduleKind == .custom {
                    ThemeRule()
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(L10n.text("apple.automationfieldsview.on.13001175"))
                            .font(Theme.callout)
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { bit in
                                let on = (fields.customDays & (1 << bit)) != 0
                                Button {
                                    if on {
                                        fields.customDays &= ~(1 << bit)
                                    } else {
                                        fields.customDays |= (1 << bit)
                                    }
                                } label: {
                                    Text(JobScheduleCopy.weekdayShort[bit])
                                        .font(Theme.caption2.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 44)
                                        .background(
                                            on ? Theme.accent.opacity(0.2) : Theme.background,
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .foregroundStyle(on ? Theme.accent : Theme.controlGlyph)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.border)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(JobScheduleCopy.weekdayNames[bit])
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 10)
                }

                if fields.scheduleKind == .daily
                    || fields.scheduleKind == .weekdays
                    || fields.scheduleKind == .weekly
                    || fields.scheduleKind == .custom {
                    ThemeRule()
                    frequencyRow(L10n.text("apple.automationfieldsview.at.c72c5404")) {
                        DatePicker(L10n.text("apple.automationfieldsview.time.33b93476"), selection: time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Theme.accent)
                    }
                }

                if fields.scheduleKind == .once {
                    Text(L10n.text("apple.automationfieldsview.runs_only_when_you_press_run_now_nothing_i.d8d3b24d"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.s)
                        .padding(.horizontal, Theme.Space.s)
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))

            if usesHostClock {
                Text(HostScheduleClock.timeCaption(hostName: hostName, timezone: timezone))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.s)
                if let nextCaption {
                    Text(nextCaption)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var usesHostClock: Bool {
        fields.scheduleKind == .daily
            || fields.scheduleKind == .weekdays
            || fields.scheduleKind == .weekly
            || fields.scheduleKind == .custom
    }

    private var intervalOptions: [(value: String, label: String)] {
        var values = fields.intervalMenuMinutes.map {
            (value: String($0), label: JobScheduleCopy.intervalPresetLabel($0))
        }
        let seconds = fields.intervalCurrentSeconds
        if seconds % 60 != 0 {
            values.insert(
                (value: "s:\(seconds)", label: JobScheduleCopy.intervalLabel(seconds)),
                at: 0
            )
        }
        return values
    }

    private var intervalSelection: Binding<String> {
        Binding(
            get: {
                let seconds = fields.intervalCurrentSeconds
                if seconds % 60 != 0 { return "s:\(seconds)" }
                return String(seconds / 60)
            },
            set: { value in
                guard !value.hasPrefix("s:") else { return }
                fields.intervalMinutes = value
                fields.intervalTouched = true
            }
        )
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: fields.hour,
                    minute: fields.minute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                fields.hour = min(max(comps.hour ?? 9, 0), 23)
                fields.minute = min(max(comps.minute ?? 0, 0), 59)
            }
        )
    }

    private func frequencyRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(Theme.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Space.s)
            content()
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 10)
    }
}

struct AutomationBudgetFields<Draft: JobBudgetEditing>: View {
    @Binding var fields: Draft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.automationfieldsview.time_limit.e592a9ca"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            TimeLimitChips(minutesText: $fields.budgetMinutes, noLimit: $fields.noTimeLimit)
            if !fields.noTimeLimit, !isPreset {
                TextField(L10n.text("apple.automationfieldsview.minutes.4f846a84"), text: $fields.budgetMinutes)
                    .textFieldStyle(.themed)
                    .accessibilityLabel(L10n.text("apple.automationfieldsview.time_limit_in_minutes.e841e686"))
            }
            Text(fields.noTimeLimit ? L10n.text("apple.automationfieldsview.this_run_is_not_stopped_by_a_timer.dbacd6c6") : L10n.text("apple.automationfieldsview.the_connected_computer_stops_the_run_at_th.ddd7e504"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
    }

    private var isPreset: Bool {
        let presets = [15, 30, 60, 180, 480]
        return presets.contains(Int(fields.budgetMinutes) ?? -1)
    }
}
