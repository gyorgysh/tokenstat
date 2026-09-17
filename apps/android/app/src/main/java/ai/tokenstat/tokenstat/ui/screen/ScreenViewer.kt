// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import androidx.activity.compose.BackHandler
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.chrome.HideTabBar
import ai.tokenstat.tokenstat.ui.chrome.HideTopBar
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.SurfaceTexture
import android.net.Uri
import android.provider.OpenableColumns
import android.view.Surface
import android.view.TextureView
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewModelScope
import kotlin.math.abs
import kotlin.math.roundToInt

/// Legend screen viewer, the Android twin of `ScreenViewerView.swift`.
///
/// The session lives in `ScreenViewerModel`; this draws it. H.264 is decoded
/// on this device, mouse and keyboard travel back as an ordered side channel,
/// and the relay and account service see encrypted bytes either way.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenViewerScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    tier: String?,
    onPlans: () -> Unit,
    onClose: () -> Unit,
) {
    // Its own header and its own way out, so the app chrome steps aside.
    HideTopBar()
    HideTabBar()
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val clipboard = remember(context) { AndroidScreenClipboard(context) }
    // The viewer close outlives this screen: the composition scope is being
    // cancelled when `release` runs from `onDispose`.
    val session = remember { ScreenViewerModel(model, scope, clipboard, model.viewModelScope) }

    var zoom by remember { mutableFloatStateOf(1f) }
    /// Local displacement of a magnified picture while merely viewing it.
    /// Control mode follows the remote pointer instead and keeps this at zero.
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }
    /// Slow the pointer right down, for a target a few pixels across.
    var fine by remember { mutableStateOf(false) }
    /// The left button is held, so the next drag drags. A toggle rather than
    /// only a long press, because a long press cannot be held while the other
    /// hand does anything and is not visible anywhere on screen.
    var dragLatched by remember { mutableStateOf(false) }
    var heldModifiers by remember { mutableStateOf(0L) }
    var pointerMode by remember { mutableStateOf(ScreenPointerMode.Trackpad) }
    var muted by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(Menu.None) }
    /// The chrome is hidden and the picture has the whole display.
    var immersive by remember { mutableStateOf(false) }
    /// Whether the last rotation into landscape has been acted on, so leaving
    /// immersive mode by hand is not undone on the next redraw.
    var appliedLandscape by remember { mutableStateOf(false) }
    /// The key row has been pulled up over a picture that otherwise has the
    /// whole display.
    var keysRevealed by remember { mutableStateOf(false) }
    var touchView by remember { mutableStateOf<ScreenTouchView?>(null) }
    var keyboardWanted by remember { mutableStateOf(false) }
    var surfaceWidth by remember { mutableFloatStateOf(0f) }
    var surfaceHeight by remember { mutableFloatStateOf(0f) }

    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val controlling = session.isControlling
    // The key row has a place of its own in portrait with the chrome up. Full
    // screen and landscape take that place away, and there it appears only
    // because somebody pulled the handle on the bottom edge.
    val keyBarIsFurniture = !landscape && !immersive
    val showsKeyBar = controlling && (keyBarIsFurniture || keysRevealed)

    fun clampOffset() {
        val horizontal = (surfaceWidth * (zoom - 1f) / 2f).coerceAtLeast(0f)
        val vertical = (surfaceHeight * (zoom - 1f) / 2f).coerceAtLeast(0f)
        offsetX = offsetX.coerceIn(-horizontal, horizontal)
        offsetY = offsetY.coerceIn(-vertical, vertical)
    }

    fun fit() {
        zoom = 1f
        offsetX = 0f
        offsetY = 0f
    }

    DisposableEffect(Unit) {
        val window = (context as? Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        ScreenViewing.show(context, hostLabel)
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            ScreenViewing.hide(context)
            if (dragLatched) session.press(false)
            session.release()
        }
    }

    // Back leaves full screen first, then the viewer. Closing the whole
    // session because somebody wanted the chrome back is a long way to fall.
    BackHandler {
        if (immersive) immersive = false else onClose()
    }

    // Keyed on the tier too: it can load after the viewer opens, and a
    // Legend user with a slow account fetch must not sit behind a paywall
    // until they press Try again.
    LaunchedEffect(peer, tier) { session.start(peer, hostLabel, tier, control = false) }

    // Rotating a phone onto its side is asking for the picture, so going
    // sideways hides the chrome once. Turning it back shows it again.
    LaunchedEffect(landscape) {
        keysRevealed = false
        if (landscape) {
            if (!appliedLandscape) {
                appliedLandscape = true
                immersive = true
            }
        } else {
            appliedLandscape = false
            immersive = false
        }
    }

    // Handing control back leaves nothing on the key row worth showing, and
    // would leave the far end holding a click nothing here can release.
    LaunchedEffect(controlling) {
        if (!controlling) {
            keysRevealed = false
            keyboardWanted = false
            offsetX = 0f
            offsetY = 0f
            if (dragLatched) {
                session.press(false)
                dragLatched = false
            }
        }
    }

    LaunchedEffect(keyboardWanted, controlling, touchView) {
        val view = touchView ?: return@LaunchedEffect
        val ime = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        if (keyboardWanted && controlling) {
            view.requestFocus()
            ime?.showSoftInput(view, 0)
        } else {
            ime?.hideSoftInputFromWindow(view.windowToken, 0)
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { session.sendFile(fileSource(context, it)) }
    }

    val actions = remember(session) {
        ScreenInputActions(
            move = { x, y -> session.move(x, y) },
            nudge = { dx, dy, width, height ->
                // Divided by the zoom, so magnifying the picture magnifies the
                // precision with it: at 4x a finger crosses a quarter as much
                // of the remote screen, which is the whole reason to zoom in
                // on a control too small to hit. Fine takes another third off.
                val sensitivity = 1.6f / zoom.coerceAtLeast(1f) * (if (fine) 0.35f else 1f)
                session.nudge(dx, dy, width, height, sensitivity)
            },
            click = { button, count -> session.click(button, count, heldModifiers) },
            press = { down -> session.press(down) },
            scroll = { dx, dy -> session.scroll(dx, dy) },
            panView = { dx, dy, _, _ ->
                offsetX += dx
                offsetY += dy
                clampOffset()
            },
            text = { value, flags -> session.sendText(value, flags) },
            key = { code, down, flags -> session.sendKey(code, down, flags) },
            magnify = { factor, _, _ ->
                val previous = zoom
                val next = (previous * factor).coerceIn(1f, MAX_ZOOM)
                zoom = next
                if (session.isControlling || next <= 1.01f) {
                    offsetX = 0f
                    offsetY = 0f
                } else {
                    val ratio = if (previous > 0f) next / previous else 1f
                    offsetX *= ratio
                    offsetY *= ratio
                    clampOffset()
                }
            },
            modifiersSpent = { heldModifiers = 0 },
            // A tap on the picture brings the chrome back, but only while
            // merely watching. In control mode a tap is a click on somebody's
            // desktop, so full screen there has the corner button instead.
            tapWhileWatching = { immersive = false },
        )
    }

    Column(Modifier.fillMaxSize().background(Color.Black)) {
        if (!immersive) {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.textPrimary,
                ),
                title = {
                    Column {
                        Text(hostLabel, style = TsType.headline, maxLines = 1)
                        // Worth a line in portrait, not worth one sideways:
                        // every line there is picture somebody rotated the
                        // device to see.
                        if (!landscape) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Box(
                                    Modifier.size(7.dp).clip(CircleShape).background(
                                        if (session.transport == "direct") colors.success
                                        else colors.warning
                                    )
                                )
                                Text(
                                    ScreenFrames.transportLabel(session.transport),
                                    style = TsType.caption,
                                    color = colors.textSecondary,
                                )
                            }
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = colors.textPrimary)
                    }
                },
                actions = {
                    IconButton(
                        onClick = { session.setControl(!controlling) },
                        enabled = session.state != ScreenViewerModel.State.Connecting,
                    ) {
                        Icon(
                            Icons.Default.Mouse,
                            if (controlling) "View only" else "Control",
                            tint = if (controlling) colors.accent else colors.textPrimary,
                        )
                    }
                    if (controlling) {
                        IconButton(onClick = { keyboardWanted = !keyboardWanted }) {
                            Icon(
                                Icons.Default.Keyboard,
                                "Keyboard",
                                tint = if (keyboardWanted) colors.accent else colors.textPrimary,
                            )
                        }
                    }
                    IconButton(onClick = { immersive = true }) {
                        Icon(
                            Icons.Default.Fullscreen,
                            "Full screen",
                            tint = colors.textPrimary,
                        )
                    }
                    Box {
                        IconButton(onClick = { menu = Menu.Main }) {
                            Icon(Icons.Default.MoreVert, "More", tint = colors.textPrimary)
                        }
                        ViewerMenu(
                            open = menu,
                            session = session,
                            controlling = controlling,
                            muted = muted,
                            pointerMode = pointerMode,
                            zoomed = zoom > 1.01f,
                            onDismiss = { menu = Menu.None },
                            onOpen = { menu = it },
                            onMute = {
                                muted = it
                                session.audio.muted = it
                            },
                            onPointerMode = { pointerMode = it },
                            onFit = { fit() },
                            onSendFile = { picker.launch(arrayOf("*/*")) },
                        )
                    }
                },
            )
        }
        BoxWithConstraints(
            Modifier.weight(1f).fillMaxWidth(),
            contentAlignment = Alignment.Center,
        ) {
            // Fit, not fill. Matching the height first on a phone holding a
            // 16:10 desktop made the picture taller than the box and cut the
            // right-hand third of somebody's screen off.
            val roomy = maxWidth / maxHeight > session.aspectRatio
            Box(
                (if (roomy) Modifier.fillMaxHeight() else Modifier.fillMaxWidth())
                    .aspectRatio(session.aspectRatio)
                    .onSizeChanged {
                        surfaceWidth = it.width.toFloat()
                        surfaceHeight = it.height.toFloat()
                    }
                    .graphicsLayer {
                        scaleX = zoom
                        scaleY = zoom
                        // Following the pointer means control mode never needs
                        // a pan gesture: moving the pointer to an edge brings
                        // that edge into view. View mode grows from the centre
                        // and uses the local pan instead.
                        transformOrigin = if (controlling) {
                            TransformOrigin(session.cursorX, session.cursorY)
                        } else {
                            TransformOrigin.Center
                        }
                    }
                    .offset { IntOffset(offsetX.roundToInt(), offsetY.roundToInt()) }
            ) {
                ScreenVideoSurface(session.decoder, Modifier.fillMaxSize())
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx -> ScreenTouchView(ctx).also { touchView = it } },
                    update = { view ->
                        view.actions = actions
                        view.inputEnabled = controlling
                        view.mode = pointerMode
                        view.zoomed = zoom > 1.01f
                        view.modifiers = heldModifiers
                    },
                    onRelease = { view ->
                        view.actions = null
                        if (touchView === view) touchView = null
                    },
                )
                // Trackpad mode hides the finger from the pointer, so the
                // pointer has to be visible. Direct mode does not need it: the
                // finger is the pointer.
                if (controlling && pointerMode == ScreenPointerMode.Trackpad) {
                    Box(
                        Modifier
                            .offset {
                                IntOffset(
                                    (session.cursorX * surfaceWidth - with(density) { 11.dp.toPx() }).roundToInt(),
                                    (session.cursorY * surfaceHeight - with(density) { 11.dp.toPx() }).roundToInt(),
                                )
                            }
                            .size(22.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.35f))
                            .border(2.dp, Color.White, CircleShape)
                    )
                }
            }
            if (session.state != ScreenViewerModel.State.Streaming) {
                ScreenOverlay(
                    session = session,
                    tier = tier,
                    controlling = controlling,
                    onPlans = onPlans,
                    onRetry = { session.start(peer, hostLabel, tier, controlling) },
                )
            }
            // The way out that works in either mode. Hiding the chrome hides
            // the button that hid it, and in control mode a tap on the picture
            // is a click on somebody's desktop.
            if (immersive) {
                TsSecondaryButton(
                    label = "Exit full screen",
                    icon = ActionIcon.ExitFullScreen.vector,
                    small = true,
                    onClick = { immersive = false },
                    modifier = Modifier.align(Alignment.TopEnd).padding(Space.m),
                )
            }
            // Said once, not twice. The key row's first button already reads
            // "Release" while the button is down, so this belongs to the
            // shapes that have no key row, which are exactly the ones where a
            // held button would otherwise be invisible.
            if (dragLatched && !showsKeyBar) {
                Row(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(Space.s)
                        .clip(RoundedCornerShape(50))
                        .background(colors.accent)
                        .padding(horizontal = Space.m, vertical = Space.s),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Text(
                        "Holding the left button",
                        style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = Color.White,
                    )
                    TsSecondaryButton(
                        label = "Release",
                        icon = ActionIcon.Move.vector,
                        small = true,
                        onClick = {
                            session.press(false)
                            dragLatched = false
                        },
                    )
                }
            }
            session.transferProgress?.let { progress ->
                Row(
                    Modifier.align(Alignment.BottomCenter).padding(Space.m).widthIn(max = 280.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier.weight(1f),
                        color = colors.accent,
                    )
                    TsSecondaryButton(
                        label = "Cancel",
                        icon = ActionIcon.Dismiss.vector,
                        small = true,
                        onClick = { session.cancelTransfer() },
                    )
                }
            }
        }
        // Full screen and landscape are the shapes somebody chose for the
        // picture, so the key row does not take a strip of either by default.
        // It is still what control mode reaches for most, so it is one pull
        // away. Below the navigation bar either way: a keycap under the
        // gesture handle is a keycap nobody can press.
        if (controlling) {
            Column(Modifier.navigationBarsPadding()) {
                if (!keyBarIsFurniture) {
                    ScreenKeyBarHandle(revealed = keysRevealed) { keysRevealed = it }
                }
                if (showsKeyBar) {
                    ScreenKeyBar(
                        modifiers = heldModifiers,
                        onModifiers = { heldModifiers = it },
                        send = { code, flags -> touchView?.tap(code, flags) },
                        pointer = ScreenPointerControls(
                            fine = fine,
                            dragLatched = dragLatched,
                            zoom = zoom,
                            click = { button, count -> session.click(button, count, heldModifiers) },
                            toggleDrag = {
                                dragLatched = !dragLatched
                                session.press(dragLatched)
                            },
                            toggleFine = { fine = !fine },
                            resetZoom = { fit() },
                        ),
                    )
                }
            }
        }
    }
}

private const val MAX_ZOOM = 8f

/// The picture, on a texture this device owns.
///
/// A `TextureView` rather than a `SurfaceView` because the picture is pinched,
/// panned and drawn under an overlay. A surface layer punches its own hole
/// through the window and ignores both.
@Composable
private fun ScreenVideoSurface(decoder: ScreenDecoder, modifier: Modifier) {
    // The surface the decoder draws into, owned here. Dropping the reference
    // without releasing it leaks the surface and its buffers on every
    // rotation, so each one is released before it is replaced or forgotten.
    val output = remember { SurfaceHolder() }
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            TextureView(ctx).apply {
                isOpaque = true
                surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                    override fun onSurfaceTextureAvailable(
                        texture: SurfaceTexture,
                        width: Int,
                        height: Int,
                    ) {
                        output.surface?.release()
                        output.surface = Surface(texture)
                        decoder.surface = output.surface
                    }

                    override fun onSurfaceTextureSizeChanged(
                        texture: SurfaceTexture,
                        width: Int,
                        height: Int,
                    ) = Unit

                    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                        decoder.surface = null
                        output.surface?.release()
                        output.surface = null
                        return true
                    }

                    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
                }
            }
        },
        onRelease = {
            decoder.surface = null
            output.surface?.release()
            output.surface = null
        },
    )
}

private class SurfaceHolder {
    var surface: Surface? = null
}

/// The grab handle that pulls the key row up over a full-screen picture.
///
/// Deliberately quiet and deliberately small. A tap on the picture cannot do
/// this job: in control mode a tap is a click on somebody's desktop. So the
/// handle is its own surface on the bottom edge, out of the picture's way, and
/// it answers to a tap or a drag the way a sheet's grabber does.
@Composable
private fun ScreenKeyBarHandle(revealed: Boolean, onRevealed: (Boolean) -> Unit) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .fillMaxWidth()
            // The handle is 4 points tall and a thumb is not. The padding is
            // the target, so the strip that answers is a proper 44.
            .height(44.dp)
            .background(Color.Black)
            .clickable { onRevealed(!revealed) }
            .pointerInput(revealed) {
                detectVerticalDragGestures { _, delta ->
                    if (abs(delta) > 4f) onRevealed(delta < 0f)
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .width(44.dp)
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(colors.textTertiary)
        )
    }
}

/// Cover over the black backing until a picture is on it, or until the session
/// has said why there will not be one.
@Composable
private fun ScreenOverlay(
    session: ScreenViewerModel,
    tier: String?,
    controlling: Boolean,
    onPlans: () -> Unit,
    onRetry: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.45f))
            .padding(Space.l),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.m, Alignment.CenterVertically),
    ) {
        when {
            session.state == ScreenViewerModel.State.Connecting -> {
                CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(28.dp))
                Text(
                    session.message,
                    style = TsType.callout,
                    color = Color.White,
                    textAlign = TextAlign.Center,
                )
            }
            session.needsLegend -> {
                Text(
                    "Screen access is on Legend",
                    style = TsType.headline,
                    color = Color.White,
                    textAlign = TextAlign.Center,
                )
                Text(
                    "Mouse and keyboard never travel without the picture, and the picture is " +
                        "end-to-end encrypted between your devices. Legend is the plan that includes it.",
                    style = TsType.callout,
                    color = Color.White.copy(alpha = 0.72f),
                    textAlign = TextAlign.Center,
                )
                TsAccentButton(label = "See plans", icon = ActionIcon.Plans.vector, onClick = onPlans)
            }
            else -> {
                Text(
                    session.message,
                    style = TsType.callout.copy(fontWeight = FontWeight.Medium),
                    color = Color.White,
                    textAlign = TextAlign.Center,
                )
                Column(
                    Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.White.copy(alpha = 0.08f))
                        .padding(Space.m),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Readiness("Legend plan", tier.equals("legend", ignoreCase = true))
                    Readiness("Signed in and paired", true)
                    Readiness(
                        "Host online",
                        !session.message.contains("offline", ignoreCase = true),
                    )
                    Readiness("Per-device screen permission", !session.needsPermission)
                    Readiness(
                        if (controlling) "Screen Recording and Accessibility"
                        else "Screen Recording on the host",
                        !session.message.contains("recording", ignoreCase = true),
                    )
                }
                if (session.needsPermission) {
                    TsAccentButton(
                        label = "Request access",
                        icon = ActionIcon.Approve.vector,
                        enabled = !session.isRequesting,
                        onClick = { session.requestAccess() },
                    )
                }
                session.requestNotice?.let {
                    Text(
                        it,
                        style = TsType.caption,
                        color = Color.White.copy(alpha = 0.72f),
                        textAlign = TextAlign.Center,
                    )
                }
                TsSecondaryButton(
                    label = "Try again",
                    icon = ActionIcon.Refresh.vector,
                    onClick = onRetry,
                )
            }
        }
    }
}

@Composable
private fun Readiness(title: String, ready: Boolean) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(
            if (ready) ActionIcon.Done.vector else ActionIcon.Visibility.vector,
            null,
            tint = if (ready) colors.success else Color.White.copy(alpha = 0.72f),
            modifier = Modifier.size(16.dp),
        )
        Text(
            title,
            style = TsType.callout,
            color = if (ready) colors.success else Color.White.copy(alpha = 0.72f),
        )
    }
}

private enum class Menu { None, Main, Displays, Quality, Pointer }

@Composable
private fun ViewerMenu(
    open: Menu,
    session: ScreenViewerModel,
    controlling: Boolean,
    muted: Boolean,
    pointerMode: ScreenPointerMode,
    zoomed: Boolean,
    onDismiss: () -> Unit,
    onOpen: (Menu) -> Unit,
    onMute: (Boolean) -> Unit,
    onPointerMode: (ScreenPointerMode) -> Unit,
    onFit: () -> Unit,
    onSendFile: () -> Unit,
) {
    DropdownMenu(expanded = open == Menu.Main, onDismissRequest = onDismiss) {
        if (session.displays.size > 1) {
            DropdownMenuItem(
                text = { Text("Display: " + currentDisplayName(session)) },
                onClick = { onOpen(Menu.Displays) },
            )
        }
        DropdownMenuItem(
            text = { Text("Quality: " + session.quality.title) },
            onClick = { onOpen(Menu.Quality) },
        )
        if (controlling) {
            DropdownMenuItem(
                text = { Text("Pointer: " + pointerMode.title) },
                onClick = { onOpen(Menu.Pointer) },
            )
            DropdownMenuItem(
                text = { Text(if (session.transferProgress == null) "Send file" else "Cancel transfer") },
                onClick = {
                    onDismiss()
                    if (session.transferProgress == null) onSendFile() else session.cancelTransfer()
                },
            )
        }
        DropdownMenuItem(
            text = { Text(if (muted) "Unmute" else "Mute") },
            onClick = {
                onDismiss()
                onMute(!muted)
            },
        )
        if (zoomed) {
            DropdownMenuItem(
                text = { Text("Fit") },
                onClick = {
                    onDismiss()
                    onFit()
                },
            )
        }
    }
    DropdownMenu(expanded = open == Menu.Displays, onDismissRequest = onDismiss) {
        session.displays.forEach { display ->
            DropdownMenuItem(
                text = { Text(display.name) },
                onClick = {
                    onDismiss()
                    session.selectDisplay(display.id)
                },
            )
        }
    }
    DropdownMenu(expanded = open == Menu.Quality, onDismissRequest = onDismiss) {
        ScreenQuality.entries.forEach { choice ->
            DropdownMenuItem(
                text = {
                    Column {
                        Text(choice.title, style = TsType.callout)
                        Text(
                            choice.detail,
                            style = TsType.caption,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                },
                onClick = {
                    onDismiss()
                    session.chooseQuality(choice)
                },
            )
        }
    }
    DropdownMenu(expanded = open == Menu.Pointer, onDismissRequest = onDismiss) {
        ScreenPointerMode.entries.forEach { choice ->
            DropdownMenuItem(
                text = { Text(choice.title) },
                onClick = {
                    onDismiss()
                    onPointerMode(choice)
                },
            )
        }
    }
}

private fun currentDisplayName(session: ScreenViewerModel): String =
    session.displays.firstOrNull { it.id == session.selectedDisplay }?.name
        ?: session.displays.firstOrNull()?.name
        ?: "Main"

/// This device's clipboard, kept in step with the far end while controlling
/// it. The contents are read only when the description says they changed, so
/// a session that copies nothing never trips the system's paste notice.
private class AndroidScreenClipboard(context: Context) : ScreenClipboard {
    private val manager =
        context.applicationContext.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

    override fun stamp(): Long =
        runCatching { manager?.primaryClipDescription?.timestamp ?: -1L }.getOrDefault(-1L)

    override fun read(): String? = runCatching {
        manager?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
    }.getOrNull()

    override fun write(text: String) {
        runCatching { manager?.setPrimaryClip(ClipData.newPlainText("tokenstat", text)) }
    }
}

/// What a document picker handed back, as a name and a way to open it twice.
private fun fileSource(context: Context, uri: Uri): ScreenFileSource {
    val resolver = context.contentResolver
    val name = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { row ->
            if (row.moveToFirst()) row.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
    return ScreenFileSource(name) {
        resolver.openInputStream(uri) ?: throw IllegalStateException("That file could not be read.")
    }
}
