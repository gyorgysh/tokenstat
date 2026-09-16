// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.DeviceCopy
import ai.tokenstat.tokenstat.ui.logic.HomeGreeting
import ai.tokenstat.tokenstat.ui.logic.HomePreset
import ai.tokenstat.tokenstat.ui.logic.HomeSection
import ai.tokenstat.tokenstat.ui.logic.HostStatsFormat
import ai.tokenstat.tokenstat.ui.logic.LimitLogic
import ai.tokenstat.tokenstat.ui.logic.PinnedWork
import ai.tokenstat.tokenstat.ui.logic.RecentChatsRanking
import ai.tokenstat.tokenstat.ui.logic.RecentPlaces
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.normalizeHomeLayout
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.compactTokens
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.harnessCanonicalID
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.logic.moneyValue
import ai.tokenstat.tokenstat.ui.logic.shortDate
import ai.tokenstat.tokenstat.ui.logic.tagSignInUrl
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.search.SearchOpen
import ai.tokenstat.tokenstat.ui.search.SearchPlace
import ai.tokenstat.tokenstat.ui.search.SearchPlaces

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

    // compactTokens — port of formatTokens in Bridge/Models.swift: lowercase
    // k, whole thousands above ten thousand.
    @Test
    fun tokenCountsCompact() {
        assertEquals("0", compactTokens(0))
        // Non-positive counts render as zero, exactly like the Swift original.
        assertEquals("0", compactTokens(null))
        assertEquals("0", compactTokens(-5))
        assertEquals("999", compactTokens(999))
        assertEquals("1.0k", compactTokens(1_000))
        assertEquals("1.6k", compactTokens(1_600))
        assertEquals("126k", compactTokens(125_844))
        assertEquals("1.6M", compactTokens(1_600_000))
        assertEquals("2.0B", compactTokens(2_000_000_000))
    }

    @Test
    fun moneyFormatsMicros() {
        // Rates are published in US dollars: en_US USD whatever the device
        // locale, like Money in Bridge/Models.swift.
        assertEquals("$1.50", money(1_500_000L))
    }

    @Test
    fun moneyValueQualifiesFloorsAndEstimates() {
        assertEquals("$1.50", moneyValue(1_500_000L, estimated = false, complete = true))
        assertEquals("~$1.50", moneyValue(1_500_000L, estimated = true, complete = true))
        assertEquals("$1.50+", moneyValue(1_500_000L, estimated = false, complete = false))
        assertEquals("$1.50+", moneyValue(1_500_000L, estimated = true, complete = false))
    }

    @Test
    fun harnessNamesMatchAppleSpelling() {
        assertEquals("Claude Code", harnessName("claude_code"))
        assertEquals("Claude Code (recovered)", harnessName("claude_code_rollup"))
        assertEquals("OpenCode 2", harnessName("opencode2"))
        assertEquals("Grok Build", harnessName("grok"))
        assertEquals("Antigravity", harnessName("agy"))
        assertEquals("unknown", harnessName(""))
        assertEquals("someslug", harnessName("someslug"))
    }

    @Test
    fun harnessCanonicalNormalizesLegacyIds() {
        assertEquals("antigravity", harnessCanonicalID("agy"))
        assertEquals("antigravity", harnessCanonicalID("antigravity-2"))
        assertEquals("claude_code", harnessCanonicalID("claude"))
        assertEquals("opencode", harnessCanonicalID("opencode2"))
        assertEquals("codex", harnessCanonicalID("codex"))
    }

    @Test
    fun signInUrlCarriesAndroidClient() {
        assertEquals(
            "https://tokenstat.ai/link?code=AB12CD34&app=android&mobile=1",
            tagSignInUrl("https://tokenstat.ai/link?code=AB12CD34"),
        )
        assertEquals(
            "https://tokenstat.ai/link?app=android&mobile=1",
            tagSignInUrl("https://tokenstat.ai/link"),
        )
    }

    @Test
    fun shortDateOmitsCurrentYear() {
        val now = java.time.LocalDate.now()
        val thisYear = now.withMonth(8).withDayOfMonth(11)
            .let { if (it.isAfter(now)) it.minusYears(1) else it }
        val expectedDay = thisYear.format(java.time.format.DateTimeFormatter.ofPattern("d MMMM"))
        assertEquals(expectedDay, shortDate(thisYear.toString()))
        val otherYear = thisYear.minusYears(1)
        assertEquals(
            otherYear.format(java.time.format.DateTimeFormatter.ofPattern("d MMMM yyyy")),
            shortDate(otherYear.toString()),
        )
        assertEquals("not-a-date", shortDate("not-a-date"))
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

    // RecentChatsRanking.visible — three newest by time stay on top, five
    // more follow ranked by what needs a look, from ClientRecentChatsRanking.
    @Test
    fun rankingKeepsThreeNewestOnTop() {
        val now = 1_700_000_000_000L
        // A chat just left sits above older unread replies.
        val chats = listOf(
            RecentChatsRanking.Item("old-unread", now - 50_000, running = false, needsAttention = false, unread = true),
            RecentChatsRanking.Item("older-unread", now - 60_000, running = false, needsAttention = false, unread = true),
            RecentChatsRanking.Item("just-left", now - 1_000, running = false, needsAttention = false, unread = false),
        )
        val shown = RecentChatsRanking.visible(chats, now)
        assertEquals("just-left", shown.first().id)
    }

    @Test
    fun rankingOrdersTheTailByPriorityThenTime() {
        val now = 1_700_000_000_000L
        fun item(id: String, ageMs: Long, running: Boolean = false, needsAttention: Boolean = false, unread: Boolean = false) =
            RecentChatsRanking.Item(id, now - ageMs, running, needsAttention, unread)
        val head = listOf(item("n1", 1_000), item("n2", 2_000), item("n3", 3_000))
        val tail = listOf(
            item("plain", 4_000),
            item("running", 9_000, running = true),
            item("unread", 8_000, unread = true),
            item("approval", 10_000, needsAttention = true),
        )
        val shown = RecentChatsRanking.visible(head + tail, now).map { it.id }
        assertEquals(listOf("n1", "n2", "n3", "approval", "unread", "running", "plain"), shown)
        assertEquals(3, RecentChatsRanking.priority(RecentChatsRanking.Item("a", 0, running = false, needsAttention = true, unread = true)))
        assertEquals(2, RecentChatsRanking.priority(RecentChatsRanking.Item("a", 0, running = true, needsAttention = false, unread = true)))
        assertEquals(1, RecentChatsRanking.priority(RecentChatsRanking.Item("a", 0, running = true, needsAttention = false, unread = false)))
        assertEquals(0, RecentChatsRanking.priority(RecentChatsRanking.Item("a", 0, running = false, needsAttention = false, unread = false)))
    }

    @Test
    fun rankingDropsOldQuietChatsAndCapsAtEight() {
        val now = 1_700_000_000_000L
        val old = now - RecentChatsRanking.WINDOW_MS - 1_000
        val chats = (0 until 12).map {
            RecentChatsRanking.Item("chat$it", now - it * 1_000L, running = false, needsAttention = false, unread = false)
        } + RecentChatsRanking.Item("ancient", old, running = false, needsAttention = false, unread = false)
        val shown = RecentChatsRanking.visible(chats, now)
        assertEquals(8, shown.size)
        assertEquals(false, shown.any { it.id == "ancient" })
        // An old approval still counts: attention outlives the window.
        val kept = RecentChatsRanking.visible(
            listOf(RecentChatsRanking.Item("old-approval", old, running = false, needsAttention = true, unread = false)),
            now,
        )
        assertEquals(listOf("old-approval"), kept.map { it.id })
    }

    // RecentPlaces — newest first, capped at twenty, invalid rows dropped.
    @Test
    fun recentPlacesRecordAndTrim() {
        val scope = RecentPlaces.scopeKey("", "ada")
        assertEquals("client.recentPlaces.v1.0:3:ada", scope)
        var stored: List<RecentPlaces.Place> = emptyList()
        stored = RecentPlaces.record(stored, "peer1", "ws1", "My folder", RecentPlaces.Kind.WORKSPACE, null, 1000L)
        stored = RecentPlaces.record(stored, "peer1", "ws1", "My folder", RecentPlaces.Kind.WORKSPACE, null, 2000L)
        assertEquals(1, stored.size)
        assertEquals(2000L, stored.first().openedAtMs)
        assertEquals("My folder", RecentPlaces.title(stored.first()))
        val chat = RecentPlaces.record(emptyList(), "peer1", "ws1", "My folder", RecentPlaces.Kind.CHAT, "c1", 1000L)
        assertEquals("Chat in My folder", RecentPlaces.title(chat.first()))
        val term = RecentPlaces.record(emptyList(), "peer1", null, "My folder", RecentPlaces.Kind.TERMINAL, "t1", 1000L)
        assertEquals("Terminal", RecentPlaces.title(term.first()))
        val termIn = RecentPlaces.record(emptyList(), "peer1", "ws1", "My folder", RecentPlaces.Kind.TERMINAL, "t1", 1000L)
        assertEquals("Terminal in My folder", RecentPlaces.title(termIn.first()))
        // Path-shaped names never land in the store.
        val bad = RecentPlaces.record(emptyList(), "peer1", "ws1", "/tmp/evil", RecentPlaces.Kind.WORKSPACE, null, 1000L)
        assertEquals("Workspace", bad.first().workspaceName)
        // A chat without an item id is not a place.
        assertEquals(0, RecentPlaces.record(emptyList(), "peer1", "ws1", "X", RecentPlaces.Kind.CHAT, null, 1000L).size)
        // Twenty at most, newest first.
        var many: List<RecentPlaces.Place> = emptyList()
        for (i in 0 until 25) {
            many = RecentPlaces.record(many, "peer", "ws$i", "Folder $i", RecentPlaces.Kind.WORKSPACE, null, i.toLong())
        }
        assertEquals(20, many.size)
        assertEquals("ws24", many.first().id.workspaceId)
    }

    // PinnedWork — eight pins, newest first, full shelf refuses.
    @Test
    fun pinsKeepEightAndRefuseTheNinth() {
        val scope = "account|host|ada"
        var stored: List<PinnedWork.Pin> = emptyList()
        for (i in 0 until 8) {
            val (next, ok) = PinnedWork.pin(stored, scope, "peer", "ws$i", PinnedWork.Kind.WORKSPACE, null, "Folder $i", "Folder $i", i.toLong())
            stored = next
            assertEquals(true, ok)
        }
        val (_, refused) = PinnedWork.pin(stored, scope, "peer", "ws8", PinnedWork.Kind.WORKSPACE, null, "Folder 8", "Folder 8", 100L)
        assertEquals(false, refused)
        assertEquals(8, PinnedWork.pins(stored, scope).size)
        // Re-pinning moves to the top and refreshes the label.
        val (moved, ok) = PinnedWork.pin(stored, scope, "peer", "ws0", PinnedWork.Kind.WORKSPACE, null, "Renamed", "Folder 0", 100L)
        assertEquals(true, ok)
        assertEquals("ws0", moved.first().workspaceId)
        assertEquals("Renamed", moved.first().label)
        assertEquals(true, PinnedWork.isPinned(moved, scope, "peer", "ws0", PinnedWork.Kind.WORKSPACE, null))
        val dropped = PinnedWork.unpin(moved, scope, "peer", "ws0", PinnedWork.Kind.WORKSPACE, null)
        assertEquals(false, PinnedWork.isPinned(dropped, scope, "peer", "ws0", PinnedWork.Kind.WORKSPACE, null))
        // A conversation pin names the item, not the folder.
        val key = PinnedWork.pinKey(scope, "peer", "ws", PinnedWork.Kind.CONVERSATION, "chat1")
        assertEquals(true, key?.startsWith("conversation|") == true)
        assertEquals(null, PinnedWork.pinKey(scope, "peer", "ws", PinnedWork.Kind.WORKSPACE, "chat1"))
        assertEquals("Pinned work", PinnedWork.safeLabel("  "))
    }

    // HomeLayout — stored orders survive new sections; unknown names drop.
    @Test
    fun homeLayoutNormalizeKeepsChosenOrder() {
        val (order, hidden) = normalizeHomeLayout(null, emptySet())
        assertEquals(HomePreset.BALANCED.order, order)
        assertEquals(
            listOf(HomeSection.USAGE, HomeSection.CONTINUE, HomeSection.MACHINES, HomeSection.PINNED, HomeSection.ACTIVITY, HomeSection.LIMITS),
            HomePreset.BALANCED.order,
        )
        val stored = listOf(HomeSection.LIMITS, HomeSection.USAGE, HomeSection.LIMITS)
        val (kept, keptHidden) = normalizeHomeLayout(stored, setOf(HomeSection.USAGE, HomeSection.ACTIVITY))
        assertEquals(HomeSection.LIMITS, kept.first())
        assertEquals(HomeSection.USAGE, kept[1])
        assertEquals(6, kept.size)
        // The hidden set is intersected with the order, and appended
        // sections are in the order, so both survive.
        assertEquals(setOf(HomeSection.USAGE, HomeSection.ACTIVITY), keptHidden)
        assertEquals(HomeSection.CONTINUE, HomeSection.of("continue"))
        assertEquals(null, HomeSection.of("nope"))
    }

    // DeviceCopy — the list and the detail cannot describe a machine
    // differently.
    @Test
    fun deviceCopyNamesAndStatuses() {
        assertEquals("Studio", DeviceCopy.displayName("Studio", "macOS", true))
        assertEquals("Linux computer", DeviceCopy.displayName(null, "Linux · x86_64", true))
        assertEquals("iPhone device", DeviceCopy.displayName("", "iPhone", false))
        assertEquals("Unnamed device", DeviceCopy.displayName(null, null, true))
        assertEquals("Awake now", DeviceCopy.statusLine(false, true, true, true, null))
        assertEquals("Awake now", DeviceCopy.statusLine(true, false, false, false, null))
        assertEquals("Asleep · last seen yesterday", DeviceCopy.statusLine(false, false, true, true, "yesterday"))
        assertEquals("Asleep", DeviceCopy.statusLine(false, false, true, true, null))
        assertEquals("Not set up for remote", DeviceCopy.statusLine(false, false, true, false, null))
        assertEquals("Not set up for remote", DeviceCopy.statusLine(false, null, true, false, null))
        assertEquals("Last seen yesterday", DeviceCopy.statusLine(false, false, false, false, "yesterday"))
        assertEquals("Has not reported in yet", DeviceCopy.statusLine(false, null, false, false, null))
        assertEquals("m_c982…872c", DeviceCopy.shortId("m_c9821234872c"))
        assertEquals("short", DeviceCopy.shortId("short"))
        assertEquals("This is the device you are holding.", DeviceCopy.reach(true, false, false))
        assertEquals(true, DeviceCopy.reach(false, true, true).startsWith("Awake and reachable"))
        assertEquals(true, DeviceCopy.reach(false, false, true).contains("Always-on host"))
        assertEquals(true, DeviceCopy.reach(false, false, false).contains("Reach devices from anywhere"))
    }

    // LimitLogic — closest to full first, core thresholds for severity.
    @Test
    fun limitProvidersSortClosestToFullFirst() {
        val rows = listOf("a" to 12.0, "b" to 91.0, "c" to 70.0)
        val sorted = LimitLogic.closestToFullFirst(rows) { it.second }
        assertEquals(listOf("b", "c", "a"), sorted.map { it.first })
        assertEquals(LimitLogic.Severity.CRITICAL, LimitLogic.severityOf(null, 90.0))
        assertEquals(LimitLogic.Severity.WARNING, LimitLogic.severityOf(null, 70.0))
        assertEquals(LimitLogic.Severity.NORMAL, LimitLogic.severityOf(null, 69.9))
        assertEquals(LimitLogic.Severity.CRITICAL, LimitLogic.severityOf("Critical", 3.0))
        assertEquals(91.0, LimitLogic.peakPercent(listOf(12.0, 91.0)), 0.0)
    }

    // HostStatsFormat — missing readings stay missing, never zero.
    @Test
    fun statsReadingsMatchAppleWords() {
        assertEquals("…", HostStatsFormat.powerLabel(false, null, null, false, false))
        assertEquals("n/a", HostStatsFormat.powerLabel(false, null, null, true, false))
        assertEquals("42%", HostStatsFormat.powerLabel(true, 42, "battery", false, true))
        assertEquals("Plugged in", HostStatsFormat.powerLabel(false, null, "ac", false, true))
        assertEquals("On battery", HostStatsFormat.powerLabel(false, null, "battery", false, true))
        assertEquals("n/a", HostStatsFormat.powerLabel(false, null, null, false, true))
        assertEquals("24 / 32 GB", HostStatsFormat.ramLabel(24L * 1024 * 1024 * 1024, 32L * 1024 * 1024 * 1024))
        assertEquals("3.5 / 8.0 GB", HostStatsFormat.ramLabel((3.5 * 1024 * 1024 * 1024).toLong(), 8L * 1024 * 1024 * 1024))
        assertEquals("42%", HostStatsFormat.cpuLabel(0.42))
    }

    // SearchPlaces.rank — every word must start a word in the place; title
    // beats keywords beats the trail. Mirrors WorkSearchPlaceMatch.
    @Test
    fun searchRankMatchesApple() {
        val places = SearchPlaces.all(mapOf("peer-1" to "Build Mac"), mapOf("peer-1" to "macOS"))
        val notifications = SearchPlaces.rank("not", places)
        assertTrue(notifications.any { it.id == "account:thisDevice:notifications" })
        val traffic = SearchPlaces.rank("local traffic", places)
        assertEquals(listOf("account:thisDevice:traffic"), traffic.map { it.id })
        // A word from nowhere removes the place rather than ranking it last.
        assertEquals(emptyList<SearchPlace>(), SearchPlaces.rank("zxqv", places))
        assertEquals(emptyList<SearchPlace>(), SearchPlaces.rank("", places))
        // "plan" means the Plan card, not every setting that mentions a plan.
        val plan = SearchPlaces.rank("plan", places)
        assertEquals("account:account:plans", plan.first().id)
        // A machine name finds the device.
        val device = SearchPlaces.rank("build", places)
        assertTrue(device.any { it.id == "device:peer-1" })
    }

    @Test
    fun searchDestinationsParse() {
        val tab = SearchPlace("tab:insights", "Insights", "Tab", ActionIcon.Benchmarks)
        assertEquals(SearchOpen.Tab("insights"), SearchPlaces.destinationOf(tab) { null })
        val device = SearchPlace("device:peer-1", "Build Mac", "Devices", ActionIcon.Device)
        assertEquals(SearchOpen.Device("m-1"), SearchPlaces.destinationOf(device) { if (it == "peer-1") "m-1" else null })
        val account = SearchPlace("account:thisDevice", "Settings", "Behind your avatar", ActionIcon.Settings)
        assertEquals(SearchOpen.Account, SearchPlaces.destinationOf(account) { null })
        val unknown = SearchPlace("elsewhere", "Lost", "Nowhere", ActionIcon.Help)
        assertNull(SearchPlaces.destinationOf(unknown) { null })
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
