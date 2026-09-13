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
            TextField("Job name", text: $fields.name, axis: .vertical)
                .font(Theme.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Job name")
            ThemeRule()
            Text(fields.backend == "sh" ? "Command" : "Prompt")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            TextEditor(text: $fields.prompt)
                .font(Theme.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: fills ? nil : minimumHeight)
                .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
                .accessibilityLabel(fields.backend == "sh" ? "Job command" : "Job prompt")
            Text(draftStatus)
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if section != .settings {
                Text("Job settings").font(Theme.callout.weight(.semibold))
            }
            if folderLocked {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    Text(folderName)
                        .font(Theme.callout)
                    Text("This job runs in this folder on the connected computer.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
            } else {
                AppMenuPicker(title: "Folder", options: folderOptions, selection: $fields.workspaceID)
            }
            AppMenuPicker(
                title: "Agent",
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
                        title: "Effort",
                        options: effortOptions(backend.efforts, preserving: fields.effort),
                        selection: $fields.effort
                    )
                }
                if !fields.model.isEmpty && !backend.models.contains(fields.model) {
                    Text("This computer does not list the saved model. Keep it or choose another.")
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
        var values = [(value: "", label: "Choose a folder")] + folders.map { (value: $0.id, label: $0.name) }
        if !values.contains(where: { $0.value == fields.workspaceID }) {
            values.append((fields.workspaceID, "Unavailable folder"))
        }
        return values
    }

    private var backendOptions: [(value: String, label: String)] {
        var values = [(value: "", label: "Choose an agent")] + backends.map { (value: $0.id, label: $0.label) }
        if !values.contains(where: { $0.value == fields.backend }) {
            values.append((fields.backend, "\(fields.backend) · Unavailable"))
        }
        return values
    }

    private func effortOptions(_ values: [String], preserving value: String) -> [(value: String, label: String)] {
        [(value: "", label: "Default")]
            + (values.contains(value) || value.isEmpty ? values : values + [value])
            .map { (value: $0, label: values.contains($0) ? $0 : "\($0) · Saved choice") }
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
            Text("Frequency")
                .font(Theme.sectionHeader)
                .foregroundStyle(Theme.controlGlyph)
                .padding(.bottom, Theme.Space.xs)

            VStack(spacing: 0) {
                frequencyRow("Repeat") {
                    AppMenuPicker(
                        title: "",
                        options: ScheduleKind.allCases.map { (value: $0, label: $0.label) },
                        selection: $fields.scheduleKind
                    )
                    .frame(maxWidth: 180)
                }

                if fields.scheduleKind == .interval {
                    ThemeRule()
                    frequencyRow("Every") {
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
                    frequencyRow("On") {
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
                        Text("On")
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
                    frequencyRow("At") {
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Theme.accent)
                    }
                }

                if fields.scheduleKind == .once {
                    Text("Runs only when you press Run now. Nothing is scheduled.")
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
            Text("Time limit")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            TimeLimitChips(minutesText: $fields.budgetMinutes, noLimit: $fields.noTimeLimit)
            if !fields.noTimeLimit, !isPreset {
                TextField("Minutes", text: $fields.budgetMinutes)
                    .textFieldStyle(.themed)
                    .accessibilityLabel("Time limit in minutes")
            }
            Text(fields.noTimeLimit ? "This run is not stopped by a timer." : "The connected computer stops the run at this budget.")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
    }

    private var isPreset: Bool {
        let presets = [15, 30, 60, 180, 480]
        return presets.contains(Int(fields.budgetMinutes) ?? -1)
    }
}
