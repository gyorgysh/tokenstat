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
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsColors

object TsType {
    @OptIn(ExperimentalTextApi::class)
    val interfaceFamily = FontFamily(
        Font(R.font.manrope_variable, weight = FontWeight.Normal,
            variationSettings = FontVariation.Settings(FontVariation.weight(400))),
        Font(R.font.manrope_variable, weight = FontWeight.Medium,
            variationSettings = FontVariation.Settings(FontVariation.weight(500))),
        Font(R.font.manrope_variable, weight = FontWeight.SemiBold,
            variationSettings = FontVariation.Settings(FontVariation.weight(600))),
        Font(R.font.manrope_variable, weight = FontWeight.Bold,
            variationSettings = FontVariation.Settings(FontVariation.weight(700))),
    )

    val monoFamily = FontFamily(Font(R.font.jetbrainsmono_variable))

    fun numeric(size: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
        fontSize = size.sp,
        fontWeight = weight,
        fontFamily = interfaceFamily,
        fontFeatureSettings = "tnum",
    )

    fun mono(size: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
        fontSize = size.sp,
        fontWeight = weight,
        fontFamily = monoFamily,
    )

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

    val chatHeading = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, fontFamily = interfaceFamily)
    val chatSubheading = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, fontFamily = interfaceFamily)

    val chatBody = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Normal, fontFamily = interfaceFamily)
    val chatCode = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Normal, fontFamily = monoFamily)

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

@Composable
fun Modifier.tsCardBorder(): Modifier {
    val colors = LocalTsColors.current
    return border(BorderStroke(1.dp, colors.border), cardShape)
}

@Composable
fun Modifier.tsPanel(): Modifier =
    background(LocalTsColors.current.panel, cardShape).tsCardBorder()

@Composable
fun TsCard(
    title: String,
    subtitle: String? = null,
    accessory: (@Composable RowScope.() -> Unit)? = null,
    modifier: Modifier = Modifier,
    mark: String? = null,
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

@Composable
fun SectionTitle(title: String, mark: String, tint: Color = LocalTsColors.current.accent) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        ai.tokenstat.tokenstat.ui.marks.FeatureMark(name = mark, tint = tint, size = 22)
        Text(title, style = TsType.headline, color = LocalTsColors.current.textPrimary)
    }
}

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
            ai.tokenstat.tokenstat.ui.marks.planTitle(tier).uppercase(),
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

@Composable
fun TsFitFigure(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    minScale: Float = 0.5f,
) {
    BasicText(
        text,
        modifier = modifier,
        style = style.copy(color = color),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        autoSize = TextAutoSize.StepBased(
            minFontSize = style.fontSize * minScale,
            maxFontSize = style.fontSize,
            stepSize = 1.sp,
        ),
    )
}

enum class EmptyKind {
    NothingYet,

    Unreachable,

    NeedsAccount,
    ;

    val mark: String
        get() = when (this) {
            NothingYet -> "mark_activity"
            Unreachable -> "mark_sync"
            NeedsAccount -> "mark_account"
        }
}

@Composable
fun EmptyState(
    icon: ImageVector? = null,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    kind: EmptyKind = EmptyKind.NothingYet,
    art: (@Composable () -> Unit)? = null,
    action: (@Composable () -> Unit)? = null,
    secondaryAction: (@Composable () -> Unit)? = null,
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
