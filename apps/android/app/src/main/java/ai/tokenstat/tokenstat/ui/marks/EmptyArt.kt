// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.TsColors
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion

/// Every picture an empty screen draws, one per surface, ported from
/// `ClientEmptyArt.swift`. "Nothing here" is a different sentence in a folder
/// with no sessions and a folder with no jobs, so each surface gets its own
/// drawing rather than a shared shrug.
enum class EmptyArtKind {
    Sessions, Tasks, Notes, Workflows, Automations, Changes, History, NotGit,
    Files, Waiting, RemoteReach, Vault, Screen, WorkspaceAccess, Chat,
    NoMachine, Provisioning, ServerReady, Connect, MacDoor, CloudDoor,
    RentServer, ByHand, FirstBars, GetCounting, RemoteGate,
}

/// Line drawings from `ClientEmptyArt.swift`, 128x84, brand stroke. The Mac
/// draws each scene with one small loop; the phone draws the resting frame
/// and arrives on it with the shared intro spring (`TsMotion.introSpring`,
/// the response 0.5-0.7s damping 0.7-0.84 family), so Reduce Motion lands on
/// the frame by construction.
@Composable
fun EmptyArt(kind: EmptyArtKind, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    var entered by remember(kind) { mutableStateOf(reduceMotion) }
    val progress by animateFloatAsState(
        targetValue = if (entered) 1f else 0f,
        animationSpec = if (reduceMotion) snap() else TsMotion.introSpring(),
        label = "emptyArtIn",
    )
    LaunchedEffect(kind) { entered = true }
    val accent = colors.accent
    val border = colors.border
    Canvas(
        modifier
            .size(128.dp, 84.dp)
            .graphicsLayer {
                alpha = progress
                val scale = 0.92f + 0.08f * progress
                scaleX = scale
                scaleY = scale
            },
    ) {
        val stroke = Stroke(width = 3.4f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        val fine = Stroke(width = 2.4f, cap = StrokeCap.Round)
        val dashed = Stroke(width = 3.4f, cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f), 0f))
        when (kind) {
            EmptyArtKind.Sessions -> {
                drawRoundRect(border, Offset(size.width * 0.18f, size.height * 0.18f), Size(size.width * 0.64f, size.height * 0.64f), CornerRadius(10f, 10f), style = stroke)
                drawCircle(colors.danger.copy(alpha = 0.7f), 3.5f, Offset(size.width * 0.28f, size.height * 0.32f))
                drawCircle(colors.warning.copy(alpha = 0.7f), 3.5f, Offset(size.width * 0.36f, size.height * 0.32f))
                drawCircle(accent.copy(alpha = 0.7f), 3.5f, Offset(size.width * 0.44f, size.height * 0.32f))
                drawLine(accent, Offset(size.width * 0.28f, size.height * 0.55f), Offset(size.width * 0.34f, size.height * 0.55f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(size.width * 0.38f, size.height * 0.48f), Offset(size.width * 0.38f, size.height * 0.62f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            EmptyArtKind.Tasks -> {
                repeat(3) { i ->
                    val y = size.height * (0.22f + i * 0.22f)
                    drawRoundRect(if (i == 0) accent.copy(alpha = 0.45f) else border, Offset(size.width * 0.18f, y), Size(size.width * 0.64f, size.height * 0.16f), CornerRadius(6f, 6f), style = stroke)
                }
            }
            EmptyArtKind.Notes -> {
                drawRoundRect(border, Offset(size.width * 0.28f, size.height * 0.16f), Size(size.width * 0.44f, size.height * 0.68f), CornerRadius(6f, 6f), style = stroke)
                drawLine(accent, Offset(size.width * 0.36f, size.height * 0.38f), Offset(size.width * 0.62f, size.height * 0.38f), strokeWidth = 3f, cap = StrokeCap.Round)
                drawLine(accent.copy(alpha = 0.5f), Offset(size.width * 0.36f, size.height * 0.50f), Offset(size.width * 0.58f, size.height * 0.50f), strokeWidth = 3f, cap = StrokeCap.Round)
            }
            EmptyArtKind.Workflows -> {
                val nodes = listOf(0.22f, 0.42f, 0.62f, 0.82f)
                nodes.forEachIndexed { i, x ->
                    drawCircle(if (i == 0) accent else border, 7f, Offset(size.width * x, size.height * 0.5f), style = stroke)
                    if (i < nodes.lastIndex) {
                        drawLine(border, Offset(size.width * x + 8f, size.height * 0.5f), Offset(size.width * nodes[i + 1] - 8f, size.height * 0.5f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                    }
                }
            }
            EmptyArtKind.Automations -> {
                drawCircle(border, size.minDimension * 0.28f, Offset(size.width * 0.5f, size.height * 0.5f), style = stroke)
                drawLine(accent, Offset(size.width * 0.5f, size.height * 0.5f), Offset(size.width * 0.5f, size.height * 0.28f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            EmptyArtKind.Changes -> {
                drawLine(colors.diffAdded, Offset(size.width * 0.28f, size.height * 0.30f), Offset(size.width * 0.72f, size.height * 0.30f), strokeWidth = 3f)
                drawLine(colors.diffRemoved, Offset(size.width * 0.28f, size.height * 0.48f), Offset(size.width * 0.62f, size.height * 0.48f), strokeWidth = 3f)
                drawLine(accent, Offset(size.width * 0.28f, size.height * 0.66f), Offset(size.width * 0.55f, size.height * 0.66f), strokeWidth = 3f)
            }
            // A commit list with nothing in it yet: the rail is there, the
            // newest seat is still an outline.
            EmptyArtKind.History -> {
                val railX = size.width * 0.18f
                drawLine(border, Offset(railX, size.height * 0.19f), Offset(railX, size.height * 0.81f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                val rows = listOf(0.25f, 0.50f, 0.75f)
                rows.forEachIndexed { i, y ->
                    val cy = size.height * y
                    if (i == 0) {
                        drawCircle(colors.accentSoft, 7f, Offset(railX, cy))
                        drawCircle(accent, 7f, Offset(railX, cy), style = stroke)
                    } else {
                        drawCircle(border, 6f, Offset(railX, cy), style = stroke)
                    }
                    val lead = if (i == 0) accent else border
                    drawLine(lead, Offset(size.width * 0.30f, cy - 4f), Offset(size.width * (if (i == 0) 0.68f else 0.60f), cy - 4f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                    drawLine(border, Offset(size.width * 0.30f, cy + 5f), Offset(size.width * (if (i == 0) 0.48f else 0.44f), cy + 5f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                }
            }
            // A folder that has no history behind it: the branch never meets
            // the folder, so the picture is the missing connection.
            EmptyArtKind.NotGit -> {
                val folder = Path().apply {
                    moveTo(size.width * 0.10f, size.height * 0.79f)
                    lineTo(size.width * 0.10f, size.height * 0.48f)
                    lineTo(size.width * 0.21f, size.height * 0.48f)
                    lineTo(size.width * 0.25f, size.height * 0.55f)
                    lineTo(size.width * 0.53f, size.height * 0.55f)
                    lineTo(size.width * 0.53f, size.height * 0.79f)
                    close()
                }
                drawPath(folder, colors.accentSoft)
                drawPath(folder, accent, style = stroke)
                val branch = accent.copy(alpha = 0.85f)
                drawLine(branch, Offset(size.width * 0.62f, size.height * 0.60f), Offset(size.width * 0.70f, size.height * 0.60f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                drawLine(branch, Offset(size.width * 0.70f, size.height * 0.60f), Offset(size.width * 0.80f, size.height * 0.42f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                drawLine(branch, Offset(size.width * 0.70f, size.height * 0.60f), Offset(size.width * 0.80f, size.height * 0.78f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                drawCircle(colors.accentSoft, 5.5f, Offset(size.width * 0.60f, size.height * 0.60f))
                drawCircle(accent, 5.5f, Offset(size.width * 0.60f, size.height * 0.60f), style = stroke)
                drawCircle(border, 4.5f, Offset(size.width * 0.81f, size.height * 0.42f), style = stroke)
                drawCircle(border, 4.5f, Offset(size.width * 0.81f, size.height * 0.78f), style = stroke)
            }
            EmptyArtKind.Files -> {
                drawRoundRect(border, Offset(size.width * 0.22f, size.height * 0.34f), Size(size.width * 0.36f, size.height * 0.42f), CornerRadius(6f, 6f), style = stroke)
                drawRoundRect(accent.copy(alpha = 0.55f), Offset(size.width * 0.42f, size.height * 0.22f), Size(size.width * 0.34f, size.height * 0.48f), CornerRadius(6f, 6f), style = stroke)
            }
            EmptyArtKind.Waiting -> {
                drawRoundRect(border, Offset(size.width * 0.32f, size.height * 0.28f), Size(size.width * 0.36f, size.height * 0.44f), CornerRadius(8f, 8f), style = stroke)
                drawCircle(accent.copy(alpha = 0.35f), size.minDimension * 0.22f, Offset(size.width * 0.5f, size.height * 0.5f), style = stroke)
            }
            // A phone calling a Mac whose Remote Reach switch is still off:
            // the pulse ends at the switch, so this reads as setup, not as a
            // vague network failure.
            EmptyArtKind.RemoteReach -> {
                drawRoundRect(border, Offset(size.width * 0.13f, size.height * 0.23f), Size(size.width * 0.20f, size.height * 0.54f), CornerRadius(9f, 9f), style = stroke)
                drawLine(colors.secondary, Offset(size.width * 0.18f, size.height * 0.40f), Offset(size.width * 0.28f, size.height * 0.40f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawCircle(accent, 3.5f, Offset(size.width * 0.23f, size.height * 0.58f))
                repeat(3) { i ->
                    drawCircle(accent, 3.5f, Offset(size.width * (0.40f + i * 0.05f), size.height * 0.55f))
                }
                drawRoundRect(accent.copy(alpha = 0.7f), Offset(size.width * 0.58f, size.height * 0.28f), Size(size.width * 0.33f, size.height * 0.40f), CornerRadius(8f, 8f), style = stroke)
                drawLine(colors.secondary, Offset(size.width * 0.65f, size.height * 0.45f), Offset(size.width * 0.84f, size.height * 0.45f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawRoundRect(accent, Offset(size.width * 0.74f, size.height * 0.56f), Size(size.width * 0.13f, size.height * 0.10f), CornerRadius(6f, 6f))
            }
            EmptyArtKind.Vault -> {
                drawRoundRect(border, Offset(size.width * 0.16f, size.height * 0.22f), Size(size.width * 0.22f, size.height * 0.56f), CornerRadius(10f, 10f), style = stroke)
                drawRoundRect(border, Offset(size.width * 0.48f, size.height * 0.28f), Size(size.width * 0.36f, size.height * 0.44f), CornerRadius(8f, 8f), style = stroke)
                val lock = Path().apply {
                    moveTo(size.width * 0.44f, size.height * 0.52f)
                    lineTo(size.width * 0.56f, size.height * 0.52f)
                    lineTo(size.width * 0.56f, size.height * 0.66f)
                    lineTo(size.width * 0.44f, size.height * 0.66f)
                    close()
                }
                drawPath(lock, accent, style = stroke)
            }
            // A display with a scan line: the picture that is missing until
            // the plan includes the remote screen.
            EmptyArtKind.Screen -> {
                val frame = Offset(size.width * 0.16f, size.height * 0.15f)
                val frameSize = Size(size.width * 0.68f, size.height * 0.69f)
                drawRoundRect(colors.panel, frame, frameSize, CornerRadius(10f, 10f))
                drawRoundRect(accent, frame, frameSize, CornerRadius(10f, 10f), style = stroke)
                drawLine(colors.secondary, Offset(size.width * 0.30f, size.height * 0.36f), Offset(size.width * 0.70f, size.height * 0.36f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(border, Offset(size.width * 0.34f, size.height * 0.50f), Offset(size.width * 0.66f, size.height * 0.50f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(colors.secondary, Offset(size.width * 0.32f, size.height * 0.64f), Offset(size.width * 0.68f, size.height * 0.64f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent.copy(alpha = 0.45f), Offset(size.width * 0.20f, size.height * 0.30f), Offset(size.width * 0.80f, size.height * 0.30f), strokeWidth = 2.4f, cap = StrokeCap.Round)
            }
            // A folder waiting on a key: permission, not emptiness. The key
            // drifts in rather than turning, because nothing is locked
            // against this person, it simply has not been handed over yet.
            EmptyArtKind.WorkspaceAccess -> {
                drawRoundRect(border, Offset(size.width * 0.14f, size.height * 0.30f), Size(size.width * 0.50f, size.height * 0.55f), CornerRadius(12f, 12f), style = stroke)
                drawRoundRect(border, Offset(size.width * 0.18f, size.height * 0.20f), Size(size.width * 0.20f, size.height * 0.12f), CornerRadius(5f, 5f), style = stroke)
                val bow = Offset(size.width * 0.80f, size.height * 0.48f)
                drawCircle(accent, 6f, bow, style = stroke)
                val shaftEnd = Offset(size.width * 0.66f, size.height * 0.70f)
                drawLine(accent, bow, shaftEnd, strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(size.width * 0.70f, size.height * 0.63f), Offset(size.width * 0.74f, size.height * 0.59f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(size.width * 0.67f, size.height * 0.67f), Offset(size.width * 0.71f, size.height * 0.63f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            // A folder with no chats yet. The Mac draws the persona character
            // that will carry the next conversation; the phone has no persona
            // engine, so this is a plain face placeholder until it does.
            EmptyArtKind.Chat -> {
                val center = Offset(size.width * 0.5f, size.height * 0.50f)
                drawCircle(colors.accentSoft, size.height * 0.36f, center)
                drawCircle(accent.copy(alpha = 0.7f), size.height * 0.36f, center, style = stroke)
                drawCircle(accent, 3.5f, Offset(size.width * 0.44f, size.height * 0.44f))
                drawCircle(accent, 3.5f, Offset(size.width * 0.56f, size.height * 0.44f))
                drawArc(border, 20f, 140f, false, Offset(size.width * 0.42f, size.height * 0.44f), Size(size.width * 0.16f, size.height * 0.22f), style = fine)
            }
            EmptyArtKind.NoMachine -> serverScene(ServerArtState.Waiting, stroke, colors)
            EmptyArtKind.Provisioning -> serverScene(ServerArtState.Working, stroke, colors)
            EmptyArtKind.ServerReady -> serverScene(ServerArtState.Ready, stroke, colors)
            // This device reaching a machine: the handshake travels an arc
            // from the phone to the server, which lights up as it arrives.
            EmptyArtKind.Connect -> {
                drawRoundRect(border, Offset(size.width * 0.07f, size.height * 0.27f), Size(size.width * 0.17f, size.height * 0.46f), CornerRadius(8f, 8f), style = stroke)
                drawLine(colors.secondary, Offset(size.width * 0.11f, size.height * 0.48f), Offset(size.width * 0.20f, size.height * 0.48f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                val arcCenter = Offset(size.width * 0.30f, size.height * 0.50f)
                repeat(3) { i ->
                    val radius = 10f + i * 11f
                    drawArc(accent.copy(alpha = 0.9f - i * 0.25f), -38f, 76f, false, Offset(arcCenter.x, arcCenter.y - radius), Size(radius * 2f, radius * 2f), style = fine)
                }
                val rack = Offset(size.width * 0.62f, size.height * 0.30f)
                val rackSize = Size(size.width * 0.30f, size.height * 0.40f)
                drawRoundRect(border, rack, rackSize, CornerRadius(6f, 6f), style = stroke)
                drawCircle(accent, 3.5f, Offset(size.width * 0.67f, size.height * 0.40f))
                drawLine(colors.secondary, Offset(size.width * 0.73f, size.height * 0.48f), Offset(size.width * 0.86f, size.height * 0.48f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            // Door one: the computer, with the download coming down onto it.
            EmptyArtKind.MacDoor -> {
                sparkle(Offset(size.width * 0.23f, size.height * 0.24f), 11f, accent)
                sparkle(Offset(size.width * 0.77f, size.height * 0.72f), 7f, accent)
                drawLine(accent, Offset(size.width * 0.5f, size.height * 0.08f), Offset(size.width * 0.5f, size.height * 0.22f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(size.width * 0.5f, size.height * 0.22f), Offset(size.width * 0.44f, size.height * 0.15f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(size.width * 0.5f, size.height * 0.22f), Offset(size.width * 0.56f, size.height * 0.15f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawRoundRect(border, Offset(size.width * 0.28f, size.height * 0.30f), Size(size.width * 0.44f, size.height * 0.43f), CornerRadius(7f, 7f), style = stroke)
                drawLine(colors.secondary, Offset(size.width * 0.41f, size.height * 0.52f), Offset(size.width * 0.59f, size.height * 0.52f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(border, Offset(size.width * 0.22f, size.height * 0.76f), Offset(size.width * 0.78f, size.height * 0.76f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            // Door three: a cloud machine. Servers are read out of the
            // provider into the rack below, which is what importing means.
            EmptyArtKind.CloudDoor -> {
                sparkle(Offset(size.width * 0.20f, size.height * 0.24f), 9f, accent)
                sparkle(Offset(size.width * 0.77f, size.height * 0.76f), 7f, accent)
                val cloud = Offset(size.width * 0.26f, size.height * 0.12f)
                val cloudSize = Size(size.width * 0.48f, size.height * 0.26f)
                drawRoundRect(colors.background, cloud, cloudSize, CornerRadius(20f, 20f))
                drawRoundRect(border, cloud, cloudSize, CornerRadius(20f, 20f), style = stroke)
                val bump = Offset(size.width * 0.36f, size.height * 0.12f)
                drawCircle(colors.background, size.width * 0.09f, bump)
                drawCircle(border, size.width * 0.09f, bump, style = stroke)
                repeat(3) { i ->
                    drawCircle(accent, 3.5f, Offset(size.width * 0.5f, size.height * (0.48f + i * 0.08f)))
                }
                val unit = Offset(size.width * 0.28f, size.height * 0.72f)
                val unitSize = Size(size.width * 0.44f, size.height * 0.19f)
                drawRoundRect(accent.copy(alpha = 0.6f), unit, unitSize, CornerRadius(6f, 6f), style = stroke)
                drawCircle(accent, 3.5f, Offset(size.width * 0.33f, size.height * 0.815f))
                drawLine(colors.secondary, Offset(size.width * 0.40f, size.height * 0.815f), Offset(size.width * 0.64f, size.height * 0.815f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            // The renting guide: a price tag next to a rack. Renting is the
            // one setup screen about money, so it is the one that draws it.
            EmptyArtKind.RentServer -> {
                sparkle(Offset(size.width * 0.19f, size.height * 0.31f), 9f, accent)
                sparkle(Offset(size.width * 0.78f, size.height * 0.69f), 6f, accent)
                val tag = Offset(size.width * 0.12f, size.height * 0.36f)
                drawRoundRect(accent.copy(alpha = 0.7f), tag, Size(size.width * 0.27f, size.height * 0.29f), CornerRadius(7f, 7f), style = stroke)
                drawCircle(accent, 3.5f, Offset(size.width * 0.17f, size.height * 0.48f))
                drawLine(colors.secondary, Offset(size.width * 0.22f, size.height * 0.50f), Offset(size.width * 0.33f, size.height * 0.50f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                repeat(2) { i ->
                    drawRoundRect(border, Offset(size.width * 0.48f, size.height * (0.32f + i * 0.21f)), Size(size.width * 0.34f, size.height * 0.15f), CornerRadius(5f, 5f), style = stroke)
                }
            }
            // The install line, run by hand: a terminal holding a pasted
            // command with a caret, plus the paste badge.
            EmptyArtKind.ByHand -> {
                sparkle(Offset(size.width * 0.11f, size.height * 0.21f), 8f, accent)
                sparkle(Offset(size.width * 0.91f, size.height * 0.83f), 6f, accent)
                drawRoundRect(border, Offset(size.width * 0.17f, size.height * 0.17f), Size(size.width * 0.66f, size.height * 0.66f), CornerRadius(10f, 10f), style = stroke)
                drawLine(accent.copy(alpha = 0.7f), Offset(size.width * 0.28f, size.height * 0.36f), Offset(size.width * 0.59f, size.height * 0.36f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(border, Offset(size.width * 0.28f, size.height * 0.52f), Offset(size.width * 0.51f, size.height * 0.52f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(size.width * 0.55f, size.height * 0.45f), Offset(size.width * 0.55f, size.height * 0.60f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                val badge = Offset(size.width * 0.76f, size.height * 0.74f)
                drawCircle(colors.background, 10f, badge)
                drawCircle(accent, 10f, badge, style = stroke)
                drawLine(accent, Offset(badge.x, badge.y - 5f), Offset(badge.x, badge.y + 4f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(badge.x, badge.y + 4f), Offset(badge.x - 3.5f, badge.y), strokeWidth = 2.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(badge.x, badge.y + 4f), Offset(badge.x + 3.5f, badge.y), strokeWidth = 2.4f, cap = StrokeCap.Round)
            }
            // Insights with nothing on the account yet: bars rising, the last
            // one still a dashed slot. The first counters are arriving, not
            // absent.
            EmptyArtKind.FirstBars -> {
                sparkle(Offset(size.width * 0.22f, size.height * 0.24f), 9f, accent)
                sparkle(Offset(size.width * 0.78f, size.height * 0.74f), 6f, accent)
                val bottom = size.height * 0.74f
                val barTops = listOf(0.50f, 0.33f, 0.17f)
                val barX = listOf(0.28f, 0.44f, 0.60f)
                barTops.forEachIndexed { i, top ->
                    val rect = Offset(size.width * barX[i], size.height * top)
                    val rectSize = Size(size.width * 0.125f, bottom - size.height * top)
                    if (i < 2) {
                        drawRoundRect(accent.copy(alpha = 0.85f), rect, rectSize, CornerRadius(5f, 5f))
                    } else {
                        drawRoundRect(accent.copy(alpha = 0.6f), rect, rectSize, CornerRadius(5f, 5f), style = dashed)
                    }
                }
                drawLine(border, Offset(size.width * 0.24f, size.height * 0.78f), Offset(size.width * 0.76f, size.height * 0.78f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            // Getting started: this device ready with its check, the machine
            // still a quiet outline beside it.
            EmptyArtKind.GetCounting -> {
                sparkle(Offset(size.width * 0.19f, size.height * 0.26f), 9f, accent)
                sparkle(Offset(size.width * 0.81f, size.height * 0.71f), 6f, accent)
                drawRoundRect(accent.copy(alpha = 0.6f), Offset(size.width * 0.22f, size.height * 0.26f), Size(size.width * 0.19f, size.height * 0.48f), CornerRadius(8f, 8f), style = stroke)
                drawLine(colors.secondary, Offset(size.width * 0.26f, size.height * 0.45f), Offset(size.width * 0.37f, size.height * 0.45f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                val badge = Offset(size.width * 0.41f, size.height * 0.72f)
                drawCircle(accent, 8f, badge)
                drawLine(colors.background, Offset(badge.x - 4f, badge.y), Offset(badge.x - 1f, badge.y + 3f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                drawLine(colors.background, Offset(badge.x - 1f, badge.y + 3f), Offset(badge.x + 4.5f, badge.y - 3.5f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                repeat(2) { i ->
                    val unit = Offset(size.width * 0.52f, size.height * (0.30f + i * 0.25f))
                    drawRoundRect(border, unit, Size(size.width * 0.31f, size.height * 0.14f), CornerRadius(5f, 5f), style = stroke)
                    drawCircle(accent.copy(alpha = 0.5f), 3.5f, Offset(size.width * 0.56f, size.height * (0.37f + i * 0.25f)))
                }
            }
            // A paid gate: the phone reaches a folder and a lock sits on the
            // path.
            EmptyArtKind.RemoteGate -> {
                sparkle(Offset(size.width * 0.16f, size.height * 0.24f), 9f, accent)
                sparkle(Offset(size.width * 0.84f, size.height * 0.74f), 6f, accent)
                drawRoundRect(border, Offset(size.width * 0.10f, size.height * 0.30f), Size(size.width * 0.16f, size.height * 0.40f), CornerRadius(7f, 7f), style = stroke)
                drawLine(colors.secondary, Offset(size.width * 0.14f, size.height * 0.48f), Offset(size.width * 0.22f, size.height * 0.48f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                val badge = Offset(size.width * 0.36f, size.height * 0.50f)
                drawCircle(accent, 10f, badge)
                drawArc(colors.background, 180f, 180f, false, Offset(badge.x - 5f, badge.y - 8f), Size(10f, 10f), style = fine)
                drawCircle(colors.background, 2.5f, Offset(badge.x, badge.y + 1f))
                drawRoundRect(accent.copy(alpha = 0.7f), Offset(size.width * 0.50f, size.height * 0.32f), Size(size.width * 0.34f, size.height * 0.36f), CornerRadius(7f, 7f), style = stroke)
                drawRoundRect(accent.copy(alpha = 0.7f), Offset(size.width * 0.54f, size.height * 0.26f), Size(size.width * 0.16f, size.height * 0.12f), CornerRadius(6f, 6f), style = fine)
            }
        }
    }
}

/// Three moments of the same machine: a server with nothing on it, a server
/// being set up, and a server that answers. One drawing in three states, so
/// walking the wizard never meets three different machines.
private enum class ServerArtState { Waiting, Working, Ready }

private fun DrawScope.serverScene(state: ServerArtState, stroke: Stroke, colors: TsColors) {
    val accent = colors.accent
    val border = colors.border
    // The phone on the left.
    drawRoundRect(border, Offset(size.width * 0.07f, size.height * 0.27f), Size(size.width * 0.17f, size.height * 0.46f), CornerRadius(8f, 8f), style = stroke)
    drawLine(colors.secondary, Offset(size.width * 0.11f, size.height * 0.50f), Offset(size.width * 0.20f, size.height * 0.50f), strokeWidth = 3.4f, cap = StrokeCap.Round)
    // The link is the whole story: nothing, a travelling signal, or settled.
    val dot: (Int) -> Unit = { i ->
        val color = when (state) {
            ServerArtState.Waiting -> border.copy(alpha = 0.5f)
            ServerArtState.Working, ServerArtState.Ready -> accent
        }
        drawCircle(color, 3.5f, Offset(size.width * (0.30f + i * 0.05f), size.height * 0.50f))
    }
    repeat(3) { dot(it) }
    // The rack: three units, with a light on the top one that only comes on
    // when the machine actually answers.
    val light = when (state) {
        ServerArtState.Waiting -> border
        ServerArtState.Working -> accent.copy(alpha = 0.7f)
        ServerArtState.Ready -> accent
    }
    repeat(3) { unit ->
        val top = Offset(size.width * 0.42f, size.height * (0.24f + unit * 0.185f))
        val unitSize = Size(size.width * 0.34f, size.height * 0.15f)
        drawRoundRect(border, top, unitSize, CornerRadius(5f, 5f), style = stroke)
        drawCircle(if (unit == 0) light else border, 3.5f, Offset(size.width * 0.46f, top.y + unitSize.height / 2f))
        drawLine(colors.secondary, Offset(size.width * 0.60f, top.y + unitSize.height / 2f), Offset(size.width * 0.70f, top.y + unitSize.height / 2f), strokeWidth = 3.4f, cap = StrokeCap.Round)
    }
}

/// A four-point spark, the accent that makes a scene pop. Static by design:
/// each scene already carries its one loop on the Mac, and the phone draws
/// the resting frame.
private fun DrawScope.sparkle(center: Offset, size: Float, accent: Color) {
    val half = size / 2f
    val inner = size * 0.16f
    val path = Path().apply {
        moveTo(center.x, center.y - half)
        quadraticTo(center.x + inner, center.y - inner, center.x + half, center.y)
        quadraticTo(center.x + inner, center.y + inner, center.x, center.y + half)
        quadraticTo(center.x - inner, center.y + inner, center.x - half, center.y)
        quadraticTo(center.x - inner, center.y - inner, center.x, center.y - half)
        close()
    }
    drawPath(path, accent)
}
