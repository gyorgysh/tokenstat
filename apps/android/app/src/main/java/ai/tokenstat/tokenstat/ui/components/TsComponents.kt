// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.marks.FeatureMark

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Report
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsColors

/// The shared type scale and component set, ported from the Apple client's
/// `Sources/Design/Theme.swift` and `Sources/Design/AppFonts.swift`.
///
/// The phone ladder, not the Mac one: body 17 down through callout 16,
/// subheadline 15, footnote 13, caption 12 and caption2 11. Every size and
/// weight below traces to that file, nothing is invented here. Interface text
/// is Manrope, code and identifiers are JetBrains Mono, both bundled as
/// variable faces under `res/font` from the same files the Mac app ships.
object TsType {
    /// Manrope. Language: navigation, controls, body text, headings, labels.
    val interfaceFamily = FontFamily(Font(R.font.manrope_variable))

    /// JetBrains Mono. Anything read character by character: commands, model
    /// ids, paths, terminals.
    val monoFamily = FontFamily(Font(R.font.jetbrainsmono_variable))

    /// Numbers that sit in columns must not jitter as they update, so anything
    /// numeric uses tabular figures. The interface face, not the terminal one:
    /// Manrope's tabular figures already hold a column still.
    fun numeric(size: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
        fontSize = size.sp,
        fontWeight = weight,
        fontFamily = interfaceFamily,
        fontFeatureSettings = "tnum",
    )

    /// Identifiers read character by character: model ids, machine ids, paths.
    /// Monospaced so strings that look alike do not read alike.
    fun mono(size: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
        fontSize = size.sp,
        fontWeight = weight,
        fontFamily = monoFamily,
    )

    /// Small uppercase label above a group.
    val sectionHeader = TextStyle(
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = interfaceFamily,
    )

    val cardTitle = TextStyle(
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = interfaceFamily,
    )

    // The phone text ladder, in the app's face and at the phone's sizes.
    val largeTitle = TextStyle(fontSize = 34.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val title = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val title2 = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val title3 = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val headline = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, fontFamily = interfaceFamily)
    val body = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val callout = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val subheadline = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val footnote = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val caption = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val caption2 = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)

    /// Conversation prose is read for minutes at a time, not scanned as
    /// chrome: one rung below body, the same step the Apple client takes.
    val chatBody = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val chatCode = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Normal, fontFamily = monoFamily)

    /// The Material slots the app still reads, pointed at the ladder above so
    /// unstyled Material text is Manrope at a tokenstat size rather than the
    /// platform default. Headline numbers keep tabular figures through
    /// [numeric], which these slots do not carry: prose is not a column.
    val typography = Typography(
        displayLarge = largeTitle,
        displayMedium = title,
        displaySmall = title2,
        headlineLarge = title,
        headlineMedium = title2,
        headlineSmall = title3,
        titleLarge = headline,
        titleMedium = callout,
        titleSmall = subheadline,
        bodyLarge = body,
        bodyMedium = callout,
        bodySmall = footnote,
        labelLarge = subheadline,
        labelMedium = caption,
        labelSmall = caption2,
    )
}

val cardRadiusDp = 14.dp
val cardPaddingDp = 16.dp

private val cardShape = RoundedCornerShape(cardRadiusDp)

/** The hairline stroke that carries the structure shadows used to. */
@Composable
fun Modifier.tsCardBorder(): Modifier {
    val colors = LocalTsColors.current
    return border(BorderStroke(1.dp, colors.border), cardShape)
}

/** The panel fill + hairline treatment every card shares. */
@Composable
fun Modifier.tsPanel(): Modifier =
    background(LocalTsColors.current.panel, cardShape).tsCardBorder()

/// A titled panel. Used for every block in the content column.
@Composable
fun TsCard(
    title: String,
    subtitle: String? = null,
    accessory: (@Composable RowScope.() -> Unit)? = null,
    modifier: Modifier = Modifier,
    /// The glyph the Apple `Card(title:subtitle:mark:)` leads with. Named
    /// cards on both clients carry one; a titled card without it is the odd
    /// one out on a screen where every other card has a mark.
    mark: String? = null,
    /// The mark's colour. Danger for a card that ends something, so the tile
    /// says what the card is before the words do.
    markTint: Color? = null,
    content: (@Composable () -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(cardShape)
            .background(colors.panel)
            .tsCardBorder()
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (mark != null) {
                FeatureMark(name = mark, tint = markTint ?: colors.accent, size = 22)
                Spacer(Modifier.width(Space.s))
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = TsType.cardTitle, color = colors.textPrimary)
                if (subtitle != null) {
                    Text(subtitle, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                }
            }
            accessory?.invoke(this@Row)
        }
        content?.invoke()
    }
}

/// A panel without a title row, for clickable device rows and similar.
@Composable
fun TsCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val colors = LocalTsColors.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(cardShape)
            .background(colors.panel)
            .tsCardBorder()
            .padding(cardPaddingDp),
        content = content,
    )
}

/// One headline number with its label.
@Composable
fun Stat(
    label: String,
    value: String,
    note: String? = null,
    tint: Color = Color.Unspecified,
    size: Int = 22,
    expands: Boolean = true,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier.then(if (expands) Modifier.fillMaxWidth() else Modifier),
        verticalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        Text(label.uppercase(), style = TsType.sectionHeader, color = colors.textTertiary)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                value,
                style = TsType.numeric(size, FontWeight.Medium),
                color = if (tint == Color.Unspecified) colors.textPrimary else tint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (note != null) {
                Spacer(Modifier.width(Space.xs))
                Text(note, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary, maxLines = 1)
            }
        }
    }
}

/// A screen section header: the feature mark on its tile beside a title-case
/// headline. Ported from `ClientSectionTitle` in `GlassChrome.swift`.
@Composable
fun SectionTitle(title: String, mark: String, tint: Color = LocalTsColors.current.accent) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        ai.tokenstat.tokenstat.ui.marks.FeatureMark(name = mark, tint = tint, size = 22)
        Text(title, style = TsType.headline, color = LocalTsColors.current.textPrimary)
    }
}

/// A group heading with an optional count.
///
/// Title case in the app's own words, not upper-cased chrome. The Apple
/// clients write `Text("Run an agent").font(ClientType.sectionTitle)` and
/// leave the string alone, so "Run an agent" and "Sessions" read as headings
/// there while Android shouted "RUN AN AGENT" and "SESSIONS" in small grey
/// tertiary. Same words, one of them a heading and the other an eyebrow.
@Composable
fun SectionLabel(text: String, count: Int? = null, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = TsType.headline, color = colors.textPrimary)
        Spacer(Modifier.weight(1f))
        if (count != null) {
            Text(count.toString(), style = TsType.numeric(13), color = colors.textSecondary)
        }
    }
}

/// Names the folder a scoped screen is showing. Accent-soft rather than grey:
/// it is not chrome, it is the answer to "whose cards are these".
@Composable
fun ScopeChip(label: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Row(
        modifier
            .clip(RoundedCornerShape(50))
            .background(colors.accentSoft)
            .padding(horizontal = Space.s, vertical = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium),
            color = colors.accent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/// The account tier, as a small uppercase pill. Uppercase and tracked out,
/// because a tier is a label and not a word in a sentence.
@Composable
fun TierBadge(tier: String) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(colors.accentSoft)
            .border(1.dp, colors.accent.copy(alpha = 0.28f), RoundedCornerShape(50))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Text(
            tier.uppercase(),
            style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Bold),
            color = colors.accent,
        )
    }
}

enum class BannerSeverity(
    val symbol: ImageVector,
    val tint: (TsColors) -> Color,
) {
    INFO(Icons.Outlined.Info, { it.secondary }),
    SUCCESS(Icons.Outlined.CheckCircle, { it.success }),
    WARNING(Icons.Outlined.WarningAmber, { it.warning }),
    DANGER(Icons.Outlined.Report, { it.danger }),
}

/// A line of status across the top of a pane. One banner for the whole app:
/// the same severity must look like the same thing on every screen.
@Composable
fun Banner(text: String, severity: BannerSeverity = BannerSeverity.WARNING, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val tint = severity.tint(colors)
    Row(
        modifier
            .fillMaxWidth()
            .clip(cardShape)
            .background(tint.copy(alpha = 0.12f))
            .padding(Space.m),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(severity.symbol, null, tint = tint, modifier = Modifier.heightIn(max = 18.dp))
        Text(text, style = TextStyle(fontSize = 14.sp), color = tint)
    }
}

/// A figure that shrinks rather than losing its last digits.
///
/// The Apple client writes this as `minimumScaleFactor(0.6)` on every money
/// figure and percentage, and for the same reason: "$1,110.16" clipped to
/// "$1,11" is not a smaller number, it is a wrong one. A phone at 320dp with
/// the system font turned up is exactly where that happens, so the fit is
/// part of the component rather than something each screen remembers.
@Composable
fun TsFitFigure(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    /// How far down it may shrink before it gives up. Half the size, rather
    /// than the Apple client's 0.6: the system font scale multiplies on top
    /// of this on Android, and at 320dp with the font turned up a 0.6 floor
    /// still lost the last digit of a four-figure total.
    minScale: Float = 0.5f,
) {
    BasicText(
        text,
        modifier = modifier,
        style = style.copy(color = color),
        maxLines = 1,
        // The floor can still be too big on the narrowest phone with the
        // largest font. An ellipsis says so; a clipped glyph pretends the
        // number ended there.
        overflow = TextOverflow.Ellipsis,
        autoSize = TextAutoSize.StepBased(
            minFontSize = style.fontSize * minScale,
            maxFontSize = style.fontSize,
            stepSize = 1.sp,
        ),
    )
}

/// What a screen shows when it has no content, and why the three cases are
/// three cases. Port of `ClientEmptyKind`.
///
/// **Empty, unreachable and refused are not the same thing**, and rendering
/// them the same is the mistake `limits.rs` already argues against for quota
/// readings: "no data" and "we could not look" must never read alike. A quiet
/// day is an answer. A host that is down is a problem. An account that does
/// not include this is a decision somebody can act on, and it is the only one
/// of the three that gets a button by default.
enum class EmptyKind {
    /// The answer arrived and it was nothing.
    NothingYet,

    /// We could not get an answer.
    Unreachable,

    /// The answer is no, and signing in or upgrading is the fix.
    NeedsAccount,
    ;

    /// The mark this kind leads with when a screen passes no art of its own.
    val mark: String
        get() = when (this) {
            NothingYet -> "mark_activity"
            Unreachable -> "mark_sync"
            NeedsAccount -> "mark_account"
        }
}

/// What a screen shows before it has anything to show. One component for the
/// whole app: an empty Automations screen and an empty Insights screen are the
/// same situation and should not look like two different products. Port of
/// `ClientEmptyState`.
///
/// The headline names what is missing, the line under it says what the thing
/// is *for*, and the button is the one action that ends the empty state. All
/// of it on a card, like the Apple one, so an empty screen reads as a piece
/// of the app rather than as text that fell into the middle of a page.
@Composable
fun EmptyState(
    /// The glyph to lead with when the screen passes no art. Kept as the
    /// first parameter because most screens pass one positionally. Null falls
    /// back to the kind's mark, which is what a plan gate or an unreachable
    /// screen wants: those three cases have their own vocabulary.
    icon: ImageVector? = null,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    /// Which of the three situations this is. Nothing yet by default: it is
    /// what most screens mean, and it is the only one of the three that is
    /// not news.
    kind: EmptyKind = EmptyKind.NothingYet,
    art: (@Composable () -> Unit)? = null,
    action: (@Composable () -> Unit)? = null,
    /// A second way out, under the first. Rare on purpose: a screen offering
    /// two answers to "there is nothing here" usually has one too many.
    secondaryAction: (@Composable () -> Unit)? = null,
    /// Off for a caller that is already drawing its own card around this.
    card: Boolean = true,
) {
    val colors = LocalTsColors.current
    Column(
        modifier
            .fillMaxWidth()
            .then(if (card) Modifier.tsPanel() else Modifier)
            .padding(horizontal = Space.m, vertical = Space.l),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        when {
            art != null -> art()
            icon != null -> Icon(
                icon,
                null,
                tint = colors.accent.copy(alpha = 0.7f),
                modifier = Modifier.heightIn(min = 28.dp),
            )
            else -> FeatureMark(
                name = kind.mark,
                tint = if (kind == EmptyKind.Unreachable) colors.textSecondary else colors.accent,
                size = 30,
            )
        }
        Text(
            title,
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            message,
            style = TextStyle(fontSize = 14.sp),
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(0.9f),
        )
        action?.let { Box(Modifier.padding(top = Space.xs)) { it() } }
        secondaryAction?.let { Box(Modifier.padding(top = Space.xs)) { it() } }
    }
}
