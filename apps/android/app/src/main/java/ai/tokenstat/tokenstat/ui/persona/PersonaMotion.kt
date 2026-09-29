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
    private val seedPhase = (seed % 997UL).toDouble() * 0.01
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
    var blink = 0.0; private set
    var mood = PersonaMood.Idle; private set

    init { settle() }

    fun suspendClock() { lastTime = null; pending = 0.0 }

    fun settle() {
        for (i in 0 until count) {
            val radius = 0.355 * (1 + lumps.getOrElse(i) { 0f } * 0.10)
            x[i] = (0.5 + (basis[i][0] * radius - restOffsetX * 0.355)).coerceIn(0.02, 0.98)
            y[i] = (0.95 - restBottom * 0.355 + (basis[i][1] * radius - restOffsetY * 0.355)).coerceIn(0.02, 0.95)
            vx[i] = 0.0; vy[i] = 0.0
        }
        roll = 0.0; yaw = 0.0; rollVelocity = 0.0; yawVelocity = 0.0; blink = 0.0
        stretchX = 1.0; stretchY = 1.0; grounded = 0.0
        suspendClock()
    }

    fun advance(time: Double, requested: PersonaMood, moving: Boolean = true) {
        if (mood != requested) { previousMood = mood; mood = requested; moodAge = 0.0 }
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
        val blinkPhase = (lifetime + seedPhase) % 4.7
        val transitionBlink = if (moodAge < 0.24) sin(moodAge / 0.24 * PI) * 0.85 else 0.0
        blink = if (mood == PersonaMood.Sleeping) 0.96
            else max(transitionBlink, (1 - abs(blinkPhase - 0.10) / 0.10).coerceIn(0.0, 1.0))
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

    private companion object { const val STEP = 1.0 / 120 }
}
