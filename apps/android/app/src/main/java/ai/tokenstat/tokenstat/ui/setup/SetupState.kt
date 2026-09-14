// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import ai.tokenstat.tokenstat.core.CoreFailure

/// Setup journey state, ported from `ClientSetupState.swift`.
///
/// The wizard pairs a machine by hand, from the cloud door, or watched from
/// the Mac door, then ends inside a project. Every failure names what failed,
/// what changed if anything, and one concrete next action, chosen from the
/// host's error code rather than its words.
object SetupIdentity {
    /// A public identity is 64 hex characters. Anything else is not a key.
    fun normalize(key: String): String? {
        val value = key.trim()
        if (value.length != 64) return null
        if (!value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return value.lowercase()
    }

    fun matches(actual: String, expected: String): Boolean {
        val a = normalize(actual) ?: return false
        val b = normalize(expected) ?: return false
        return a == b
    }

    /// Whose setup this is. The handle when the account has claimed one, else
    /// the server's own id. An empty answer means the draft goes unpersisted:
    /// one account must never resume another's.
    fun accountIdentity(handle: String?, id: String?): String {
        if (!handle.isNullOrBlank()) return handle.trim()
        if (!id.isNullOrBlank()) return id.trim()
        return ""
    }
}

enum class SetupMilestone {
    TRUSTED, CHECKED, INSTALL_REQUESTED, VERIFYING, HOST_READY;

    /** What happened, in the words somebody would use about their own
     *  server. The installing states say what setup will do next, because
     *  the honest answer after an interruption is that nobody knows how far
     *  it got. */
    fun summary(): String = when (this) {
        TRUSTED -> "Its fingerprint is verified. Setup carries on from your sign-in details."
        CHECKED -> "It is checked and ready to install."
        INSTALL_REQUESTED -> "The installer was started. Setup asks the server what actually happened before it does anything again."
        VERIFYING -> "The server is installed. Setup is waiting for it to reach your account."
        HOST_READY -> "The server answered. One last check finishes this."
    }
}

enum class SetupAction {
    CHECK_ADDRESS, REVIEW_FINGERPRINT, CHECK_CREDENTIAL, CHECK_SERVER,
    NEW_CODE, SIGN_IN_AGENT, SIGN_IN_ACCOUNT, UPDATE_MACHINE, RETRY;

    fun title(): String = when (this) {
        CHECK_ADDRESS -> "Check the address"
        REVIEW_FINGERPRINT -> "Review the fingerprint"
        CHECK_CREDENTIAL -> "Check the credential"
        CHECK_SERVER -> "Check the server"
        NEW_CODE -> "Get a new code"
        SIGN_IN_AGENT, SIGN_IN_ACCOUNT -> "Sign in"
        UPDATE_MACHINE -> "How to update"
        RETRY -> "Try again"
    }

    fun step(): SetupStep? = when (this) {
        CHECK_ADDRESS, REVIEW_FINGERPRINT -> SetupStep.WHERE
        CHECK_CREDENTIAL -> SetupStep.CREDENTIAL
        CHECK_SERVER -> SetupStep.FINISH
        NEW_CODE -> SetupStep.INSTALL
        SIGN_IN_AGENT -> SetupStep.PROJECT
        SIGN_IN_ACCOUNT, UPDATE_MACHINE, RETRY -> null
    }
}

enum class SetupStep {
    WHERE, CREDENTIAL, FINGERPRINT, CHECK, INSTALL, FINISH,
    PROJECT, NEED_SERVER, BY_HAND, CLOUD, MAC, SERVER,
}

data class SetupFailure(
    val explanation: String,
    val changed: String? = null,
    val action: SetupAction,
    val details: String? = null,
) {
    companion object {
        /** Read a failure from whatever was thrown. Codes come from
         *  `tokenstat-host::error`. Anything unrecognised keeps its own
         *  message and offers a retry: an unknown failure is not evidence
         *  that nothing can be done. */
        fun from(error: Throwable): SetupFailure {
            if (error !is CoreFailure) {
                return SetupFailure(
                    explanation = error.message ?: "Setup could not continue.",
                    action = SetupAction.RETRY,
                )
            }
            val code = error.code
            val message = error.message
            return when (code) {
                "ssh_unreachable" -> SetupFailure(
                    "We couldn't reach this server. Check its address, and that it is running and accepting connections.",
                    action = SetupAction.CHECK_ADDRESS,
                    details = message,
                )
                "ssh_host_key_changed" -> SetupFailure(
                    "This server's identity has changed since it was trusted. That can be a reinstall, or it can be the wrong machine answering. Verify the fingerprint before connecting again.",
                    changed = "Nothing was sent to it.",
                    action = SetupAction.REVIEW_FINGERPRINT,
                    details = message,
                )
                "ssh_host_key_unverified" -> SetupFailure(
                    "This server's fingerprint has not been confirmed yet.",
                    action = SetupAction.REVIEW_FINGERPRINT,
                    details = message,
                )
                "ssh_auth_refused" -> SetupFailure(
                    "The server refused the key or password. Check the credential and the user name you are connecting as.",
                    action = SetupAction.CHECK_CREDENTIAL,
                    details = message,
                )
                "setup_pending" -> SetupFailure(
                    "This machine has not appeared on your account yet.",
                    changed = "The installer may still be running on the server.",
                    action = SetupAction.CHECK_SERVER,
                    details = message,
                )
                "identity_mismatch" -> SetupFailure(
                    "The machine answered with a different identity than the one this setup installed. Reconnect and verify the server.",
                    action = SetupAction.REVIEW_FINGERPRINT,
                    details = message,
                )
                "access_required" -> SetupFailure(
                    "This machine is on your account, but this device is not allowed on it yet.",
                    changed = "The server is installed and signed in.",
                    action = SetupAction.CHECK_SERVER,
                    details = message,
                )
                "pairing_expired", "code_expired" -> SetupFailure(
                    "This pairing code has expired.",
                    action = SetupAction.NEW_CODE,
                    details = message,
                )
                "identity_required" -> SetupFailure(
                    "Paste the full machine key the installer printed, so setup finishes on the machine you installed rather than one with the same name.",
                    action = SetupAction.RETRY,
                    details = message,
                )
                "account_changed", "signed_out", "auth" -> SetupFailure(
                    "This device is signed out of the account that started this setup. Sign in again, then continue.",
                    action = SetupAction.SIGN_IN_ACCOUNT,
                    details = message,
                )
                "unknown_method" -> SetupFailure(
                    "This machine is running an older tokenstat, which does not know how to finish setup. Update it there to continue.",
                    action = SetupAction.UPDATE_MACHINE,
                    details = message,
                )
                else -> {
                    val lower = message.lowercase()
                    when {
                        lower.contains("unknown method") -> SetupFailure(
                            "This app is running against an older helper, which does not know how to do that yet. Reinstall tokenstat and try again.",
                            action = SetupAction.UPDATE_MACHINE,
                            details = message,
                        )
                        lower.contains("not logged in") -> SetupFailure(
                            "This device is signed out. Sign in again, then set the machine up.",
                            action = SetupAction.SIGN_IN_ACCOUNT,
                            details = message,
                        )
                        else -> SetupFailure(explanation = message, action = SetupAction.RETRY)
                    }
                }
            }
        }

        /** A readable sentence for an error that never became a SetupFailure. */
        fun readable(error: Throwable): String =
            (error as? CoreFailure)?.message ?: error.message ?: "Something went wrong."
    }
}

/** A first task that reads the project and changes nothing. Deliberately
 *  not "fix" or "add": the first thing somebody sends should not be a
 *  change they have to review before they have seen the place. */
const val SETUP_FIRST_TASK =
    "Give me a short tour of this project: what it does, how it is laid out, and where you would start."
