// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

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
    ONCE("Once"),
    INTERVAL("Interval"),
    DAILY("Daily"),
    WEEKDAYS("Weekdays"),
    WEEKLY("Weekly"),
    CUSTOM("Custom"),
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

        private val dayShort = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

        fun dayList(mask: Int): String =
            (0..6).filter { (mask and (1 shl it)) != 0 }.map { dayShort[it] }.joinToString(", ")
    }

    /// One phrasing for every client, so a job cannot say two things.
    val summary: String get() {
        val time = "$hour:${minute.toString().padStart(2, '0')}"
        return when (kind) {
            ScheduleKind.ONCE -> "once, when you run it"
            ScheduleKind.INTERVAL -> {
                val minutes = (everySeconds / 60).toInt()
                if (minutes >= 60 && minutes % 60 == 0) {
                    val hours = minutes / 60
                    "every $hours hour${if (hours == 1) "" else "s"}"
                } else {
                    "every $minutes minute${if (minutes == 1) "" else "s"}"
                }
            }
            ScheduleKind.DAILY -> "daily at $time"
            ScheduleKind.WEEKDAYS -> "weekdays at $time"
            ScheduleKind.WEEKLY -> {
                if (weekdays and 0b0111_1111 != 0) "${dayList(weekdays)} at $time"
                else {
                    val names = listOf("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
                    "${if (weekday in 0..6) names[weekday] else "?"} at $time"
                }
            }
            ScheduleKind.CUSTOM -> {
                val days = dayList(weekdays)
                if (days.isEmpty()) "custom at $time" else "$days at $time"
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
    val weekdayNames = listOf("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
    val weekdayShort = listOf("Mo", "Tu", "We", "Th", "Fr", "Sa", "Su")
    val intervalPresets = listOf(15, 30, 60, 120, 360, 720, 1440)

    fun intervalPresetLabel(minutes: Int): String {
        if (minutes >= 60 && minutes % 60 == 0) {
            val hours = minutes / 60
            return if (hours == 1) "1 hour" else "$hours hours"
        }
        return if (minutes == 1) "1 minute" else "$minutes minutes"
    }

    fun intervalLabel(seconds: Long): String {
        if (seconds % 60 != 0L) return "$seconds seconds"
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
        if (weekday !in 0..6) return "Day"
        return JobScheduleCopy.weekdayNames[weekday]
    }

    fun weeklyDaySelected(day: Int): Boolean {
        if (weeklyDayEdited) return weekday == day
        if (weeklyDays != 0) return (weeklyDays and (1 shl day)) != 0
        return weekday == day
    }

    val validation: String? get() {
        if (scheduleKind == ScheduleKind.CUSTOM && (customDays and 0b0111_1111) == 0) {
            return "Pick at least one day for a custom schedule."
        }
        if (scheduleKind == ScheduleKind.INTERVAL && intervalCurrentSeconds < 60) {
            return "An interval must be at least a minute."
        }
        if (hour !in 0..23 || minute !in 0..59) {
            return "Choose a real hour and minute."
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
        if (budgetSeconds == null) "Enter a positive time limit, or choose No limit." else null
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

    private val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

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
        val wall = wallClock(epochMs, timezone) ?: return "on the connected computer"
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
        clockOwnership(hostName, timezone, "This time is")

    fun timesCaption(hostName: String, timezone: String?): String =
        clockOwnership(hostName, timezone, "Times are")

    private fun clockOwnership(hostName: String, timezone: String?, subject: String): String {
        val host = hostName.trim()
        val place = place(timezone)
        if (place != null) {
            if (host.isEmpty()) return "$subject on the connected computer ($place)."
            return "$subject on $host ($place)."
        }
        if (host.isEmpty()) return "$subject on the connected computer, not this device."
        return "$subject on $host, not this device."
    }
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
        if (name.trim().isEmpty()) return "Give this job a name."
        if (name.toByteArray().size > 4096) return "Shorten the name to 4 KiB or less."
        if (prompt.trim().isEmpty()) return "Write what the agent should do."
        if (prompt.toByteArray().size > 1024 * 1024) return "Shorten the prompt to 1 MiB or less."
        if (workspaceID.trim().isEmpty()) return "Choose a folder for this job."
        if (backend.trim().isEmpty()) return "Choose an agent for this job."
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
            ?: throw IllegalArgumentException(validation ?: "Check this job's settings.")
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
    fun budgetSeconds(noLimit: Boolean, minutesText: String): Long? {
        if (noLimit) return 0
        val minutes = minutesText.trim().toLongOrNull() ?: return null
        if (minutes <= 0) return null
        val product = minutes * 60
        if (product / 60 != minutes) return null
        return product
    }

    fun budgetError(noLimit: Boolean, minutesText: String): String? =
        if (budgetSeconds(noLimit, minutesText) == null) "Time limit must be a whole number of minutes." else null

    fun maxConcurrent(countText: String): Long? =
        countText.trim().toLongOrNull()?.takeIf { it >= 0 }

    fun maxConcurrentError(countText: String): String? =
        if (maxConcurrent(countText) == null) "Max concurrent jobs must be a whole number." else null
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
        "starting" -> "Starting"
        "queued" -> "Queued"
        "running" -> "Running"
        "stopping" -> "Stopping"
        "ok" -> "Done"
        "stopped" -> "Stopped"
        "error" -> "Failed"
        "interrupted" -> "Interrupted by restart"
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
