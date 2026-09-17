// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.sample

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.sample.SampleStore.Change
import ai.tokenstat.tokenstat.ui.sample.SampleStore.ChangeKind
import ai.tokenstat.tokenstat.ui.sample.SampleStore.Turn
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// What the product is, before anybody rents anything. Port of
/// `ClientSampleWorkspace`.
///
/// Setting a machine up costs money and half an hour, and until now that had
/// to happen before somebody could see what they were getting. This is the ten
/// seconds in front of it: a task, the answer, the one line that changed, and
/// what the reading looks like.
///
/// It is a picture and says so, twice, in the places somebody would otherwise
/// mistake for their own data. Nothing here is running: there is no machine,
/// no agent and no account involved.
///
/// Read-only. Leaving lands back where setup was. No step is marked finished
/// by having looked at this, because none of them is.
@Composable
fun SampleSheet(onDismiss: () -> Unit) {
    val colors = LocalTsColors.current
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .clip(RoundedCornerShape(14.dp))
                .background(colors.background)
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Sample",
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TsSecondaryButton(label = "Done", small = true, onClick = onDismiss)
            }
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Text(
                        "AN EXAMPLE, NOT YOUR DATA",
                        style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.accent,
                    )
                    Text(
                        "A small task, start to finish",
                        style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        SampleStore.disclaimer,
                        style = TextStyle(fontSize = 17.sp),
                        color = colors.textSecondary,
                    )
                }
                TsCard(title = "The conversation") {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        SampleStore.conversation.forEach { turn -> TurnRow(turn) }
                    }
                }
                TsCard(title = "What changed in ${SampleStore.file}") {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            SampleStore.diff.forEach { line -> DiffRow(line) }
                        }
                        Text(
                            "One line. Nothing was committed and nothing was published: " +
                                "that stays something you do on purpose.",
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textSecondary,
                        )
                    }
                }
                TsCard(title = "What it counted") {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        SampleStore.readings.forEach { reading ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    reading.label,
                                    style = TextStyle(fontSize = 14.sp),
                                    color = colors.textSecondary,
                                )
                                Spacer(Modifier.weight(1f))
                                Text(
                                    reading.value,
                                    style = TsType.mono(13),
                                    color = colors.textPrimary,
                                )
                            }
                        }
                        Banner(SampleStore.disclaimer, BannerSeverity.INFO)
                    }
                }
            }
        }
    }
}

@Composable
private fun TurnRow(turn: Turn) {
    val colors = LocalTsColors.current
    val agent = turn.speaker == SampleStore.Speaker.AGENT
    val tint = if (agent) colors.accent else colors.textSecondary
    Row(
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            Modifier
                .size(22.dp)
                .clip(CircleShape)
                .background(tint.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (agent) Icons.Default.AutoAwesome else Icons.Default.Person,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(12.dp),
            )
        }
        Text(
            turn.text,
            style = TextStyle(fontSize = 14.sp),
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
    }
}

/// A diff line, marked by its sign as well as its colour.
///
/// Green and red alone are the oldest way to make a diff unreadable, and a
/// sample is exactly where somebody is looking at one for the first time.
@Composable
private fun DiffRow(line: Change) {
    val colors = LocalTsColors.current
    val tint = when (line.kind) {
        ChangeKind.CONTEXT -> colors.textSecondary
        ChangeKind.REMOVED -> colors.danger
        ChangeKind.ADDED -> colors.success
    }
    val sign = when (line.kind) {
        ChangeKind.CONTEXT -> " "
        ChangeKind.REMOVED -> "\u2212"
        ChangeKind.ADDED -> "+"
    }
    Row(
        Modifier
            .fillMaxWidth()
            .background(if (line.kind == ChangeKind.CONTEXT) colors.panel else tint.copy(alpha = 0.10f))
            .padding(horizontal = Space.xs, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(
            sign,
            style = TsType.mono(12, FontWeight.SemiBold),
            color = tint,
        )
        Text(
            line.text,
            style = TsType.mono(12),
            color = if (line.kind == ChangeKind.CONTEXT) colors.textSecondary else colors.textPrimary,
        )
    }
}
