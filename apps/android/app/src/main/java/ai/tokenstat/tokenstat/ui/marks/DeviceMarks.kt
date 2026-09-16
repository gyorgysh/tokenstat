// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletAndroid
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/// The distro brand a device row wears, ported from `distroBrandID` in
/// `SSHHostPlatform.swift`. Short names match on token boundaries, so `arch`
/// inside another word does not claim Arch Linux. Zero means no mark: the
/// caller draws the platform glyph instead.
fun distroBrandId(label: String?, platform: String?): String? {
    val branded = platform?.takeIf { it.isNotBlank() } ?: label ?: return null
    val name = branded.lowercase()
    val tokens = name.split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() }.toSet()
    return when {
        name.contains("ubuntu") -> "ubuntu"
        name.contains("debian") -> "debian"
        name.contains("fedora") -> "fedora"
        name.contains("alpine") -> "alpinelinux"
        tokens.contains("arch") || name.contains("arch linux") -> "archlinux"
        name.contains("nixos") || name.contains("nix os") -> "nixos"
        tokens.contains("mint") || name.contains("linux mint") -> "linuxmint"
        name.contains("gentoo") -> "gentoo"
        name.contains("rocky") -> "rockylinux"
        tokens.contains("alma") || name.contains("almalinux") -> "almalinux"
        name.contains("centos") -> "centos"
        name.contains("red hat") || tokens.contains("rhel") -> "redhat"
        name.contains("opensuse") -> "opensuse"
        tokens.contains("suse") || tokens.contains("sles") -> "suse"
        tokens.contains("linux") -> "linux"
        else -> null
    }
}

fun distroBrandRes(label: String?, platform: String?): Int = when (distroBrandId(label, platform)) {
    "ubuntu" -> R.drawable.brand_distro_ubuntu
    "debian" -> R.drawable.brand_distro_debian
    "fedora" -> R.drawable.brand_distro_fedora
    "alpinelinux" -> R.drawable.brand_distro_alpinelinux
    "archlinux" -> R.drawable.brand_distro_archlinux
    "nixos" -> R.drawable.brand_distro_nixos
    "linuxmint" -> R.drawable.brand_distro_linuxmint
    "gentoo" -> R.drawable.brand_distro_gentoo
    "rockylinux" -> R.drawable.brand_distro_rockylinux
    "almalinux" -> R.drawable.brand_distro_almalinux
    "centos" -> R.drawable.brand_distro_centos
    "redhat" -> R.drawable.brand_distro_redhat
    "opensuse" -> R.drawable.brand_distro_opensuse
    "suse" -> R.drawable.brand_distro_suse
    "linux" -> R.drawable.brand_distro_linux
    else -> 0
}

/// Which platform glyph a device wears when no distro mark matches, the same
/// decision `ClientDeviceIcon.symbol` makes: a tablet or phone name wins over
/// the kind, servers stay racks, everything else is a laptop or a desktop.
fun deviceGlyphVector(name: String?, isHost: Boolean): ImageVector {
    val lower = (name ?: "").lowercase()
    if (lower.contains("ipad") || lower.contains("tablet")) return Icons.Default.TabletAndroid
    if (lower.contains("iphone") || lower.contains("phone") || lower.contains("android")) {
        return Icons.Default.PhoneAndroid
    }
    if (lower.contains("mini") || lower.contains("studio") || lower.contains("pro")) {
        return Icons.Default.Computer
    }
    if (lower.contains("server") || lower.contains("rack")) return Icons.Default.Dns
    return if (isHost) Icons.Default.Laptop else Icons.Default.PhoneAndroid
}

/// The device in the row: a distro brand where the platform names one,
/// otherwise the platform glyph. The mark is drawn untinted, the glyph in the
/// caller's tint, so brands keep their own colours.
@Composable
fun DeviceGlyph(
    name: String?,
    label: String?,
    platform: String?,
    isHost: Boolean,
    modifier: Modifier = Modifier,
    sizeDp: Int = 18,
    tint: Color = LocalTsColors.current.textSecondary,
) {
    val brand = distroBrandRes(label, platform)
    if (brand != 0) {
        Icon(
            painterResource(brand),
            contentDescription = null,
            modifier = modifier.size(sizeDp.dp),
            tint = Color.Unspecified,
        )
    } else {
        Icon(
            deviceGlyphVector(name, isHost),
            contentDescription = null,
            modifier = modifier.size(sizeDp.dp),
            tint = tint,
        )
    }
}

/// The lit dot before a device name. The device in your hand is awake
/// whatever the directory last recorded: the app asking is running on it.
@Composable
fun AwakeDot(online: Boolean?, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Box(
        modifier.then(
            Modifier.size(9.dp).background(
                if (online == true) colors.accent else colors.textSecondary.copy(alpha = 0.35f),
                CircleShape,
            ),
        ),
    )
}

private val serverDateParsers: List<SimpleDateFormat> = listOf(
    "yyyy-MM-dd'T'HH:mm:ss.SSSX",
    "yyyy-MM-dd'T'HH:mm:ssX",
    "yyyy-MM-dd'T'HH:mm:ss.SSS",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss",
).map {
    SimpleDateFormat(it, Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
        isLenient = false
    }
}

fun parseServerDate(raw: String?): Date? {
    if (raw.isNullOrBlank()) return null
    return serverDateParsers.firstNotNullOfOrNull { runCatching { it.parse(raw) }.getOrNull() }
}

/// "3 minutes ago", for a timestamp whose exact minute nobody reads. Nil when
/// the string does not parse, so the caller decides what absence looks like.
fun formatRelativeDate(raw: String?): String? {
    val date = parseServerDate(raw) ?: return null
    val seconds = ((Date().time - date.time) / 1000).coerceAtLeast(0)
    return when {
        seconds < 10 -> "just now"
        seconds < 60 -> "$seconds seconds ago"
        seconds < 3600 -> {
            val m = seconds / 60
            if (m == 1L) "1 minute ago" else "$m minutes ago"
        }
        seconds < 86400 -> {
            val h = seconds / 3600
            if (h == 1L) "1 hour ago" else "$h hours ago"
        }
        seconds < 7 * 86400 -> {
            val d = seconds / 86400
            if (d == 1L) "yesterday" else "$d days ago"
        }
        else -> SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(date)
    }
}

/// "4 Aug 2026, 18:41". The raw string when nothing parses: a screen showing
/// an ISO string beats one showing the wrong day.
fun formatServerDate(raw: String?): String? {
    if (raw.isNullOrBlank()) return null
    val date = parseServerDate(raw) ?: return raw
    return SimpleDateFormat("d MMM yyyy, HH:mm", Locale.getDefault()).format(date)
}
