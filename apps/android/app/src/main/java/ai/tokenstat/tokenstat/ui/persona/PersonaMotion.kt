// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round
import kotlin.math.sin
import kotlin.math.sqrt

/** Work state supplies forces; the spring body carries motion between states. */
enum class PersonaMood {
    Idle, Thinking, Running, Waiting, Complete, Failed, Sleeping, Bouncing, Dancing, Pacing,
    Speaking, Juggling, Reading, Gaming, Typing, Sipping, Sketching, Stargazing, Gardening, Bubbling, Snacking,
}

/** Fixed-step pressure body, with the same stage and fixed plush silhouettes as Apple/Windows.
 * All simulation buffers are reused. Compose observes only a draw invalidation tick.
 */
class PersonaMotion(seed: ULong, private val lumps: List<Float>, private val firmness: Double) {
    val count = lumps.size.coerceAtLeast(6)
    val x = DoubleArray(count)
    val y = DoubleArray(count)
    private val vx = DoubleArray(count)
    private val vy = DoubleArray(count)
    private val fx = DoubleArray(count)
    private val fy = DoubleArray(count)
    private val basis = Array(count) { i ->
        val a = i * 2 * PI / count
        doubleArrayOf(cos(a), sin(a))
    }
    private val restX = DoubleArray(count) { basis[it][0] * (1 + lumps.getOrElse(it) { 0f } * 0.10) }
    private val restY = DoubleArray(count) { basis[it][1] * (1 + lumps.getOrElse(it) { 0f } * 0.10) }
    private val restOffsetX = restX.average()
    private val restOffsetY = restY.average()
    private val restBottom = restY.max() - restOffsetY
    private val restEdges = DoubleArray(count) { i ->
        val next = (i + 1) % count
        val dx = restX[next] - restX[i]; val dy = restY[next] - restY[i]
        sqrt(dx * dx + dy * dy)
    }
    private val restArea = abs((0 until count).sumOf { i ->
        val next = (i + 1) % count
        restX[i] * restY[next] - restX[next] * restY[i]
    }) * 0.5
    private var lastTime: Double? = null
    private var pending = 0.0
    var lifetime = 0.0; private set
    var moodAge = 0.0; private set
    var previousMood = PersonaMood.Idle; private set
    private var grounded = 0.0
    private var rollVelocity = 0.0
    private var yawVelocity = 0.0
    private var stretchX = 1.0
    private var stretchY = 1.0
    private var anchor = 0.5
    var roll = 0.0; private set
    var yaw = 0.0; private set
    var mood = PersonaMood.Idle; private set

    // The face, eased toward what the mood asks for, so a change of mood
    // reads as an expression moving rather than a mask being swapped.
    // Openness: zero shut, one normal, above one wide. Cheer: the lower lid
    // pushed up into a smile, one a crescent. Droop: the outer ends of the
    // upper lid down. Focus: the inner ends down. Gaze in eye radii.
    var openness = 1.0; private set
    var cheer = 0.0; private set
    var droop = 0.0; private set
    var squint = 0.0; private set
    var focus = 0.0; private set
    var blush = 0.32; private set
    var gazeX = 0.0; private set
    var gazeY = 0.0; private set
    private var blinks = true

    // Where the eyes look on top of the mood's gaze. It jumps between
    // fixations rather than drifting: fast, then still.
    var lookX = 0.0; private set
    var lookY = 0.0; private set
    private var lookVX = 0.0
    private var lookVY = 0.0
    private var lookTargetX = 0.0
    private var lookTargetY = 0.0
    private var fixation = 0.8
    /** The head leaning into where it looks. Underdamped: curiosity. */
    var headTilt = 0.0; private set
    private var headTiltV = 0.0

    private var blinkAge = -1.0
    private var blinkLength = 0.30
    private var blinkAgain = false
    private var blinkCountdown = 2.0
    /** Minus one is the left eye, plus one the right, zero no wink. */
    var winkSide = 0; private set
    private var winkAge = -1.0
    private var winkCountdown = 7.0
    private var random = if (seed == 0UL) 0x9E3779B97F4A7C15UL else seed

    init { settle() }

    fun suspendClock() { lastTime = null; pending = 0.0 }

    fun settle() {
        for (i in 0 until count) {
            val radius = 0.355 * (1 + lumps.getOrElse(i) { 0f } * 0.10)
            x[i] = (0.5 + (basis[i][0] * radius - restOffsetX * 0.355)).coerceIn(0.02, 0.98)
            y[i] = (0.95 - restBottom * 0.355 + (basis[i][1] * radius - restOffsetY * 0.355)).coerceIn(0.02, 0.95)
            vx[i] = 0.0; vy[i] = 0.0
        }
        roll = 0.0; yaw = 0.0; rollVelocity = 0.0; yawVelocity = 0.0
        val face = target(mood)
        openness = face[0]; cheer = face[1]; droop = face[2]; squint = face[3]; focus = face[4]
        blush = face[5]; gazeX = face[6]; gazeY = face[7]
        blinkAge = -1.0; winkAge = -1.0; winkSide = 0
        lookX = 0.0; lookY = 0.0; lookVX = 0.0; lookVY = 0.0; lookTargetX = 0.0; lookTargetY = 0.0
        headTilt = 0.0; headTiltV = 0.0
        stretchX = 1.0; stretchY = 1.0; grounded = 0.0
        suspendClock()
    }

    fun advance(time: Double, requested: PersonaMood, moving: Boolean = true) {
        if (mood != requested) {
            previousMood = mood; mood = requested; moodAge = 0.0
            // A blink over a change: the eye forgives what happens behind one.
            startBlink(0.30)
        }
        if (!moving) { previousMood = mood; moodAge = 1.0; settle(); return }
        val last = lastTime
        lastTime = time
        if (last == null) return
        pending += (time - last).coerceIn(0.0, 1.0 / 12)
        while (pending >= STEP) {
            pending -= STEP
            step()
        }
    }

    private fun step() {
        val previous = lifetime
        lifetime += STEP
        moodAge += STEP
        val playful = mood == PersonaMood.Bouncing || mood == PersonaMood.Dancing || mood == PersonaMood.Pacing
        val quiet = mood == PersonaMood.Sleeping || mood == PersonaMood.Waiting || mood == PersonaMood.Failed
        if (mood == PersonaMood.Bouncing || mood == PersonaMood.Dancing) {
            rollVelocity += (1.25 - rollVelocity) * STEP * 4
        } else {
            val resting = round(roll / (2 * PI)) * 2 * PI
            rollVelocity += ((resting - roll) * 10 - rollVelocity * 6) * STEP
        }
        roll += rollVelocity * STEP
        val desiredYaw = if (mood == PersonaMood.Pacing) sin(lifetime * 0.65) * PI
            else if (quiet) 0.0 else sin(lifetime * 0.42) * 0.35
        yawVelocity += ((desiredYaw - yaw) * 12 - yawVelocity * 7) * STEP
        yaw += yawVelocity * STEP
        advanceFace()
        advanceGaze()
        advanceBlink()
        val breath = sin(lifetime * 2 * PI / 2.8)
        val pumping = when (mood) {
            PersonaMood.Dancing -> sin(lifetime * 2 * PI / 0.7) * 0.10
            PersonaMood.Speaking -> sin(lifetime * 12) * 0.035
            PersonaMood.Typing, PersonaMood.Gaming -> sin(lifetime * 16) * 0.025
            PersonaMood.Gardening, PersonaMood.Sketching -> sin(lifetime * 3.2) * 0.045
            else -> 0.0
        }
        stretchX += (1 + breath * 0.032 + pumping - stretchX) * STEP * 8
        stretchY += (1 - breath * 0.030 - pumping - stretchY) * STEP * 8
        stretchX = stretchX.coerceIn(0.88, 1.12)
        stretchY = stretchY.coerceIn(0.88, 1.12)
        val desiredAnchor = when (mood) {
            PersonaMood.Pacing -> 0.5 + sin(lifetime * 1.2) * 0.13
            PersonaMood.Juggling -> 0.5 + sin(lifetime * 3.8) * 0.045
            PersonaMood.Gardening, PersonaMood.Sketching -> 0.5 + sin(lifetime * 2) * 0.035
            else -> 0.5
        }
        anchor += (desiredAnchor - anchor) * STEP * 5
        if (mood == PersonaMood.Bouncing && floor(previous / 1.4) != floor(lifetime / 1.4)) {
            for (i in 0 until count) vy[i] -= 1.25
        }
        val gravity = if (mood == PersonaMood.Bouncing) 3.1 else 0.95
        val weight = gravity * (1 - grounded)
        var cx = 0.0; var cy = 0.0; var twiceArea = 0.0
        for (i in 0 until count) {
            fx[i] = 0.0; fy[i] = weight
            cx += x[i]; cy += y[i]
            val next = (i + 1) % count
            twiceArea += x[i] * y[next] - x[next] * y[i]
        }
        cx /= count; cy /= count
        val radius = if (playful) 0.355 * 0.90 else 0.355
        val targetArea = restArea * radius * radius * stretchX * stretchY
        val pressure = 44 * firmness * (targetArea / max(abs(twiceArea) * 0.5, 0.0002) - 1).coerceIn(-1.5, 3.0)
        for (i in 0 until count) {
            val next = (i + 1) % count
            val dx = x[next] - x[i]; val dy = y[next] - y[i]
            val length = max(sqrt(dx * dx + dy * dy), 0.00001)
            val nx = dx / length; val ny = dy / length
            val spring = 210 * (length - restEdges[i] * radius)
            fx[i] += spring * nx; fy[i] += spring * ny
            fx[next] -= spring * nx; fy[next] -= spring * ny
            val push = pressure * length * 0.5
            fx[i] += ny * push; fy[i] -= nx * push
            fx[next] += ny * push; fy[next] -= nx * push
        }
        val rs = sin(roll); val rc = cos(roll)
        val offsetX = (restOffsetX * rc - restOffsetY * rs) * radius
        val offsetY = (restOffsetY * rc + restOffsetX * rs) * radius
        var contacts = 0
        for (i in 0 until count) {
            val b = basis[i]
            val reach = radius * (1 + lumps.getOrElse(i) { 0f } * 0.10)
            val goalX = cx + ((b[0] * rc - b[1] * rs) * reach - offsetX) * stretchX
            val goalY = cy + ((b[1] * rc + b[0] * rs) * reach - offsetY) * stretchY
            fx[i] += (goalX - x[i]) * 150 * firmness + (anchor - cx) * 7
            fy[i] += (goalY - y[i]) * 150 * firmness
            if (mood == PersonaMood.Thinking || mood == PersonaMood.Running) {
                val wave = sin(lifetime * 3.9 + i * 4 * PI / count) * 0.18
                fx[i] += b[0] * wave; fy[i] += b[1] * wave
            }
            val damp = 1 - 3.4 * firmness * STEP
            vx[i] = (vx[i] + fx[i] * STEP) * damp
            vy[i] = (vy[i] + fy[i] * STEP) * damp
            x[i] += vx[i] * STEP; y[i] += vy[i] * STEP
            if (y[i] > 0.946) contacts++
            if (y[i] > 0.95) { y[i] = 0.95; if (vy[i] > 0) vy[i] *= -0.34; vx[i] *= 0.82 }
            if (y[i] < 0.02) { y[i] = 0.02; if (vy[i] < 0) vy[i] *= -0.25 }
            if (x[i] < 0.02) { x[i] = 0.02; if (vx[i] < 0) vx[i] *= -0.34 }
            if (x[i] > 0.98) { x[i] = 0.98; if (vx[i] > 0) vx[i] *= -0.34 }
        }
        grounded += (min(1.0, contacts / 3.0) - grounded) * STEP * 22
    }

    /**
     * What each mood does with the eyes, as lid positions: openness, cheer,
     * droop, squint, focus, blush, gaze x and gaze y. Numbers rather than eye
     * shapes, so every mood can ease into every other one.
     */
    private fun target(state: PersonaMood): DoubleArray {
        val sway = sin(lifetime * 2 * PI / 7.3) * 0.22
        return when (state) {
            PersonaMood.Idle -> doubleArrayOf(1.0, 0.0, 0.0, 0.0, 0.0, 0.32, sway, 0.0)
            PersonaMood.Thinking, PersonaMood.Running ->
                doubleArrayOf(0.86, 0.0, 0.0, 0.24, 0.30, 0.32, 0.42 + cos(lifetime * 1.3) * 0.2, -0.55)
            PersonaMood.Waiting -> doubleArrayOf(1.12, 0.0, 0.0, 0.0, 0.0, 0.32, sin(lifetime * 2) * 0.1, 0.04)
            PersonaMood.Complete -> doubleArrayOf(1.0, 1.0, 0.0, 0.0, 0.0, 0.55, 0.0, 0.0)
            PersonaMood.Failed -> doubleArrayOf(0.45, 0.0, 0.85, 0.0, 0.0, 0.32, 0.0, 0.5)
            PersonaMood.Sleeping -> doubleArrayOf(0.0, 0.0, 0.0, 0.0, 0.0, 0.40, 0.0, 0.0)
            PersonaMood.Bouncing -> doubleArrayOf(1.12, 0.0, 0.0, 0.0, 0.0, 0.40, 0.0, -0.1)
            PersonaMood.Dancing, PersonaMood.Snacking -> doubleArrayOf(1.0, 1.0, 0.0, 0.0, 0.0, 0.50, 0.0, 0.0)
            PersonaMood.Pacing -> doubleArrayOf(0.92, 0.0, 0.0, 0.18, 0.25, 0.32, sin(lifetime * 1.2) * 0.55, -0.1)
            PersonaMood.Speaking -> doubleArrayOf(1.05, 0.2, 0.0, 0.0, 0.0, 0.36, sin(lifetime * 1.7) * 0.25, -0.1)
            PersonaMood.Juggling -> doubleArrayOf(1.12, 0.0, 0.0, 0.0, 0.0, 0.32, sin(lifetime * 3.8) * 0.4, -0.6)
            PersonaMood.Reading, PersonaMood.Typing, PersonaMood.Gaming, PersonaMood.Sketching, PersonaMood.Gardening ->
                doubleArrayOf(0.84, 0.0, 0.0, 0.24, 0.25, 0.32, 0.2, 0.55)
            PersonaMood.Sipping -> doubleArrayOf(0.7, 0.5, 0.0, 0.0, 0.0, 0.45, 0.1, 0.4)
            PersonaMood.Stargazing -> doubleArrayOf(1.05, 0.0, 0.0, 0.0, 0.0, 0.32, cos(lifetime) * 0.4, -0.7)
            PersonaMood.Bubbling -> doubleArrayOf(0.8, 0.0, 0.0, 0.2, 0.0, 0.36, 0.0, 0.45)
        }
    }

    private fun advanceFace() {
        val face = target(mood)
        val k = min(1.0, STEP * 11)
        openness += (face[0] - openness) * k
        cheer += (face[1] - cheer) * k
        droop += (face[2] - droop) * k
        squint += (face[3] - squint) * k
        focus += (face[4] - focus) * k
        blush += (face[5] - blush) * k
        gazeX += (face[6] - gazeX) * k
        gazeY += (face[7] - gazeY) * k
        blinks = mood != PersonaMood.Sleeping
    }

    /** How far this mood's eyes wander between fixations, in eye radii. */
    private val wander: Double get() = when (mood) {
        PersonaMood.Sleeping, PersonaMood.Failed -> 0.0
        PersonaMood.Idle, PersonaMood.Waiting, PersonaMood.Stargazing, PersonaMood.Gardening -> 0.55
        PersonaMood.Thinking, PersonaMood.Running, PersonaMood.Pacing -> 0.45
        PersonaMood.Reading, PersonaMood.Typing, PersonaMood.Gaming, PersonaMood.Sketching -> 0.18
        else -> 0.32
    }

    private fun advanceGaze() {
        val reach = if (openness > 0.3) wander else 0.0
        fixation -= STEP
        if (fixation <= 0) {
            // Mostly small hops, now and then a proper look somewhere else.
            val far = nextUnit() < 0.3
            val angle = nextUnit() * 2 * PI
            val distance = reach * (if (far) 0.7 + nextUnit() * 0.3 else nextUnit() * 0.45)
            val nx = cos(angle) * distance
            val ny = sin(angle) * distance * 0.6
            val jump = sqrt((nx - lookTargetX) * (nx - lookTargetX) + (ny - lookTargetY) * (ny - lookTargetY))
            lookTargetX = nx; lookTargetY = ny
            fixation = 0.45 + nextUnit() * (if (far) 2.4 else 1.4)
            if (jump > 0.45 && blinkAge < 0 && blinks && nextUnit() < 0.35) startBlink(0.26)
        }
        if (reach == 0.0) { lookTargetX = 0.0; lookTargetY = 0.0 }
        // Critically damped: there and still in a tenth of a second.
        val omega = 34.0
        lookVX += ((lookTargetX - lookX) * omega * omega - 2 * omega * lookVX) * STEP
        lookVY += ((lookTargetY - lookY) * omega * omega - 2 * omega * lookVY) * STEP
        lookX += lookVX * STEP
        lookY += lookVY * STEP
        val tiltTarget = (-(lookX + gazeX * 0.5) * 0.10).coerceIn(-0.16, 0.16)
        val stiffness = 70.0
        headTiltV += ((tiltTarget - headTilt) * stiffness - headTiltV * 2 * 0.55 * sqrt(stiffness)) * STEP
        headTilt += headTiltV * STEP
    }

    private fun startBlink(length: Double) {
        blinkAge = 0.0
        blinkLength = length
        blinkAgain = nextUnit() < 0.2
    }

    private fun advanceBlink() {
        if (blinkAge >= 0) {
            blinkAge += STEP
            if (blinkAge >= blinkLength) {
                if (blinkAgain) { blinkAgain = false; blinkAge = 0.0; blinkLength = 0.26 }
                else { blinkAge = -1.0; blinkCountdown = 1.6 + nextUnit() * 4.4 }
            }
        } else if (blinks) {
            blinkCountdown -= STEP
            if (blinkCountdown <= 0) startBlink(0.30)
        }
        if (winkAge >= 0) {
            winkAge += STEP
            if (winkAge >= 0.62) { winkAge = -1.0; winkSide = 0 }
        } else if (blinks && blinkAge < 0 && mood in WINKERS) {
            winkCountdown -= STEP
            if (winkCountdown <= 0) {
                winkCountdown = 6 + nextUnit() * 9
                winkAge = 0.0
                winkSide = if (nextUnit() < 0.5) -1 else 1
            }
        }
    }

    /**
     * How shut the eyes are from blinking, zero to one. Fast down, a beat
     * shut, then open a touch past where it started and back. Negative is
     * wider than at rest.
     */
    val blink: Double get() {
        if (blinkAge < 0) return 0.0
        val close = 0.06
        val hold = close + 0.035
        val t = blinkAge
        if (t < close) return (t / close) * (t / close)
        if (t < hold) return 1.0
        val open = hold + max(0.05, (blinkLength - hold) * 0.45)
        if (t < open) {
            val x = (t - hold) / (open - hold)
            return 1 - 1.08 * x * x * (3 - 2 * x)
        }
        val y = min(1.0, (t - open) / max(0.01, blinkLength - open))
        return -0.08 * (1 - y * y * (3 - 2 * y))
    }

    /** How shut one eye is from a wink. */
    val wink: Double get() {
        if (winkAge < 0) return 0.0
        val t = winkAge
        if (t < 0.08) return t / 0.08
        if (t < 0.42) return 1.0
        val x = min(1.0, (t - 0.42) / 0.20)
        return 1 - x * x * (3 - 2 * x)
    }

    private fun nextUnit(): Double {
        random = random xor (random shl 13)
        random = random xor (random shr 7)
        random = random xor (random shl 17)
        return (random % 10_000UL).toDouble() / 10_000.0
    }

    private companion object {
        const val STEP = 1.0 / 120
        val WINKERS = setOf(PersonaMood.Idle, PersonaMood.Complete, PersonaMood.Dancing,
            PersonaMood.Juggling, PersonaMood.Bouncing, PersonaMood.Waiting)
    }
}
