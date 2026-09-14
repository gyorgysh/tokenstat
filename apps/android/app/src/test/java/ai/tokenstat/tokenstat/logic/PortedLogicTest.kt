// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.HomeGreeting
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.compactTokens
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.logic.normalizedRecovery
import ai.tokenstat.tokenstat.ui.logic.vaultPasswordProblems
import ai.tokenstat.tokenstat.ui.marks.RunOutcome
import ai.tokenstat.tokenstat.ui.marks.RunTick
import ai.tokenstat.tokenstat.ui.marks.durationFraction
import ai.tokenstat.tokenstat.ui.marks.durationLabel
import ai.tokenstat.tokenstat.ui.marks.runStripSummary
import ai.tokenstat.tokenstat.ui.marks.visibleRunTicks
import ai.tokenstat.tokenstat.ui.theme.LightColors
import org.junit.Assert.assertEquals
import org.junit.Test

/// Pins the ported pure logic to the same answers the Apple client's Swift
/// originals produce, so both platforms cannot drift apart silently.
class PortedLogicTest {

    // HomeGreeting.phrase — expected values computed from Greeting.swift's
    // pool and dayOfYear % pool.count rule.
    @Test
    fun greetingMorning() {
        assertEquals("Good morning", HomeGreeting.phrase(hour = 8, hasHistory = false, dayOfYear = 0))
    }

    @Test
    fun greetingAfternoonEveningAndNight() {
        // Day-of-year multiples of five land on the time-of-day slot itself.
        assertEquals("Good afternoon", HomeGreeting.phrase(13, false, 5))
        assertEquals("Good evening", HomeGreeting.phrase(18, false, 5))
        assertEquals("Hello", HomeGreeting.phrase(3, false, 5))
        assertEquals("Hello", HomeGreeting.phrase(23, false, 5))
    }

    @Test
    fun greetingPoolIsStablePerDay() {
        // dayOfYear 3 lands on index 3: Welcome back / Welcome slot.
        assertEquals("Welcome", HomeGreeting.phrase(8, hasHistory = false, dayOfYear = 3))
        assertEquals("Welcome back", HomeGreeting.phrase(8, hasHistory = true, dayOfYear = 3))
        // Index 4 is Back at it only with history; otherwise it repeats the
        // time-of-day phrase. Fixed length means the flip changes only this
        // returning slot.
        assertEquals("Good morning", HomeGreeting.phrase(8, hasHistory = false, dayOfYear = 4))
        assertEquals("Back at it", HomeGreeting.phrase(8, hasHistory = true, dayOfYear = 4))
    }

    @Test
    fun firstNameTakesFirstWord() {
        assertEquals("Gyorgy", HomeGreeting.firstName("Gyorgy"))
        assertEquals("Ada", HomeGreeting.firstName("Ada Lovelace"))
        assertEquals("", HomeGreeting.firstName("   "))
    }

    @Test
    fun greetingLineComposes() {
        assertEquals(
            "Good morning, Ada",
            HomeGreeting.line(name = "Ada Lovelace", hasHistory = true, hour = 8, dayOfYear = 0),
        )
    }

    // compactTokens — mirrors the Apple client's K/M/B compaction beside model
    // names.
    @Test
    fun tokenCountsCompact() {
        assertEquals("0", compactTokens(0))
        // Non-positive counts render as zero, exactly like the Swift original.
        assertEquals("0", compactTokens(null))
        assertEquals("0", compactTokens(-5))
        assertEquals("999", compactTokens(999))
        assertEquals("1.0K", compactTokens(1_000))
        assertEquals("1.6K", compactTokens(1_600))
        assertEquals("1.6M", compactTokens(1_600_000))
        assertEquals("2.0B", compactTokens(2_000_000_000))
    }

    @Test
    fun moneyFormatsMicros() {
        // Micros divide by one million before formatting; the currency symbol
        // and placement are the device locale's business.
        val formatted = money(1_500_000L)
        assert(formatted.contains("1.50") || formatted.contains("1,50")) { formatted }
    }

    // TunnelCopy — a mid-reconnect tunnel reads as waiting, not gone.
    @Test
    fun tunnelAbsentDetection() {
        assertEquals(true, TunnelCopy.isAbsent("no_such_peer for abc"))
        assertEquals(false, TunnelCopy.isAbsent("workspace not found"))
    }

    @Test
    fun tunnelWaitingCopyNamesTheHost() {
        assertEquals("Waiting for the computer to come back on the tunnel.", TunnelCopy.waiting(null))
        assertEquals("Waiting for Mac Studio to come back on the tunnel.", TunnelCopy.waiting(" Mac Studio "))
    }

    @Test
    fun unknownMethodIsNotRawProtocolText() {
        val error = friendlyError("unknown method: ssh.host.list")
        assertEquals("Helper is out of date", error.title)
        assertEquals(false, error.message.contains("ssh.host.list"))
    }

    @Test
    fun vaultPasswordRuleMatchesTheHost() {
        assertEquals(true, vaultPasswordProblems("Correct-Horse9").isEmpty())
        assertEquals(true, vaultPasswordProblems("short").contains("At least 12 characters"))
        assertEquals(true, vaultPasswordProblems("lowercase12!").contains("An uppercase letter"))
        // Eastern Arabic digits must not count as a number: the host uses ASCII.
        assertEquals(true, vaultPasswordProblems("Correct-Horse١٢").contains("A number"))
    }

    @Test
    fun recoveryCodeNormalisesTheWayTheHostDoes() {
        assertEquals("ABCD0101", normalizedRecovery("abcd-O1oI"))
    }

    // friendlyError — every row of FriendlyError.swift, in the same order, so
    // both clients answer identically.
    @Test
    fun sessionLimitsEndTheSession() {
        val limited = friendlyError("session_time_limit reached")
        assertEquals("Session ended", limited.title)
        assertEquals(true, limited.canRetry)
        assertEquals("Session ended while it was idle", friendlyError("session_idle timeout").title)
    }

    @Test
    fun screenAlreadyOpenAndQuotaAreNotRetryable() {
        val open = friendlyError("screen_already_open for xyz")
        assertEquals("A screen is already open", open.title)
        assertEquals(false, open.canRetry)
        assertEquals("Relay allowance used up", friendlyError("quota_exceeded").title)
        assertEquals(false, friendlyError("quota_exceeded").canRetry)
    }

    @Test
    fun keychainRefusalsNameTheBuild() {
        assertEquals("This build cannot use the keychain", friendlyError("OSStatus -34018").title)
        assertEquals(
            "The private key is not on this device",
            friendlyError("keychain error -25300").title,
        )
    }

    @Test
    fun vaultFailuresDistinguishUnboundLoginFromUnknownMachine() {
        val unbound = friendlyError("register this device before using the vault")
        assertEquals("This login is not tied to this computer", unbound.title)
        assertEquals(true, unbound.canRetry)
        assertEquals(
            "This computer is not on your account",
            friendlyError("machine_required for vault").title,
        )
        assertEquals("There is already a vault", friendlyError("vault already exists").title)
        val unenrolled = friendlyError("device did not enroll yet")
        assertEquals("This device cannot read the vault", unenrolled.title)
        assertEquals(true, unenrolled.canRetry)
    }

    @Test
    fun approvalAndPlanRows() {
        val approval = friendlyError("not approved yet")
        assertEquals("Waiting for approval", approval.title)
        assertEquals(true, approval.canRetry)
        val plan = friendlyError("feature needs paid-plan")
        assertEquals("Not on this plan", plan.title)
        assertEquals(false, plan.canRetry)
    }

    @Test
    fun refusedCredentialReconnectsEvenWhenItMentionsSignIn() {
        // The refused-credential sentence used to contain "sign in again",
        // which sent people to fix something already being fixed.
        val error = friendlyError("tunnel credential refused, sign in again")
        assertEquals("Reconnecting", error.title)
        assertEquals(true, error.canRetry)
        assertEquals("Sign in again", friendlyError("signed out").title)
        val elsewhere = friendlyError("already on the tunnel")
        assertEquals("Connected somewhere else", elsewhere.title)
        assertEquals(false, elsewhere.canRetry)
    }

    @Test
    fun networkTimeoutSleepAndHelperRows() {
        assertEquals("No connection", friendlyError("offline: network is unreachable").title)
        assertEquals("It did not answer", friendlyError("request timed out").title)
        assertEquals("This Mac is asleep", friendlyError("host_asleep").title)
        val refused = friendlyError("connection refused (os error 61)")
        assertEquals("The helper is not running", refused.title)
        assertEquals(true, refused.canRetry)
        assertEquals("Connection dropped", friendlyError("broken pipe").title)
    }

    @Test
    fun rateGatewayAndDeviceRows() {
        val rate = friendlyError("too many requests")
        assertEquals("Asked too often", rate.title)
        assertEquals(false, rate.canRetry)
        assertEquals(
            "The server is unreachable",
            friendlyError("tunnel error code: 1033").title,
        )
        assertEquals(
            "The server could not answer",
            friendlyError("status request failed (503)").title,
        )
        // A bare number is a port or a count, not a failure code.
        assertEquals("That did not work", friendlyError("listening on 503").title)
        val devices = friendlyError("device limit reached")
        assertEquals("Device limit reached", devices.title)
        assertEquals(false, devices.canRetry)
    }

    @Test
    fun unknownPeerIsUnreachableAndUnknownTextFallsThrough() {
        val peer = friendlyError("tunnel: no_such_peer for abc")
        assertEquals("That computer is not reachable", peer.title)
        assertEquals(true, peer.canRetry)
        val other = friendlyError("some new backend sentence")
        assertEquals("That did not work", other.title)
        assertEquals("some new backend sentence", other.message)
        assertEquals(
            "Something went wrong and nothing said what.",
            friendlyError("   ").message,
        )
    }

    // RelativeClock.label — the shared phrasing behind RelativeTimeText.
    @Test
    fun relativeClockLabels() {
        val now = 1_700_000_000_000L
        assertEquals("now", RelativeClock.label(now - 3_000, now))
        assertEquals("30s ago", RelativeClock.label(now - 30_000, now))
        assertEquals("3m ago", RelativeClock.label(now - 3 * 60_000, now))
        assertEquals("2h ago", RelativeClock.label(now - 2 * 3_600_000, now))
        assertEquals("3d ago", RelativeClock.label(now - 3 * 86_400_000, now))
    }

    // RunOutcome.tint — every status in RunVisuals.swift maps to the same
    // TsColors slot on both platforms.
    @Test
    fun runOutcomeTints() {
        assertEquals(LightColors.stateWorking, RunOutcome.tint("running", LightColors))
        assertEquals(LightColors.stateWorking, RunOutcome.tint("queued", LightColors))
        assertEquals(LightColors.warning, RunOutcome.tint("waiting", LightColors))
        assertEquals(LightColors.success, RunOutcome.tint("ok", LightColors))
        assertEquals(LightColors.warning, RunOutcome.tint("stopped", LightColors))
        assertEquals(LightColors.danger, RunOutcome.tint("error", LightColors))
        assertEquals(LightColors.warning, RunOutcome.tint("interrupted", LightColors))
        assertEquals(LightColors.stateIdle, RunOutcome.tint("bogus", LightColors))
    }

    // DurationBar math — relative to the longest run beside it, with a floor
    // so a short run still draws.
    @Test
    fun durationFractionAndLabel() {
        assertEquals(0.0, durationFraction(0.0, 100.0), 0.0)
        assertEquals(0.0, durationFraction(50.0, 0.0), 0.0)
        assertEquals(0.5, durationFraction(50.0, 100.0), 1e-9)
        assertEquals(0.06, durationFraction(1.0, 100.0), 1e-9)
        assertEquals(1.0, durationFraction(200.0, 100.0), 1e-9)
        assertEquals("Still running", durationLabel(0.0))
        assertEquals("Took 45s", durationLabel(45.0))
        assertEquals("Took 2m", durationLabel(150.0))
        assertEquals("Took 1.5h", durationLabel(5400.0))
    }

    // RunHistoryStrip trimming and summary.
    @Test
    fun runStripTrimsTheFrontAndSummarises() {
        val ticks = (1..10).map { RunTick("r$it", "ok", "run $it") }
        assertEquals(8, visibleRunTicks(ticks).size)
        assertEquals("r3", visibleRunTicks(ticks).first().id)
        assertEquals(0, visibleRunTicks(ticks, -1).size)
        assertEquals("Never run", runStripSummary(emptyList()))
        assertEquals("Last 2 runs, none failed", runStripSummary(ticks.take(2)))
        val mixed = listOf(RunTick("a", "ok", "a"), RunTick("b", "error", "b"))
        assertEquals("Last 2 runs, 1 failed", runStripSummary(mixed))
    }
}
