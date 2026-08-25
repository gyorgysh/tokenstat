// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.ui.graphics.vector.ImageVector

/// One glyph per action. Case names match `ActionIcon.swift` and
/// `shared/web/actionIcons.js`. Android maps them onto Material icons so a
/// Save cannot be a check on one screen and a download on the next.
enum class ActionIcon {
    Save, Claim, Create, Upload, Copy, Download,
    SignIn, SignOut, Account, Settings, Security, Edit,
    Plans, Billing, AppStore, AutoRenew, Downgrade, CancelPlan,
    Token, Preview, Visibility, Theme, Layout,
    Connect, Disconnect, Approve, Pair, Refresh, Revoke, Device,
    Run, Stop, History, Move, Archive, Restore, Browser, Collapse, Commit,
    Delete,
    External, Next, Back, More, Search, Reveal, Docs, Source, Profile, Home, Help,
    Send, Apply, Calculate, Compare, Benchmarks,
    Dismiss, Done, Scheduled, CurrentPlan,
    ;

    val vector: ImageVector
        get() = when (this) {
            Save, CurrentPlan, Done, Commit -> Icons.Default.Check
            Claim, Approve -> Icons.Default.Verified
            Create -> Icons.Default.Add
            Upload -> Icons.Default.Upload
            Copy -> Icons.Outlined.ContentCopy
            Download -> Icons.Default.Download
            SignIn, Account, Profile -> Icons.Default.Person
            SignOut -> Icons.AutoMirrored.Filled.Logout
            Settings -> Icons.Default.Settings
            Security -> Icons.Default.Lock
            Edit -> Icons.Default.Edit
            Plans -> Icons.Default.Star
            Billing -> Icons.Default.CreditCard
            AppStore, External -> Icons.AutoMirrored.Filled.OpenInNew
            AutoRenew, Refresh -> Icons.Default.Refresh
            Downgrade, Move -> Icons.AutoMirrored.Filled.ArrowForward
            CancelPlan, Dismiss, Disconnect -> Icons.Default.Close
            Token, Pair -> Icons.Default.Key
            Preview, Visibility -> Icons.Default.Visibility
            Theme -> Icons.Default.Palette
            Layout -> Icons.Default.GridView
            Connect -> Icons.Default.Link
            Revoke -> Icons.Default.RemoveCircleOutline
            Device -> Icons.Default.Laptop
            Run -> Icons.Default.PlayArrow
            Stop -> Icons.Default.Stop
            History -> Icons.Default.History
            Archive -> Icons.Default.Archive
            Restore -> Icons.Default.History
            Browser -> Icons.Default.Language
            Collapse -> Icons.Default.Close
            Delete -> Icons.Default.Delete
            Next -> Icons.AutoMirrored.Filled.ArrowForward
            Back -> Icons.AutoMirrored.Filled.ArrowBack
            More -> Icons.Default.MoreVert
            Search -> Icons.Default.Search
            Reveal, Source -> Icons.Default.Folder
            Docs -> Icons.Default.Description
            Home -> Icons.Default.Home
            Help -> Icons.AutoMirrored.Filled.HelpOutline
            Send, Apply -> Icons.AutoMirrored.Filled.Send
            Calculate, Compare, Benchmarks -> Icons.Default.BarChart
            Scheduled -> Icons.Default.Schedule
        }
}
