// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.material.icons.filled.Terminal

import androidx.compose.material.icons.Icons

import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.ui.logic.harnessCanonicalID
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/// A harness brand tile, ported from Design/Marks.swift `HarnessMark`: the
/// product's vector mark on an accent tile, or the initial letter when the
/// harness has no artwork. The drawables are transcribed from the same SVGs
/// the Apple client ships in Brands.xcassets.
@Composable
fun HarnessMark(id: String, size: Dp = 26.dp) {
    val colors = LocalTsColors.current
    // Estimate / rollup rows belong to the same brand as the live source.
    val canonical = when (val c = harnessCanonicalID(id)) {
        "claude_code_estimate", "claude_code_rollup" -> "claude_code"
        else -> c
    }
    // Direct references keep bundled marks reachable through resource shrinking.
    val res = when (canonical) {
        "antigravity" -> R.drawable.brand_antigravity
        "claude_code" -> R.drawable.brand_claude_code
        "cline" -> R.drawable.brand_cline
        "codex" -> R.drawable.brand_codex
        "copilot" -> R.drawable.brand_copilot
        "cursor" -> R.drawable.brand_cursor
        "devin" -> R.drawable.brand_devin
        "distro_almalinux" -> R.drawable.brand_distro_almalinux
        "distro_alpinelinux" -> R.drawable.brand_distro_alpinelinux
        "distro_archlinux" -> R.drawable.brand_distro_archlinux
        "distro_centos" -> R.drawable.brand_distro_centos
        "distro_debian" -> R.drawable.brand_distro_debian
        "distro_fedora" -> R.drawable.brand_distro_fedora
        "distro_gentoo" -> R.drawable.brand_distro_gentoo
        "distro_linux" -> R.drawable.brand_distro_linux
        "distro_linuxmint" -> R.drawable.brand_distro_linuxmint
        "distro_nixos" -> R.drawable.brand_distro_nixos
        "distro_opensuse" -> R.drawable.brand_distro_opensuse
        "distro_redhat" -> R.drawable.brand_distro_redhat
        "distro_rockylinux" -> R.drawable.brand_distro_rockylinux
        "distro_suse" -> R.drawable.brand_distro_suse
        "distro_ubuntu" -> R.drawable.brand_distro_ubuntu
        "dsh" -> R.drawable.brand_dsh
        "gemini" -> R.drawable.brand_gemini
        "grok" -> R.drawable.brand_grok
        "hermes" -> R.drawable.brand_hermes
        "kilo" -> R.drawable.brand_kilo
        "kimi" -> R.drawable.brand_kimi
        "muse" -> R.drawable.brand_muse
        "openclaw" -> R.drawable.brand_openclaw
        "opencode" -> R.drawable.brand_opencode
        "pi" -> R.drawable.brand_pi
        "qwen" -> R.drawable.brand_qwen
        "zed" -> R.drawable.brand_zed
        else -> 0
    }
    // A shell is not a brand, so it has no artwork and fell through to the
    // initial-letter path: the launch grid showed a plain "S" where every
    // other tile showed a mark. The Apple grid draws it as a terminal glyph
    // with no brand tile behind it, because there is no brand to tile.
    if (canonical == "shell") {
        Box(Modifier.size(size), contentAlignment = Alignment.Center) {
            Icon(
                Icons.Default.Terminal,
                harnessName(id),
                tint = colors.accent,
                modifier = Modifier.size(size * 0.82f),
            )
        }
        return
    }
    Box(
        Modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(colors.accent.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center,
    ) {
        if (res != 0) {
            Icon(
                painterResource(res),
                harnessName(id),
                tint = colors.accent,
                modifier = Modifier.size(size * 0.58f),
            )
        } else {
            val initial = harnessName(id).firstOrNull()?.uppercase() ?: "?"
            Text(
                initial,
                style = TextStyle(
                    fontSize = (size.value * 0.46f).sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = colors.accent,
            )
        }
    }
}
