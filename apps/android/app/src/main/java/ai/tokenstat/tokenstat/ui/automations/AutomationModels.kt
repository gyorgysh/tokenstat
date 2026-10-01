// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.tasks.RunHistory
import ai.tokenstat.tokenstat.ui.tasks.RunRef
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal fun JsonObject.optStr(key: String): String? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

internal fun JsonObject.optLong(key: String): Long? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.longOrNull

internal fun JsonObject.optInt(key: String): Int? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.intOrNull

/// Monday through Friday bits, matching the host.
const val WEEKDAYS_MASK = 0b0001_1111

enum class ScheduleKind(val label: String) {
    ONCE(L10n.text("android.automationmodels.once.d88f6d83")),
    INTERVAL(L10n.text("android.automationmodels.interval.6f45b000")),
    DAILY(L10n.text("android.automationmodels.daily.b36c2611")),
    WEEKDAYS(L10n.text("android.automationmodels.weekdays.6f4b602b")),
    WEEKLY(L10n.text("android.automationmodels.weekly.29751324")),
    CUSTOM(L10n.text("android.automationmodels.custom.494ca78f")),
    ;

    companion object {
        fun parse(raw: String?): ScheduleKind =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: ONCE
    }
}

/// When a job fires. Port of `AutomationSchedule`.
data class AutomationSchedule(
    val kind: ScheduleKind = ScheduleKind.ONCE,
    val everySeconds: Long = 0,
    val hour: Int = 9,
    val minute: Int = 0,
    val weekday: Int = 0,
    val weekdays: Int = 0,
) {
    companion object {
        val DEFAULT = AutomationSchedule(ScheduleKind.ONCE, 3600, 9, 0, 0)

        fun parse(obj: JsonObject?): AutomationSchedule {
            if (obj == null) return DEFAULT
            return AutomationSchedule(
                kind = ScheduleKind.parse(obj.optStr("kind")),
                everySeconds = obj.optLong("everySeconds") ?: 0,
                hour = obj.optInt("hour") ?: 0,
                minute = obj.optInt("minute") ?: 0,
                weekday = obj.optInt("weekday") ?: 0,
                weekdays = obj.optInt("weekdays") ?: 0,
            )
        }

        private val dayShort = listOf(L10n.text("android.automationmodels.mon.f40d7f51"), L10n.text("android.automationmodels.tue.d1eb39b0"), L10n.text("android.automationmodels.wed.58339f45"), L10n.text("android.automationmodels.thu.7da11212"), L10n.text("android.automationmodels.fri.66dab40c"), L10n.text("android.automationmodels.sat.fdeb71b5"), L10n.text("android.automationmodels.sun.db18f17f"))

        fun dayList(mask: Int): String =
            (0..6).filter { (mask and (1 shl it)) != 0 }.map { dayShort[it] }.joinToString(", ")
    }

    /// One phrasing for every client, so a job cannot say two things.
    val summary: String get() {
        val time = "$hour:${minute.toString().padStart(2, '0')}"
        return when (kind) {
            ScheduleKind.ONCE -> L10n.text("android.automationmodels.once_when_you_run_it.cbb9301d")
            ScheduleKind.INTERVAL -> {
                val minutes = (everySeconds / 60).toInt()
                if (minutes >= 60 && minutes % 60 == 0) {
                    val hours = minutes / 60
                    (if (hours == 1) L10n.text("android.automationmodels.every_0_hour_1.ed193624.one", hours) else L10n.text("android.automationmodels.every_0_hour_1.ed193624.other", hours))
                } else {
                    (if (minutes == 1) L10n.text("android.automationmodels.every_0_minute_1.fd623530.one", minutes) else L10n.text("android.automationmodels.every_0_minute_1.fd623530.other", minutes))
                }
            }
            ScheduleKind.DAILY -> L10n.text("android.automationmodels.daily_at_0.c0d8484c", "${time}")
            ScheduleKind.WEEKDAYS -> L10n.text("android.automationmodels.weekdays_at_0.6459d30a", "${time}")
            ScheduleKind.WEEKLY -> {
                if (weekdays and 0b0111_1111 != 0) L10n.text("android.automationmodels.0_at_1.f0a220c8", "${dayList(weekdays)}", "${time}")
                else {
                    val names = listOf(L10n.text("android.automationmodels.monday.6a00dfc1"), L10n.text("android.automationmodels.tuesday.7d8af1de"), L10n.text("android.automationmodels.wednesday.c0a6cc82"), L10n.text("android.automationmodels.thursday.fc266206"), L10n.text("android.automationmodels.friday.e21f3f37"), L10n.text("android.automationmodels.saturday.dbe35c73"), L10n.text("android.automationmodels.sunday.873fef76"))
                    L10n.text("android.automationmodels.0_at_1.f0a220c8", "${if (weekday in 0..6) names[weekday] else "?"}", "${time}")
                }
            }
            ScheduleKind.CUSTOM -> {
                val days = dayList(weekdays)
                if (days.isEmpty()) L10n.text("android.automationmodels.custom_at_0.55fdfc5a", "${time}") else L10n.text("android.automationmodels.0_at_1.f0a220c8", "${days}", "${time}")
            }
        }
    }

    /// A repeating schedule can be paused. Once is only ever a button.
    val repeats: Boolean get() = kind != ScheduleKind.ONCE

    fun toJson(): JsonObject = buildJsonObject {
        put("kind", kind.name.lowercase())
        put("everySeconds", everySeconds)
        put("hour", hour)
        put("minute", minute)
        put("weekday", weekday)
        put("weekdays", weekdays)
    }
}

/// Labels shared by automation and workflow schedule pickers.
/// Port of `JobScheduleCopy`.
object JobScheduleCopy {
    val weekdayNames = listOf(L10n.text("android.automationmodels.monday.6a00dfc1"), L10n.text("android.automationmodels.tuesday.7d8af1de"), L10n.text("android.automationmodels.wednesday.c0a6cc82"), L10n.text("android.automationmodels.thursday.fc266206"), L10n.text("android.automationmodels.friday.e21f3f37"), L10n.text("android.automationmodels.saturday.dbe35c73"), L10n.text("android.automationmodels.sunday.873fef76"))
    val weekdayShort = listOf(L10n.text("android.automationmodels.mo.d23e867e"), L10n.text("android.automationmodels.tu.62afcc74"), L10n.text("android.automationmodels.we.f3fe997b"), L10n.text("android.automationmodels.th.3bff939c"), L10n.text("android.automationmodels.fr.eed8f901"), L10n.text("android.automationmodels.sa.a951efc7"), L10n.text("android.automationmodels.su.2d88a3a2"))
    val intervalPresets = listOf(15, 30, 60, 120, 360, 720, 1440)

    fun intervalPresetLabel(minutes: Int): String {
        if (minutes >= 60 && minutes % 60 == 0) {
            val hours = minutes / 60
            return if (hours == 1) L10n.text("android.automationmodels.1_hour.f8b8883f") else L10n.text("android.automationmodels.0_hours.4d0aa096", "${hours}")
        }
        return if (minutes == 1) L10n.text("android.automationmodels.1_minute.e67b6f61") else L10n.text("android.automationmodels.0_minutes.87086105", "${minutes}")
    }

    fun intervalLabel(seconds: Long): String {
        if (seconds % 60 != 0L) return L10n.text("android.automationmodels.0_seconds.e549e94b", "${seconds}")
        return intervalPresetLabel((seconds / 60).toInt())
    }
}

/// Frequency fields both job editors write. Schedule values stay exact
/// until a picker is touched, so a 90-second interval does not round to a
/// minute. Port of `JobScheduleEditing`.
data class ScheduleFields(
    val scheduleKind: ScheduleKind = ScheduleKind.ONCE,
    val intervalMinutes: String = "60",
    val intervalSeconds: Long = 0,
    val intervalTouched: Boolean = false,
    val hour: Int = 9,
    val minute: Int = 0,
    val weekday: Int = 0,
    val weeklyDays: Int = 0,
    val weeklyDayEdited: Boolean = false,
    val customDays: Int = WEEKDAYS_MASK,
) {
    companion object {
        fun load(schedule: AutomationSchedule): ScheduleFields {
            val custom = when {
                schedule.weekdays != 0 -> schedule.weekdays
                schedule.kind == ScheduleKind.CUSTOM || schedule.kind == ScheduleKind.WEEKDAYS -> WEEKDAYS_MASK
                schedule.kind == ScheduleKind.WEEKLY && schedule.weekday in 0..6 -> 1 shl schedule.weekday
                else -> WEEKDAYS_MASK
            }
            return ScheduleFields(
                scheduleKind = schedule.kind,
                intervalMinutes = maxOf(1, (schedule.everySeconds / 60)).toString(),
                intervalSeconds = if (schedule.kind == ScheduleKind.INTERVAL) schedule.everySeconds else 0,
                intervalTouched = false,
                hour = schedule.hour.coerceIn(0, 23),
                minute = schedule.minute.coerceIn(0, 59),
                weekday = schedule.weekday,
                weeklyDays = if (schedule.kind == ScheduleKind.WEEKLY) schedule.weekdays and 0b0111_1111 else 0,
                weeklyDayEdited = false,
                customDays = custom,
            )
        }

        fun reset(): ScheduleFields = ScheduleFields()
    }

    val intervalCurrentSeconds: Long get() {
        if (!intervalTouched && intervalSeconds > 0) return maxOf(intervalSeconds, 60)
        val minutes = intervalMinutes.toLongOrNull()?.coerceAtMost(Long.MAX_VALUE / 60) ?: 60
        return maxOf(minutes * 60, 60)
    }

    val intervalMenuMinutes: List<Int> get() {
        val seconds = intervalCurrentSeconds
        if (seconds % 60 != 0L) return JobScheduleCopy.intervalPresets
        val current = maxOf(1, (seconds / 60).toInt())
        if (JobScheduleCopy.intervalPresets.contains(current)) return JobScheduleCopy.intervalPresets
        return (JobScheduleCopy.intervalPresets + current).sorted()
    }

    val builtSchedule: AutomationSchedule get() = when (scheduleKind) {
        ScheduleKind.ONCE -> AutomationSchedule(ScheduleKind.ONCE)
        ScheduleKind.INTERVAL -> AutomationSchedule(ScheduleKind.INTERVAL, intervalCurrentSeconds)
        ScheduleKind.DAILY -> AutomationSchedule(ScheduleKind.DAILY, hour = hour, minute = minute)
        ScheduleKind.WEEKDAYS -> AutomationSchedule(ScheduleKind.WEEKDAYS, hour = hour, minute = minute, weekdays = WEEKDAYS_MASK)
        ScheduleKind.WEEKLY -> AutomationSchedule(
            ScheduleKind.WEEKLY, hour = hour, minute = minute, weekday = weekday,
            weekdays = if (weeklyDayEdited) 0 else weeklyDays,
        )
        ScheduleKind.CUSTOM -> AutomationSchedule(ScheduleKind.CUSTOM, hour = hour, minute = minute, weekdays = customDays)
    }

    val weeklyDayLabel: String get() {
        if (!weeklyDayEdited && weeklyDays != 0) {
            return (0..6).filter { (weeklyDays and (1 shl it)) != 0 }
                .map { JobScheduleCopy.weekdayNames[it] }.joinToString(", ")
        }
        if (weekday !in 0..6) return L10n.text("android.automationmodels.day.8f2364e1")
        return JobScheduleCopy.weekdayNames[weekday]
    }

    fun weeklyDaySelected(day: Int): Boolean {
        if (weeklyDayEdited) return weekday == day
        if (weeklyDays != 0) return (weeklyDays and (1 shl day)) != 0
        return weekday == day
    }

    val validation: String? get() {
        if (scheduleKind == ScheduleKind.CUSTOM && (customDays and 0b0111_1111) == 0) {
            return L10n.text("android.automationmodels.pick_at_least_one_day_for_a_custom_schedul.0c926625")
        }
        if (scheduleKind == ScheduleKind.INTERVAL && intervalCurrentSeconds < 60) {
            return L10n.text("android.automationmodels.an_interval_must_be_at_least_a_minute.91844e44")
        }
        if (hour !in 0..23 || minute !in 0..59) {
            return L10n.text("android.automationmodels.choose_a_real_hour_and_minute.13e11fdc")
        }
        return null
    }
}

/// Minutes and no-limit, shared by automations and workflows.
/// Port of `JobBudgetEditing`.
data class BudgetFields(val budgetMinutes: String = "180", val noTimeLimit: Boolean = false) {
    companion object {
        fun load(seconds: Long): BudgetFields =
            if (seconds == 0L) BudgetFields("180", true)
            else BudgetFields(maxOf(1, seconds / 60).toString(), false)
    }

    val budgetSeconds: Long? get() {
        if (noTimeLimit) return 0
        val minutes = budgetMinutes.trim().toLongOrNull() ?: return null
        if (minutes <= 0) return null
        val product = minutes * 60
        if (product / 60 != minutes) return null
        return product
    }

    val validation: String? get() =
        if (budgetSeconds == null) L10n.text("android.automationmodels.enter_a_positive_time_limit_or_choose_no_l.3b7996e8") else null
}

/// Wall-clock copy for jobs that fire on a connected computer.
/// The host scheduler owns the zone: a phone in another zone must not
/// convert 09:00 there into the device clock. Port of `HostScheduleClock`.
object HostScheduleClock {
    /// IANA name the host sent, or null when it is missing or unnamed.
    fun resolved(identifier: String?): String? {
        val trimmed = identifier?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed == "unknown") return null
        return trimmed
    }

    /// Short place name. `America/New_York` becomes `New York`.
    fun place(identifier: String?): String? {
        val id = resolved(identifier) ?: return null
        if (id == "UTC" || id == "GMT") return "UTC"
        val slash = id.lastIndexOf('/')
        if (slash < 0) return id
        return id.substring(slash + 1).replace('_', ' ')
    }

    private val months = listOf(L10n.text("android.automationmodels.jan.5c5db120"), L10n.text("android.automationmodels.feb.caf71b3f"), L10n.text("android.automationmodels.mar.b4b7d381"), L10n.text("android.automationmodels.apr.617531b4"), L10n.text("android.automationmodels.may.8c78fe5b"), L10n.text("android.automationmodels.jun.b27fd46e"), L10n.text("android.automationmodels.jul.c43f56b9"), L10n.text("android.automationmodels.aug.41e1d82a"), L10n.text("android.automationmodels.sep.451e2b71"), L10n.text("android.automationmodels.oct.6877e849"), L10n.text("android.automationmodels.nov.3e630d29"), L10n.text("android.automationmodels.dec.f2a0cfbc"))

    private fun civil(epochMs: Long, timezone: String?): ZonedDateTime? {
        val id = resolved(timezone) ?: return null
        return try {
            ZonedDateTime.ofInstant(Instant.ofEpochMilli(epochMs), ZoneId.of(id))
        } catch (e: Exception) {
            null
        }
    }

    fun shortDay(epochMs: Long, timezone: String?): String? {
        val civil = civil(epochMs, timezone) ?: return null
        val month = months[civil.monthValue - 1]
        val nowYear = try {
            ZonedDateTime.now(ZoneId.of(resolved(timezone))).year
        } catch (e: Exception) {
            return null
        }
        return if (civil.year == nowYear) "${civil.dayOfMonth} $month"
        else "${civil.dayOfMonth} $month ${civil.year}"
    }

    /// Next-run timestamp in the host zone. Null when the zone is unknown,
    /// so the caller does not fall back to this device.
    fun wallClock(epochMs: Long, timezone: String?): String? {
        val civil = civil(epochMs, timezone) ?: return null
        val day = shortDay(epochMs, timezone) ?: return null
        return "$day, ${civil.hour}:${civil.minute.toString().padStart(2, '0')}"
    }

    fun nextRun(epochMs: Long, timezone: String?): String {
        val wall = wallClock(epochMs, timezone) ?: return L10n.text("android.automationmodels.on_the_connected_computer.982b489d")
        val place = place(timezone)
        return if (place != null) "$wall in $place" else wall
    }

    fun listSubtitle(cadence: String, nextMs: Long?, enabled: Boolean, repeats: Boolean, timezone: String? = null): String {
        if (!enabled || !repeats || nextMs == null) return cadence
        val day = shortDay(nextMs, timezone) ?: return cadence
        val place = place(timezone)
        return if (place != null) "$cadence · $day, $place" else "$cadence · $day"
    }

    fun timeCaption(hostName: String, timezone: String?): String =
        clockOwnership(hostName, timezone, L10n.text("android.automationmodels.this_time_is.e63a9d6e"))

    fun timesCaption(hostName: String, timezone: String?): String =
        clockOwnership(hostName, timezone, L10n.text("android.automationmodels.times_are.e9a3f2bc"))

    private fun clockOwnership(hostName: String, timezone: String?, subject: String): String {
        val host = hostName.trim()
        val place = place(timezone)
        if (place != null) {
            if (host.isEmpty()) return L10n.text("android.automationmodels.0_on_the_connected_computer_1.856ab0a3", "${subject}", "${place}")
            return "$subject on $host ($place)."
        }
        if (host.isEmpty()) return L10n.text("android.automationmodels.0_on_the_connected_computer_not_this_devic.444e2648", "${subject}")
        return L10n.text("android.automationmodels.0_on_1_not_this_device.4df70e6c", "${subject}", "${host}")
    }
}

/// Confirm copy for starting or stopping work on another machine.
///
/// One helper so workflows and automations cannot word the same threat
/// differently. Port of `ClientJobCopy`.
object JobCopy {
    fun run(name: String, folder: String, host: String): String =
        L10n.text("android.automationmodels.starts_0_in_1_on_2.c720825d", "${name}", "${folder}", "${host}")

    fun stop(name: String, folder: String, host: String): String =
        L10n.text("android.automationmodels.stops_the_run_of_0_in_1_on_2.4717028b", "${name}", "${folder}", "${host}")

    fun continueGate(name: String, folder: String, host: String): String =
        L10n.text("android.automationmodels.lets_0_continue_in_1_on_2.4962fc94", "${name}", "${folder}", "${host}")

    fun budget(seconds: Long): String {
        if (seconds == 0L) return L10n.text("android.automationmodels.no_time_limit.436b4b94")
        val minutes = seconds / 60
        if (minutes >= 60 && minutes % 60 == 0L) {
            val hours = minutes / 60
            return L10n.text("android.automationmodels.0_hour_1.0df4dd9a", "${hours}", "${if (hours == 1L) "" else "s"}")
        }
        return L10n.text("android.automationmodels.0_minute_1.ef3d336c", "${minutes}", "${if (minutes == 1L) "" else "s"}")
    }

    /// Fact-row value. The label is already "Last", so no prefix.
    /// Port of `ClientJobCopy.lastRunWhen`.
    fun lastRunWhen(epochMs: Long?, nowMs: Long = System.currentTimeMillis()): String {
        if (epochMs == null || epochMs <= 0) return L10n.text("android.automationmodels.never_run.3d40a69d")
        return ai.tokenstat.tokenstat.ui.logic.RelativeClock.abbreviated(epochMs, nowMs)
    }
}

/// Scheduler card and editor copy. Port of `AutomationQueueDraft.summary`,
/// `ClientSchedulerCard` scope, and the queue editor captions.
object QueueCopy {
    fun summary(budgetSeconds: Long, maxConcurrent: Long): String {
        val budget = if (budgetSeconds == 0L) {
            L10n.text("android.automationmodels.no_time_limit.436b4b94")
        } else {
            val minutes = maxOf(1, budgetSeconds / 60)
            when (minutes) {
                15L -> L10n.text("android.automationmodels.15m_per_job.518ce0c3")
                30L -> L10n.text("android.automationmodels.30m_per_job.540c908c")
                60L -> L10n.text("android.automationmodels.1h_per_job.d3a13f70")
                180L -> L10n.text("android.automationmodels.3h_per_job.cabf928e")
                480L -> L10n.text("android.automationmodels.8h_per_job.62ad336f")
                else -> L10n.text("android.automationmodels.0_min_per_job.60b07c42", "${minutes}")
            }
        }
        val slots = if (maxConcurrent == 0L) L10n.text("android.automationmodels.no_cap.59db2115") else L10n.text("android.automationmodels.0_at_once.4e557f9f", "${maxConcurrent}")
        return "$budget · $slots"
    }

    /// The list may be one folder. The copy must not be.
    fun scope(hostName: String, folderName: String, compact: Boolean = false): String {
        val host = hostName.trim()
        val folder = folderName.trim()
        if (compact) {
            if (host.isEmpty()) return L10n.text("android.automationmodels.every_folder.9836340c")
            return L10n.text("android.automationmodels.every_folder_on_0.158c4469", "${host}")
        }
        if (host.isEmpty() && folder.isEmpty()) return L10n.text("android.automationmodels.every_folder_on_the_connected_computer.14a3d916")
        if (folder.isEmpty()) return L10n.text("android.automationmodels.every_folder_on_0.158c4469", "${host}")
        if (host.isEmpty()) return L10n.text("android.automationmodels.every_folder_not_just_0.0c11b65f", "${folder}")
        return L10n.text("android.automationmodels.on_0_not_just_1.dd74bb64", "${host}", "${folder}")
    }

    fun editorScope(hostName: String, folderName: String): String {
        val host = hostName.trim()
        val folder = folderName.trim()
        if (host.isEmpty() && folder.isEmpty()) {
            return L10n.text("android.automationmodels.how_queued_jobs_run_on_the_connected_compu.0d28db88")
        }
        if (folder.isEmpty()) {
            return L10n.text("android.automationmodels.how_queued_jobs_run_on_0_this_applies_to_e.09927d15", "${host}")
        }
        if (host.isEmpty()) {
            return L10n.text("android.automationmodels.how_queued_jobs_run_on_the_connected_compu.993795e3", "${folder}")
        }
        return L10n.text("android.automationmodels.how_queued_jobs_run_on_0_not_just_1.a7cb9842", "${host}", "${folder}")
    }

    fun clockCaption(hostName: String, timezone: String?): String {
        val host = hostName.trim()
        val place = HostScheduleClock.place(timezone)
        if (place != null) {
            if (host.isEmpty()) return L10n.text("android.automationmodels.the_clock_on_the_connected_computer_is_0.12b427b3", "${place}")
            return L10n.text("android.automationmodels.the_clock_on_0_is_1.021f9b37", "${host}", "${place}")
        }
        if (host.isEmpty()) return L10n.text("android.automationmodels.the_clock_is_on_the_connected_computer_not.eb1dfcf7")
        return L10n.text("android.automationmodels.the_clock_is_on_0_not_this_device.730d6f0a", "${host}")
    }
}

/// "2 enabled · 1 running", the automations library summary.
fun automationListSummary(enabled: Int, running: Int): String = L10n.text("android.automationmodels.0_enabled_1_running.6a231a0e", "${enabled}", "${running}")

/// Library search covers the name and the prompt, like the Apple client.
fun jobMatchesQuery(job: AutomationJob, query: String): Boolean {
    val q = query.trim()
    if (q.isEmpty()) return true
    return job.name.contains(q, ignoreCase = true) || job.prompt.contains(q, ignoreCase = true)
}

/// The run the detail leads with: the live-first latest, else the job's
/// recorded last run. Port of `ClientAutomationSession.lastRun(for:)`.
fun lastAutomationRun(runs: List<AutomationRun>, job: AutomationJob): AutomationRun? {
    val jobRuns = runs.filter { it.jobId == job.id }
    val ordered = RunHistory.ordered(jobRuns.map { RunRef(it.id, it.startedAtMs, it.isRunning) })
    ordered.firstOrNull()?.let { ref -> return jobRuns.firstOrNull { it.id == ref.id } }
    return job.lastRunID?.let { id -> runs.firstOrNull { it.id == id } }
}

/// One agent automation. Port of `Automation` (revision defaults to 0 on
/// hosts before protocol 21).
data class AutomationJob(
    val id: String = "",
    val name: String = "",
    val backend: String = "",
    val model: String? = null,
    val effort: String? = null,
    val workspaceID: String = "",
    val prompt: String = "",
    val schedule: AutomationSchedule = AutomationSchedule.DEFAULT,
    val budgetSeconds: Long = 0,
    val enabled: Boolean = true,
    val lastRunAtMs: Long? = null,
    val nextRunAtMs: Long? = null,
    val lastRunID: String? = null,
    val revision: Long = 0,
) {
    companion object {
        fun parse(obj: JsonObject): AutomationJob = AutomationJob(
            id = obj.optStr("id") ?: "",
            name = obj.optStr("name") ?: "",
            backend = obj.optStr("backend") ?: "",
            model = obj.optStr("model"),
            effort = obj.optStr("effort"),
            workspaceID = obj.optStr("workspaceId") ?: "",
            prompt = obj.optStr("prompt") ?: "",
            schedule = AutomationSchedule.parse(obj["schedule"] as? JsonObject),
            budgetSeconds = obj.optLong("budgetSeconds") ?: 0,
            enabled = (obj["enabled"] as? kotlinx.serialization.json.JsonPrimitive)?.content == "true",
            lastRunAtMs = obj.optLong("lastRunAtMs"),
            nextRunAtMs = obj.optLong("nextRunAtMs"),
            lastRunID = obj.optStr("lastRunId"),
            revision = obj.optLong("revision") ?: 0,
        )
    }

    /// Wire object for `automation.create`, `automation.update` and
    /// `automation.edit` (the revision rides beside it on edit).
    fun toJson(): JsonObject = buildJsonObject {
        put("id", id)
        put("name", name)
        put("backend", backend)
        model?.let { put("model", it) }
        effort?.let { put("effort", it) }
        put("workspaceId", workspaceID)
        put("prompt", prompt)
        put("schedule", schedule.toJson())
        put("budgetSeconds", budgetSeconds)
        put("enabled", enabled)
        lastRunAtMs?.let { put("lastRunAtMs", it) }
        nextRunAtMs?.let { put("nextRunAtMs", it) }
        lastRunID?.let { put("lastRunId", it) }
        put("revision", revision)
    }
}

/// Shared automation fields. Port of `AutomationEditorDraft`.
data class AutomationEditorDraft(
    val name: String = "",
    val prompt: String = "",
    val workspaceID: String = "",
    val backend: String = "",
    val model: String = "",
    val effort: String = "",
    val schedule: ScheduleFields = ScheduleFields(),
    val budget: BudgetFields = BudgetFields(),
) {
    companion object {
        fun fromJob(job: AutomationJob): AutomationEditorDraft = AutomationEditorDraft(
            name = job.name,
            prompt = job.prompt,
            workspaceID = job.workspaceID,
            backend = job.backend,
            model = ai.tokenstat.tokenstat.ui.tasks.cleanModelID(job.model ?: ""),
            effort = job.effort ?: "",
            schedule = ScheduleFields.load(job.schedule),
            budget = BudgetFields.load(job.budgetSeconds),
        )

        fun blank(workspaceID: String, budgetSeconds: Long = 10_800, backend: String = ""): AutomationEditorDraft =
            AutomationEditorDraft(
                workspaceID = workspaceID,
                backend = backend,
                budget = BudgetFields.load(budgetSeconds),
            )
    }

    val validation: String? get() {
        if (name.trim().isEmpty()) return L10n.text("android.automationmodels.give_this_job_a_name.8453c6c7")
        if (name.toByteArray().size > 4096) return L10n.text("android.automationmodels.shorten_the_name_to_4_kib_or_less.5579d8cf")
        if (prompt.trim().isEmpty()) return L10n.text("android.automationmodels.write_what_the_agent_should_do.308a8211")
        if (prompt.toByteArray().size > 1024 * 1024) return L10n.text("android.automationmodels.shorten_the_prompt_to_1_mib_or_less.dba63070")
        if (workspaceID.trim().isEmpty()) return L10n.text("android.automationmodels.choose_a_folder_for_this_job.62a1a81c")
        if (backend.trim().isEmpty()) return L10n.text("android.automationmodels.choose_an_agent_for_this_job.d585332f")
        schedule.validation?.let { return it }
        budget.validation?.let { return it }
        return null
    }

    fun matches(job: AutomationJob): Boolean =
        name.trim() == job.name &&
            prompt.trim() == job.prompt.trim() &&
            workspaceID == job.workspaceID &&
            backend == job.backend &&
            ai.tokenstat.tokenstat.ui.tasks.cleanModelID(model) == ai.tokenstat.tokenstat.ui.tasks.cleanModelID(job.model ?: "") &&
            effort.trim() == (job.effort ?: "").trim() &&
            schedule.builtSchedule == job.schedule &&
            budget.budgetSeconds == job.budgetSeconds

    fun makeJob(id: String, enabled: Boolean, lastRunAtMs: Long? = null, lastRunID: String? = null, revision: Long = 0): AutomationJob {
        val budgetSeconds = budget.budgetSeconds
            ?: throw IllegalArgumentException(validation ?: L10n.text("android.automationmodels.check_this_job_s_settings.3b738ad9"))
        if (validation != null) throw IllegalArgumentException(validation)
        val cleaned = ai.tokenstat.tokenstat.ui.tasks.cleanModelID(model)
        return AutomationJob(
            id = id,
            name = name.trim(),
            backend = backend,
            model = cleaned.ifEmpty { null },
            effort = effort.ifEmpty { null },
            workspaceID = workspaceID,
            prompt = prompt.trim(),
            schedule = schedule.builtSchedule,
            budgetSeconds = budgetSeconds,
            enabled = enabled,
            lastRunAtMs = lastRunAtMs,
            lastRunID = lastRunID,
            revision = revision,
        )
    }
}

/// Shared run queue. Port of `AutomationQueue`.
data class AutomationQueue(
    val defaultBudgetSeconds: Long = 0,
    val maxConcurrent: Long = 2,
    val timezone: String? = null,
) {
    companion object {
        fun parse(obj: JsonObject?): AutomationQueue {
            if (obj == null) return AutomationQueue()
            return AutomationQueue(
                defaultBudgetSeconds = obj.optLong("defaultBudgetSeconds") ?: 0,
                maxConcurrent = obj.optLong("maxConcurrent") ?: 2,
                timezone = obj.optStr("timezone"),
            )
        }
    }
}

/// Queue editor validation. Port of `AutomationsModel.saveQueue`.
object QueueValidation {
    const val HOST_CAP = 32L

    fun budgetSeconds(noLimit: Boolean, minutesText: String): Long? {
        if (noLimit) return 0
        val minutes = minutesText.trim().toLongOrNull() ?: return null
        if (minutes <= 0) return null
        val product = minutes * 60
        if (product / 60 != minutes) return null
        return product
    }

    fun budgetError(noLimit: Boolean, minutesText: String): String? =
        if (budgetSeconds(noLimit, minutesText) == null) L10n.text("android.automationmodels.enter_a_positive_time_limit_or_choose_no_l.3b7996e8") else null

    fun maxConcurrent(countText: String): Long? =
        countText.trim().toLongOrNull()?.takeIf { it in 0..HOST_CAP }

    fun maxConcurrentError(countText: String): String? {
        val count = countText.trim().toLongOrNull()
        if (count == null || count < 0) return L10n.text("android.automationmodels.jobs_at_once_must_be_a_whole_number_or_no.a18bbfc5")
        if (count > HOST_CAP) return L10n.text("android.automationmodels.at_most_0_jobs_can_run_at_once.c6cd6b67", "${HOST_CAP}")
        return null
    }

    fun isBudgetPreset(noLimit: Boolean, minutesText: String): Boolean {
        if (noLimit) return false
        return minutesText.trim().toIntOrNull() in listOf(15, 30, 60, 180, 480)
    }

    fun isConcurrentPreset(countText: String): Boolean =
        countText.trim().toLongOrNull() in listOf(0L, 1L, 2L, 4L, 8L)
}

/// One completed or still-running agent run. Port of `RunRecord`.
data class AutomationRun(
    val id: String = "",
    val jobId: String = "",
    val name: String = "",
    val backend: String = "",
    val workspaceID: String = "",
    val startedAtMs: Long = 0,
    val endedAtMs: Long? = null,
    val status: String = "",
    val ptyID: String? = null,
) {
    val isRunning: Boolean get() = status in setOf("starting", "queued", "running", "stopping")

    val endedLabel: String get() = when (status) {
        "starting" -> L10n.text("android.automationmodels.starting.aeed4d26")
        "queued" -> L10n.text("common.queued")
        "running" -> L10n.text("common.running")
        "stopping" -> L10n.text("android.automationmodels.stopping.a71ee1d4")
        "ok" -> L10n.text("common.done")
        "stopped" -> L10n.text("android.automationmodels.stopped.1a4f630a")
        "error" -> L10n.text("common.failed")
        "interrupted" -> L10n.text("android.automationmodels.interrupted_by_restart.012812fe")
        else -> status
    }

    companion object {
        fun parse(obj: JsonObject): AutomationRun = AutomationRun(
            id = obj.optStr("id") ?: "",
            jobId = obj.optStr("jobId") ?: "",
            name = obj.optStr("name") ?: "",
            backend = obj.optStr("backend") ?: "",
            workspaceID = obj.optStr("workspaceId") ?: "",
            startedAtMs = obj.optLong("startedAtMs") ?: 0,
            endedAtMs = obj.optLong("endedAtMs"),
            status = obj.optStr("status") ?: "",
            ptyID = obj.optStr("ptyId"),
        )
    }
}

/// A confirmed creation, including when the job has since been deleted.
/// Port of `AutomationCreationOutcome`.
data class AutomationCreationOutcome(
    val operationID: String = "",
    val jobID: String = "",
    val createdAtMs: Long = 0,
    val job: AutomationJob? = null,
) {
    companion object {
        fun parse(obj: JsonObject): AutomationCreationOutcome = AutomationCreationOutcome(
            operationID = obj.optStr("operationId") ?: "",
            jobID = obj.optStr("jobId") ?: "",
            createdAtMs = obj.optLong("createdAtMs") ?: 0,
            job = (obj["job"] as? JsonObject)?.let(AutomationJob::parse),
        )
    }
}

/// A confirmed run request. `run` is absent when the process was never
/// recorded. Port of `AutomationRunOutcome`.
data class AutomationRunOutcome(
    val operationID: String = "",
    val jobID: String = "",
    val runID: String = "",
    val createdAtMs: Long = 0,
    val job: AutomationJob? = null,
    val run: AutomationRun? = null,
) {
    companion object {
        fun parse(obj: JsonObject): AutomationRunOutcome = AutomationRunOutcome(
            operationID = obj.optStr("operationId") ?: "",
            jobID = obj.optStr("jobId") ?: "",
            runID = obj.optStr("runId") ?: "",
            createdAtMs = obj.optLong("createdAtMs") ?: 0,
            job = (obj["job"] as? JsonObject)?.let(AutomationJob::parse),
            run = (obj["run"] as? JsonObject)?.let(AutomationRun::parse),
        )
    }
}
