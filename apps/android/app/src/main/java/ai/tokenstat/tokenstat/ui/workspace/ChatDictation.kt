// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.ChatDictationText
import ai.tokenstat.tokenstat.ui.logic.ChatDictationTranscript
import ai.tokenstat.tokenstat.ui.logic.dictationLevel
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.LocaleList
import android.os.SystemClock
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import java.util.Locale
import kotlin.math.pow
import kotlinx.coroutines.delay

/// Dictation into the chat composer. Port of ChatDictation.swift.
///
/// Android's recognizer hears one stretch of speech and stops at the next
/// pause, so a session starts it again after every result until the person
/// presses Done or Cancel. The on-device recognizer is used when the
/// language has a model on the phone, and the system's own one otherwise.
class ChatDictation(context: Context) {
    enum class Phase { Idle, Starting, Listening, Finishing }

    enum class Fix { AppPermissions, VoiceInput }

    data class Problem(val message: String, val fix: Fix? = null)

    private val context = context.applicationContext
    private val prefs = this.context.getSharedPreferences("tokenstat.chat.v1", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())

    var phase by mutableStateOf(Phase.Idle)
        private set
    var problem by mutableStateOf<Problem?>(null)
    /// A language tag the person picked, or null to follow the phone's languages.
    var chosenLocale by mutableStateOf(prefs.getString(LOCALE_KEY, null))
        private set
    /// Recent loudness, oldest first, each between 0 and 1.
    var levels by mutableStateOf(List(LEVEL_COUNT) { 0f })
        private set
    var startedAt by mutableStateOf<Long?>(null)
        private set
    /// Languages the recognizer says it supports, beyond the phone's own.
    var otherLanguages by mutableStateOf<List<String>>(emptyList())
        private set

    val isActive: Boolean get() = phase != Phase.Idle

    /// The language dictation will listen for.
    val locale: String get() = resolve(chosenLocale)

    private var recognizer: SpeechRecognizer? = null
    private var onDevice = false
    private var text: ChatDictationText? = null
    private var transcript = ChatDictationTranscript()
    private var read: () -> String = { "" }
    private var write: (String) -> Unit = {}
    /// Bumped by every start and stop, so a late result from a finished
    /// session cannot write into the draft.
    private var generation = 0

    /// Switching language mid-sentence keeps what was said and listens on in
    /// the new one.
    fun choose(tag: String?) {
        chosenLocale = tag
        prefs.edit().apply { if (tag == null) remove(LOCALE_KEY) else putString(LOCALE_KEY, tag) }.apply()
        if (!isActive || phase == Phase.Finishing) return
        val read = read
        val write = write
        stop()
        start(read, write)
    }

    fun start(read: () -> String, write: (String) -> Unit) {
        if (phase != Phase.Idle) return
        generation += 1
        val mine = generation
        problem = null
        transcript = ChatDictationTranscript()
        levels = List(LEVEL_COUNT) { 0f }
        this.read = read
        this.write = write
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return fail(mine, Problem(L10n.text("android.chatdictation.microphone_denied"), Fix.AppPermissions))
        }
        val deviceModel = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        if (!deviceModel && !SpeechRecognizer.isRecognitionAvailable(context)) {
            return fail(mine, Problem(L10n.text("android.chatdictation.unavailable"), Fix.VoiceInput))
        }
        phase = Phase.Starting
        begin(mine, deviceModel)
    }

    /// Stop listening and keep the words. Waits briefly for the recognizer
    /// to settle the last of them.
    fun finish() {
        val current = recognizer
        if (phase != Phase.Listening || current == null) return stop()
        val mine = generation
        phase = Phase.Finishing
        current.stopListening()
        main.postDelayed({ if (generation == mine) stop() }, 2_000)
    }

    /// Stop at once. The words already in the draft stay there.
    fun stop() {
        generation += 1
        tearDown()
    }

    /// Stop and put the draft back the way it was before dictation started.
    fun cancel() {
        text?.let { if (read() == it.expected) write(it.original) }
        stop()
    }

    /// Ask the recognizer which languages it knows, for the language menu.
    fun loadLanguages() {
        if (otherLanguages.isNotEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) return
        val probe = SpeechRecognizer.createSpeechRecognizer(context)
        val mine = preferredChoices()
        probe.checkRecognitionSupport(
            recognizeIntent(locale),
            ContextCompat.getMainExecutor(context),
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    val all = (support.installedOnDeviceLanguages + support.supportedOnDeviceLanguages +
                        support.onlineLanguages).distinct()
                    otherLanguages = all.filter { it !in mine }.sortedBy { name(it).lowercase() }
                    probe.destroy()
                }

                override fun onError(error: Int) {
                    probe.destroy()
                }
            },
        )
    }

    private fun begin(mine: Int, deviceModel: Boolean) {
        recognizer?.destroy()
        onDevice = deviceModel
        val created = if (deviceModel && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }
        recognizer = created
        created.setRecognitionListener(Listener(mine))
        try {
            created.startListening(recognizeIntent(locale))
        } catch (failure: RuntimeException) {
            fail(mine, Problem(L10n.text("android.chatdictation.could_not_start", failure.message.orEmpty())))
        }
    }

    /// The recognizer stopped after a pause. Start it again on the same
    /// session, unless the person has finished.
    private fun again(mine: Int) {
        if (generation != mine) return
        if (phase == Phase.Finishing) return stop()
        val current = recognizer ?: return
        try {
            current.startListening(recognizeIntent(locale))
        } catch (failure: RuntimeException) {
            fail(mine, Problem(L10n.text("android.chatdictation.could_not_start", failure.message.orEmpty())))
        }
    }

    private inner class Listener(private val mine: Int) : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (generation != mine) return
            if (phase == Phase.Starting) {
                text = ChatDictationText(read())
                startedAt = SystemClock.elapsedRealtime()
                phase = Phase.Listening
            }
        }

        override fun onRmsChanged(rmsdB: Float) {
            if (generation != mine || phase != Phase.Listening) return
            levels = levels.drop(1) + dictationLevel(rmsdB)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (generation != mine) return
            val words = best(partialResults) ?: return
            transcript.hear(words)
            publish()
        }

        override fun onResults(results: Bundle?) {
            if (generation != mine) return
            best(results)?.let {
                transcript.finish(it)
                publish()
            }
            again(mine)
        }

        override fun onError(error: Int) {
            if (generation != mine) return
            when (error) {
                // Silence, or nothing it could make out. Keep listening.
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> again(mine)
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                    fail(mine, Problem(L10n.text("android.chatdictation.microphone_denied"), Fix.AppPermissions))
                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ->
                    if (onDevice && SpeechRecognizer.isRecognitionAvailable(context)) {
                        // No model for this language on the phone. The
                        // system recognizer may have it online.
                        begin(mine, deviceModel = false)
                    } else {
                        fail(mine, Problem(L10n.text("android.chatdictation.language_unsupported", name(locale))))
                    }
                SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
                SpeechRecognizer.ERROR_SERVER, SpeechRecognizer.ERROR_SERVER_DISCONNECTED ->
                    fail(mine, Problem(L10n.text("android.chatdictation.unavailable"), Fix.VoiceInput))
                // After Done, stopping can end in a client error. That is the
                // end the person asked for, not a failure.
                SpeechRecognizer.ERROR_CLIENT -> if (phase == Phase.Finishing) stop() else again(mine)
                else -> fail(mine, Problem(L10n.text("android.chatdictation.could_not_start", "$error")))
            }
        }

        override fun onBeginningOfSpeech() = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun publish() {
        val current = text ?: return
        val next = current.apply(transcript.text, read()) ?: return stop()
        write(next)
    }

    private fun fail(mine: Int, problem: Problem) {
        if (generation != mine) return
        generation += 1
        tearDown()
        this.problem = problem
    }

    private fun tearDown() {
        main.removeCallbacksAndMessages(null)
        recognizer?.let {
            it.cancel()
            it.destroy()
        }
        recognizer = null
        text = null
        startedAt = null
        phase = Phase.Idle
    }

    private fun recognizeIntent(tag: String): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }

    private fun best(results: Bundle?): String? =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.takeIf { it.isNotBlank() }

    companion object {
        const val LEVEL_COUNT = 160
        private const val LOCALE_KEY = "dictationLocale"

        /// The phone's own languages, in the order the person put them.
        fun preferredChoices(): List<String> {
            val list = LocaleList.getDefault()
            return (0 until list.size()).map { list[it].toLanguageTag() }.distinct()
        }

        fun resolve(chosen: String?): String = chosen ?: preferredChoices().firstOrNull() ?: Locale.getDefault().toLanguageTag()

        fun name(tag: String): String = Locale.forLanguageTag(tag).getDisplayName(Locale.getDefault()).ifEmpty { tag }

        /// Two letters for the chip: EN, HU.
        fun code(tag: String): String = Locale.forLanguageTag(tag).language.ifEmpty { tag }.uppercase()

        fun openSettings(context: Context, fix: Fix) {
            val intent = when (fix) {
                Fix.AppPermissions -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                Fix.VoiceInput -> Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
            }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
            } catch (_: ActivityNotFoundException) {
                context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}

/// One dictation per composer. It stops when the composer leaves the screen
/// or starts sending, and its problems show as a dialog that outlives the
/// control that raised them. Port of `ChatDictationLifetime`.
@Composable
internal fun rememberChatDictation(blocked: Boolean): ChatDictation {
    val context = LocalContext.current
    val dictation = remember { ChatDictation(context) }
    LaunchedEffect(blocked) { if (blocked) dictation.stop() }
    DisposableEffect(dictation) { onDispose { dictation.stop() } }
    dictation.problem?.let { problem ->
        AlertDialog(
            onDismissRequest = { dictation.problem = null },
            title = { Text(L10n.text("android.chatdictation.title")) },
            text = { Text(problem.message) },
            confirmButton = {
                problem.fix?.let { fix ->
                    TextButton(onClick = {
                        dictation.problem = null
                        ChatDictation.openSettings(context, fix)
                    }) { Text(L10n.text("android.chatdictation.open_settings")) }
                }
            },
            dismissButton = {
                TextButton(onClick = { dictation.problem = null }) { Text(L10n.text("android.chatdictation.ok")) }
            },
        )
    }
    return dictation
}

/// The mic beside the field. A press starts listening, asking for the
/// microphone first if it has not been granted. A long press picks the
/// language. Port of `ChatDictationButton`.
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ChatDictationButton(dictation: ChatDictation, read: () -> String, write: (String) -> Unit, enabled: Boolean) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    var choosing by remember { mutableStateOf(false) }
    // A refusal goes through start too, so the explanation and the way to
    // Settings come from one place.
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        dictation.start(read, write)
    }
    val label = L10n.text("android.chatdictation.dictate")
    Box {
        Box(
            Modifier
                .size(48.dp)
                .clip(CircleShape)
                .combinedClickable(
                    enabled = enabled,
                    role = Role.Button,
                    onClickLabel = label,
                    onLongClickLabel = L10n.text("android.chatdictation.choose_language"),
                    onLongClick = { dictation.loadLanguages(); choosing = true },
                    onClick = {
                        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                            PackageManager.PERMISSION_GRANTED
                        if (granted) dictation.start(read, write) else permission.launch(Manifest.permission.RECORD_AUDIO)
                    },
                )
                .semantics { contentDescription = label },
            contentAlignment = Alignment.Center,
        ) {
            Icon(ActionIcon.Dictate.vector, null, tint = if (enabled) colors.textSecondary else colors.textTertiary)
        }
        ChatDictationLanguages(dictation, choosing) { choosing = false }
    }
}

/// What replaces the composer's controls while dictation runs: the language,
/// a live waveform, the time, and Cancel and Done. Port of `ChatDictationBar`.
@Composable
internal fun ChatDictationBar(dictation: ChatDictation) {
    val colors = LocalTsColors.current
    var choosing by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().semantics { contentDescription = L10n.text("android.chatdictation.title") },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box {
            Text(
                ChatDictation.code(dictation.locale),
                style = TsType.mono(11, FontWeight.SemiBold),
                color = colors.accent,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.accentSoft)
                    .clickable(onClickLabel = L10n.text("android.chatdictation.language", ChatDictation.name(dictation.locale))) {
                        dictation.loadLanguages()
                        choosing = true
                    }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            )
            ChatDictationLanguages(dictation, choosing) { choosing = false }
        }
        Box(Modifier.weight(1f).height(28.dp), contentAlignment = Alignment.Center) {
            if (dictation.phase == ChatDictation.Phase.Starting) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.accent)
            } else {
                ChatDictationWaveform(dictation.levels, live = dictation.phase == ChatDictation.Phase.Listening)
            }
        }
        dictation.startedAt?.let { DictationClock(it) }
        IconButton(onClick = { dictation.cancel() }) {
            Icon(ActionIcon.Dismiss.vector, L10n.text("android.chatdictation.cancel"), tint = colors.textSecondary)
        }
        TsAccentButton(
            label = L10n.text("android.chatdictation.done"),
            icon = ActionIcon.Done.vector,
            small = true,
            enabled = dictation.phase == ChatDictation.Phase.Listening,
            onClick = { dictation.finish() },
        )
    }
}

@Composable
private fun DictationClock(startedAt: Long) {
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(startedAt) {
        while (true) {
            now = SystemClock.elapsedRealtime()
            delay(500)
        }
    }
    val seconds = ((now - startedAt) / 1000).coerceAtLeast(0)
    Text("%d:%02d".format(seconds / 60, seconds % 60), style = TsType.mono(12), color = LocalTsColors.current.textSecondary)
}

/// Bars scrolling in from the right, one per slice of audio. Quiet reads as
/// a row of dots, speech as a band that rises and falls with the voice.
@Composable
private fun ChatDictationWaveform(levels: List<Float>, live: Boolean) {
    val accent = LocalTsColors.current.accent
    Canvas(Modifier.fillMaxWidth().height(28.dp)) {
        val bar = 3.dp.toPx()
        val gap = 2.5.dp.toPx()
        val fit = ((size.width + gap) / (bar + gap)).toInt().coerceAtLeast(1)
        val shown = levels.takeLast(fit)
        var x = size.width - shown.size * (bar + gap) + gap
        shown.forEachIndexed { index, level ->
            // A little gain so ordinary speech fills the band.
            val lifted = (level.toDouble().pow(1.4) * 1.6).coerceAtMost(1.0).toFloat()
            val height = maxOf(bar, lifted * size.height)
            val age = index.toFloat() / maxOf(shown.size - 1, 1)
            drawRoundRect(
                color = accent.copy(alpha = if (live) 0.35f + 0.65f * age else 0.3f),
                topLeft = Offset(x, (size.height - height) / 2),
                size = Size(bar, height),
                cornerRadius = CornerRadius(bar / 2),
            )
            x += bar + gap
        }
    }
}

/// Automatic, the phone's own languages, then every other one the recognizer
/// knows. Port of `ChatDictationLanguages`.
@Composable
private fun ChatDictationLanguages(dictation: ChatDictation, expanded: Boolean, onDismiss: () -> Unit) {
    val colors = LocalTsColors.current
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        @Composable
        fun choice(tag: String?, title: String) {
            DropdownMenuItem(
                text = { Text(title) },
                trailingIcon = if (dictation.chosenLocale == tag) {
                    { Icon(ActionIcon.Done.vector, null, tint = colors.accent) }
                } else {
                    null
                },
                onClick = {
                    onDismiss()
                    dictation.choose(tag)
                },
            )
        }
        choice(null, L10n.text("android.chatdictation.automatic", ChatDictation.name(ChatDictation.resolve(null))))
        ChatDictation.preferredChoices().forEach { choice(it, ChatDictation.name(it)) }
        dictation.otherLanguages.forEach { choice(it, ChatDictation.name(it)) }
    }
}
