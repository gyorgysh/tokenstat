// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.account

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.BrandCheckDisc
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsBottomSheet
import ai.tokenstat.tokenstat.ui.components.TsBrandSwitch
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.marks.Avatar
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import android.content.ClipData
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.hypot
import kotlin.math.pow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

enum class ProfilePurpose { SETTINGS, OFFER }

private sealed interface Standing {
    data object Empty : Standing
    data object Checking : Standing
    data object Available : Standing
    data class Refused(val message: String) : Standing

    /// The question could not be asked. The claim is still offered: it is the
    /// claim that decides, and it will say so if the network is gone.
    data class Unknown(val message: String) : Standing
}

private val profileShape = RoundedCornerShape(16.dp)

/// The profile window, behind the name in Account: the address, who can open
/// it, and the way to see it. An account with no handle starts on choosing
/// one, and the one-time offer is this same window. Port of `ProfileSheet`.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileSheet(
    purpose: ProfilePurpose,
    account: JsonObject?,
    model: AppViewModel,
    onOpen: (String) -> Unit,
    onClose: () -> Unit,
) {
    val profile = AccountProfile.from(account)
    if (profile == null) {
        LaunchedEffect(Unit) { onClose() }
        return
    }
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    val handle = profile.handle
    var editing by rememberSaveable { mutableStateOf(handle == null) }
    var text by rememberSaveable { mutableStateOf("") }
    var standing by remember { mutableStateOf<Standing>(Standing.Empty) }
    var saving by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }
    val typed = if (editing) HandleRules.normalized(text) else ""

    LaunchedEffect(typed, editing) {
        if (!editing) return@LaunchedEffect
        val reason = HandleRules.localReason(typed)
        when {
            typed.isEmpty() -> standing = Standing.Empty
            typed == handle -> standing = Standing.Refused(L10n.text("common.handle.current"))
            reason != null -> standing = Standing.Refused(HandleRules.message(reason))
            else -> {
                standing = Standing.Checking
                // Wait for typing to pause. A new character cancels this.
                delay(400)
                standing = try {
                    val answer = model.checkHandle(typed)
                    if (answer.available) Standing.Available
                    else Standing.Refused(HandleRules.message(answer.reason, answer.message))
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    Standing.Unknown(L10n.text("common.handle.check_failed"))
                }
            }
        }
    }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_600)
            copied = false
        }
    }

    val canClaim = !saving && (standing == Standing.Available || standing is Standing.Unknown)
    fun claim() {
        if (!canClaim) return
        saving = true
        scope.launch {
            try {
                model.claimHandle(typed)
                editing = false
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val code = (failure as? CoreFailure)?.code.orEmpty()
                standing = Standing.Refused(
                    if (code.startsWith("profile_")) {
                        HandleRules.message(code.removePrefix("profile_"), failure.message.orEmpty())
                    } else {
                        failure.message ?: L10n.text("common.handle.check_failed")
                    },
                )
            } finally {
                saving = false
            }
        }
    }
    fun save(public: Boolean? = null, indexable: Boolean? = null) {
        if (saving) return
        saving = true
        error = null
        scope.launch {
            try {
                model.setProfile(public, indexable)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                error = failure.message
            } finally {
                saving = false
            }
        }
    }

    val busy by rememberUpdatedState(saving)
    TsBottomSheet(
        onDismissRequest = { if (!busy) onClose() },
        containerColor = colors.background,
        dragHandle = null,
        sheetState = rememberModalBottomSheetState(
            skipPartiallyExpanded = true,
            confirmValueChange = { it != SheetValue.Hidden || !busy },
        ),
    ) {
        Column(
            Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(bottom = Space.xl),
        ) {
            fun field(name: String) = (account?.get(name) as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.ifBlank { null }
            ProfilePlate(
                avatar = field("avatar"),
                name = field("displayName") ?: typed.ifEmpty { null } ?: handle ?: L10n.text("common.profile.title"),
                address = HandleRules.address(
                    profile.host,
                    typed.ifEmpty { null } ?: handle ?: L10n.text("common.handle.placeholder"),
                ),
                isExample = typed.isEmpty() && handle == null,
                isPublic = profile.isPublic,
                copied = copied,
                onCopy = if (editing || handle == null) null else ({
                    scope.launch {
                        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("", "${profile.host}/$handle")))
                        copied = true
                    }
                }),
            )
            Column(
                Modifier.fillMaxWidth().padding(horizontal = Space.l).padding(top = Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.l),
            ) {
                if (editing) {
                    HandleEditor(
                        profile = profile,
                        text = text,
                        onText = { text = it },
                        standing = standing,
                        saving = saving,
                        canClaim = canClaim,
                        leave = when {
                            handle != null -> L10n.text("common.cancel")
                            purpose == ProfilePurpose.OFFER -> L10n.text("common.skip")
                            else -> L10n.text("common.close")
                        },
                        onLeave = { if (handle == null) onClose() else editing = false },
                        onClaim = ::claim,
                    )
                } else if (handle != null) {
                    val days = profile.settings?.changeDays ?: 0
                    val canChange = profile.settings != null && days == 0
                    ProfileRow(
                        icon = if (canChange) ActionIcon.Edit else ActionIcon.Profile,
                        title = "@$handle",
                        detail = when {
                            canChange -> L10n.text("common.handle.change_title")
                            days == 1 -> L10n.text("common.handle.change_tomorrow")
                            days > 0 -> L10n.text("common.handle.change_in_days", "$days")
                            else -> null
                        },
                        modifier = Modifier
                            .profileCard()
                            .then(if (canChange) Modifier.clickable { text = ""; error = null; editing = true } else Modifier),
                    ) {
                        if (canChange) Icon(ActionIcon.Disclosure.vector, null, tint = colors.accent)
                    }
                    profile.settings?.let { settings ->
                        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                            Text(
                                L10n.text("common.profile.who_can_open"),
                                style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
                                color = colors.textSecondary,
                                modifier = Modifier.padding(start = 4.dp),
                            )
                            // Both answers, always in view, with the current
                            // one checked. Going back is the same tap as
                            // going there.
                            Column(Modifier.profileCard().selectableGroup()) {
                                ProfileRow(
                                    icon = ActionIcon.Security,
                                    title = L10n.text("common.profile.private"),
                                    detail = L10n.text("common.profile.private_detail"),
                                    modifier = Modifier.selectable(!profile.isPublic, enabled = !saving, role = Role.RadioButton) {
                                        if (profile.isPublic) save(public = false)
                                    },
                                ) { BrandCheckDisc(!profile.isPublic) }
                                HorizontalDivider(Modifier.padding(start = 58.dp), color = colors.border)
                                ProfileRow(
                                    icon = ActionIcon.Browser,
                                    title = L10n.text("common.profile.public"),
                                    detail = L10n.text("common.profile.public_detail"),
                                    // Going public shows things to strangers,
                                    // so it is asked once more.
                                    modifier = Modifier.selectable(profile.isPublic, enabled = !saving, role = Role.RadioButton) {
                                        if (!profile.isPublic) confirming = true
                                    },
                                ) { BrandCheckDisc(profile.isPublic) }
                            }
                        }
                        if (profile.isPublic) Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Row(
                                Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    L10n.text("common.profile.indexable"),
                                    style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 15.sp),
                                    color = colors.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                TsBrandSwitch(settings.indexable, { save(indexable = it) }, enabled = !saving)
                            }
                            Text(
                                if (settings.indexable) L10n.text("common.profile.indexable_on_detail")
                                else L10n.text("common.profile.indexable_off_detail"),
                                style = TsType.caption,
                                color = colors.textSecondary,
                                modifier = Modifier.padding(horizontal = 4.dp),
                            )
                        }
                    }
                    error?.let { Text(it, style = TsType.caption, color = colors.danger) }
                    if (profile.isPublic) {
                        TsAccentButton(
                            label = L10n.text("common.profile.view"),
                            icon = ActionIcon.External.vector,
                            onClick = { onOpen("${profile.host}/$handle?mobile=1") },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }
    }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text(L10n.text("common.profile.publish_title")) },
            text = { Text(L10n.text("common.profile.public_detail")) },
            confirmButton = {
                TextButton(onClick = { confirming = false; save(public = true) }) { Text(L10n.text("common.profile.make_public")) }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) { Text(L10n.text("common.cancel")) }
            },
        )
    }
}

@Composable
private fun HandleEditor(
    profile: AccountProfile,
    text: String,
    onText: (String) -> Unit,
    standing: Standing,
    saving: Boolean,
    canClaim: Boolean,
    leave: String,
    onLeave: () -> Unit,
    onClaim: () -> Unit,
) {
    val colors = LocalTsColors.current
    val focus = remember { FocusRequester() }
    val mono = TextStyle(fontFamily = TsType.monoFamily, fontSize = 16.sp)
    val claiming = profile.handle == null
    Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            Text(
                if (claiming) L10n.text("common.handle.claim_title") else L10n.text("common.handle.change_title"),
                style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 18.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                if (claiming) L10n.text("common.handle.claim_note") else L10n.text("common.handle.change_note"),
                style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 14.sp),
                color = colors.textSecondary,
            )
        }
        OutlinedTextField(
            value = text,
            onValueChange = onText,
            enabled = !saving,
            singleLine = true,
            isError = standing is Standing.Refused,
            textStyle = mono,
            prefix = { Text(HandleRules.prefix(profile.host), style = mono, color = colors.textSecondary) },
            placeholder = { Text(L10n.text("common.handle.placeholder"), style = mono) },
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Ascii,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { onClaim() }),
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(focus)
                .semantics { contentDescription = L10n.text("common.handle.field_label") },
        )
        LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
        StandingLine(standing)
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsSecondaryButton(
                label = leave,
                icon = ActionIcon.Dismiss.vector,
                enabled = !saving,
                onClick = onLeave,
                modifier = Modifier.weight(1f),
            )
            TsAccentButton(
                label = if (claiming) L10n.text("common.handle.claim") else L10n.text("common.save"),
                icon = if (claiming) ActionIcon.Claim.vector else ActionIcon.Save.vector,
                enabled = canClaim,
                onClick = onClaim,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/// The person and the address, over the grid the product draws days on. The
/// grid lights when the page is public. Port of `ProfilePlate`.
@Composable
private fun ProfilePlate(
    avatar: String?,
    name: String,
    address: String,
    isExample: Boolean,
    isPublic: Boolean,
    copied: Boolean,
    /// Null while the address is only a draft: a link to nowhere is not worth
    /// copying.
    onCopy: (() -> Unit)?,
) {
    val colors = LocalTsColors.current
    val cell by animateColorAsState(
        if (isPublic) colors.accent.copy(alpha = 0.4f) else colors.controlGlyph.copy(alpha = 0.22f),
        label = "profileGrid",
    )
    Box(Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(colors.accentSoft, Color.Transparent)))) {
        // Every cell is the same colour and only fades with distance, so it
        // never reads as somebody's activity.
        Canvas(Modifier.matchParentSize()) {
            val step = 15.dp.toPx()
            val side = 11.dp.toPx()
            val centerX = size.width / 2
            val centerY = size.height * 0.36f
            val reach = maxOf(size.width * 0.62f, 1f)
            val columns = (size.width / step).toInt() + 1
            val inset = (size.width - columns * step + (step - side)) / 2
            for (column in 0 until columns) {
                for (row in 0..(size.height / step).toInt()) {
                    val x = inset + column * step
                    val y = row * step
                    val drop = y - centerY
                    val distance = hypot(x - centerX, drop * (if (drop > 0) 2.6f else 1.3f))
                    val fade = maxOf(0f, 1 - distance / reach).pow(1.5f)
                    if (fade > 0.02f) {
                        drawRoundRect(
                            cell.copy(alpha = cell.alpha * fade), Offset(x, y), Size(side, side), CornerRadius(3.dp.toPx()),
                        )
                    }
                }
            }
        }
        Box(
            Modifier.align(Alignment.TopCenter).padding(top = 10.dp).size(width = 32.dp, height = 4.dp)
                .clip(CircleShape).background(colors.controlGlyph.copy(alpha = 0.5f)),
        )
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Space.l).padding(top = 40.dp, bottom = Space.l),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Box(Modifier.clip(CircleShape).background(colors.background).padding(3.dp)) {
                Avatar(name, size = 84, avatarUrl = avatar, decorative = true)
            }
            Text(
                name,
                style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                Modifier
                    .clip(CircleShape)
                    .background(colors.panel)
                    .border(1.dp, colors.border, CircleShape)
                    .then(
                        if (onCopy == null) Modifier
                        else Modifier.clickable(onClickLabel = L10n.text("common.profile.copy_address", address), onClick = onCopy),
                    )
                    .heightIn(min = 36.dp)
                    .padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    address,
                    style = TextStyle(fontFamily = TsType.monoFamily, fontSize = 13.sp),
                    color = if (isExample) colors.textTertiary else colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (onCopy != null) {
                    Icon(
                        if (copied) ActionIcon.Done.vector else ActionIcon.Copy.vector,
                        null,
                        tint = if (copied) colors.diffAdded else colors.controlGlyph,
                        modifier = Modifier.size(15.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun Modifier.profileCard(): Modifier {
    val colors = LocalTsColors.current
    return fillMaxWidth().clip(profileShape).background(colors.panel).border(1.dp, colors.border, profileShape)
}

@Composable
private fun ProfileRow(
    icon: ActionIcon,
    title: String,
    detail: String?,
    modifier: Modifier = Modifier,
    trailing: @Composable () -> Unit,
) {
    val colors = LocalTsColors.current
    Row(
        modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Box(
            Modifier.size(30.dp).clip(RoundedCornerShape(9.dp)).background(colors.accent.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon.vector, null, tint = colors.accent, modifier = Modifier.size(16.dp)) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 15.sp, fontWeight = FontWeight.Medium), color = colors.textPrimary)
            detail?.let { Text(it, style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 13.sp), color = colors.textSecondary) }
        }
        trailing()
    }
}

/// The line under the name in Account: the handle and whether its page is
/// public, or the invitation to have one.
@Composable
fun ProfileNameLine(profile: AccountProfile?) {
    val colors = LocalTsColors.current
    val handle = profile?.handle
    if (handle != null) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("@$handle", style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 14.sp), color = colors.textSecondary)
            if (profile.settings != null) {
                Icon(
                    (if (profile.isPublic) ActionIcon.Browser else ActionIcon.Security).vector,
                    if (profile.isPublic) L10n.text("common.profile.public") else L10n.text("common.profile.private"),
                    tint = if (profile.isPublic) colors.accent else colors.textTertiary,
                    modifier = Modifier.size(13.dp),
                )
            }
        }
    } else if (profile?.settings != null) {
        Text(L10n.text("common.handle.claim_title"), style = TextStyle(fontFamily = TsType.interfaceFamily, fontSize = 14.sp), color = colors.accent)
    }
}

/// Always one line, so the sheet does not jump as the answer changes.
@Composable
private fun StandingLine(standing: Standing) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 20.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        val (icon, tint, words) = when (standing) {
            Standing.Empty -> Triple(null, colors.textSecondary, L10n.text("common.handle.hint", "${HandleRules.MINIMUM}"))
            Standing.Checking -> Triple(null, colors.textSecondary, L10n.text("common.handle.checking"))
            Standing.Available -> Triple(ActionIcon.Allow.vector, colors.diffAdded, L10n.text("common.handle.available"))
            is Standing.Refused -> Triple(ActionIcon.Deny.vector, colors.danger, standing.message)
            is Standing.Unknown -> Triple(ActionIcon.Help.vector, colors.warning, standing.message)
        }
        if (standing == Standing.Checking) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.accent)
        }
        icon?.let { Icon(it, null, tint = tint, modifier = Modifier.size(16.dp)) }
        Text(words, style = TsType.caption, color = tint)
    }
}
