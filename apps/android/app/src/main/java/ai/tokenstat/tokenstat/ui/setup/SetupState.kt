// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.core.CoreFailure
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

object SetupIdentity {
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

    fun accountIdentity(handle: String?, id: String?): String =
        ai.tokenstat.tokenstat.ui.logic.AccountIdentityPins.identity(handle, id).orEmpty()
}

enum class SetupMilestone {
    TRUSTED, CHECKED, INSTALL_REQUESTED, VERIFYING, HOST_READY;

    fun summary(): String = when (this) {
        TRUSTED -> L10n.text("android.setupstate.its_fingerprint_is_verified_setup_carries.85d90f26")
        CHECKED -> L10n.text("android.setupstate.it_is_checked_and_ready_to_install.8f2e0902")
        INSTALL_REQUESTED -> L10n.text("android.setupstate.the_installer_was_started_setup_asks_the_s.2ca3a719")
        VERIFYING -> L10n.text("android.setupstate.the_server_is_installed_setup_is_waiting_f.fe7267cd")
        HOST_READY -> L10n.text("android.setupstate.the_server_answered_one_last_check_finishe.a9101f9b")
    }
}

enum class SetupAction {
    CHECK_ADDRESS, REVIEW_FINGERPRINT, CHECK_CREDENTIAL, CHECK_SERVER,
    NEW_CODE, SIGN_IN_AGENT, SIGN_IN_ACCOUNT, UPDATE_MACHINE, RETRY;

    fun title(): String = when (this) {
        CHECK_ADDRESS -> L10n.text("android.setupstate.check_the_address.b092b174")
        REVIEW_FINGERPRINT -> L10n.text("android.setupstate.review_the_fingerprint.377df466")
        CHECK_CREDENTIAL -> L10n.text("android.setupstate.check_the_credential.5f42f1c7")
        CHECK_SERVER -> L10n.text("android.setupstate.check_the_server.eb259223")
        NEW_CODE -> L10n.text("android.setupstate.get_a_new_code.42cc251c")
        SIGN_IN_AGENT, SIGN_IN_ACCOUNT -> L10n.text("common.sign_in")
        UPDATE_MACHINE -> L10n.text("android.setupstate.how_to_update.d97d76cb")
        RETRY -> L10n.text("android.setupstate.try_again.d8b8392e")
    }

    fun step(): SetupStep? = when (this) {
        CHECK_ADDRESS, REVIEW_FINGERPRINT -> SetupStep.WHERE
        CHECK_CREDENTIAL -> SetupStep.CREDENTIAL
        CHECK_SERVER -> SetupStep.FINISH
        NEW_CODE -> SetupStep.INSTALL
        SIGN_IN_AGENT -> SetupStep.AGENT
        SIGN_IN_ACCOUNT, UPDATE_MACHINE, RETRY -> null
    }
}

enum class SetupStep {
    WHERE, CREDENTIAL, FINGERPRINT, CHECK, INSTALL, FINISH,
    AGENT, PROJECT, NEED_SERVER, BY_HAND, CLOUD, MAC, SERVER,
}

data class SetupFailure(
    val explanation: String,
    val changed: String? = null,
    val action: SetupAction,
    val details: String? = null,
) {
    companion object {
        fun from(error: Throwable): SetupFailure {
            if (error !is CoreFailure) {
                return SetupFailure(
                    explanation = error.message ?: L10n.text("android.setupstate.setup_could_not_continue.8be1b020"),
                    action = SetupAction.RETRY,
                )
            }
            val code = error.code
            val message = error.message
            return when (code) {
                "ssh_unreachable" -> SetupFailure(
                    L10n.text("android.setupstate.we_couldn_t_reach_this_server_check_its_ad.13dd9877"),
                    action = SetupAction.CHECK_ADDRESS,
                    details = message,
                )
                "ssh_host_key_changed" -> SetupFailure(
                    L10n.text("android.setupstate.this_server_s_identity_has_changed_since_i.e7f60705"),
                    changed = L10n.text("android.setupstate.nothing_was_sent_to_it.80689dc8"),
                    action = SetupAction.REVIEW_FINGERPRINT,
                    details = message,
                )
                "ssh_host_key_unverified" -> SetupFailure(
                    L10n.text("android.setupstate.this_server_s_fingerprint_has_not_been_con.98cbb3d1"),
                    action = SetupAction.REVIEW_FINGERPRINT,
                    details = message,
                )
                "ssh_auth_refused" -> SetupFailure(
                    L10n.text("android.setupstate.the_server_refused_the_key_or_password_che.7f44f231"),
                    action = SetupAction.CHECK_CREDENTIAL,
                    details = message,
                )
                "setup_pending" -> SetupFailure(
                    L10n.text("android.setupstate.this_machine_has_not_appeared_on_your_acco.54a9c2b8"),
                    changed = L10n.text("android.setupstate.the_installer_may_still_be_running_on_the.9ccd1cf6"),
                    action = SetupAction.CHECK_SERVER,
                    details = message,
                )
                "identity_mismatch" -> SetupFailure(
                    L10n.text("android.setupstate.the_machine_answered_with_a_different_iden.b027025e"),
                    action = SetupAction.REVIEW_FINGERPRINT,
                    details = message,
                )
                "access_required" -> SetupFailure(
                    L10n.text("android.setupstate.this_machine_is_on_your_account_but_this_d.876ba315"),
                    changed = L10n.text("android.setupstate.the_server_is_installed_and_signed_in.092d7364"),
                    action = SetupAction.CHECK_SERVER,
                    details = message,
                )
                "pairing_expired", "code_expired" -> SetupFailure(
                    L10n.text("android.setupstate.this_pairing_code_has_expired.dc34ec3b"),
                    action = SetupAction.NEW_CODE,
                    details = message,
                )
                "identity_required" -> SetupFailure(
                    L10n.text("android.setupstate.paste_the_full_machine_key_the_installer_p.95ca62ac"),
                    action = SetupAction.RETRY,
                    details = message,
                )
                "account_changed", "signed_out", "auth" -> SetupFailure(
                    L10n.text("android.setupstate.this_device_is_signed_out_of_the_account_t.cd22fc68"),
                    action = SetupAction.SIGN_IN_ACCOUNT,
                    details = message,
                )
                "unknown_method" -> SetupFailure(
                    L10n.text("android.setupstate.this_machine_is_running_an_older_tokenstat.e8972de3"),
                    action = SetupAction.UPDATE_MACHINE,
                    details = message,
                )
                else -> {
                    val lower = message.lowercase()
                    when {
                        lower.contains("unknown method") -> SetupFailure(
                            L10n.text("android.setupstate.this_app_is_running_against_an_older_helpe.66cf1f69"),
                            action = SetupAction.UPDATE_MACHINE,
                            details = message,
                        )
                        lower.contains("not logged in") -> SetupFailure(
                            L10n.text("android.setupstate.this_device_is_signed_out_sign_in_again_th.868697cc"),
                            action = SetupAction.SIGN_IN_ACCOUNT,
                            details = message,
                        )
                        else -> SetupFailure(explanation = message, action = SetupAction.RETRY)
                    }
                }
            }
        }

        fun readable(error: Throwable): String =
            (error as? CoreFailure)?.message ?: error.message ?: L10n.text("android.setupstate.something_went_wrong.0c953ab3")
    }
}

val SETUP_FIRST_TASK = L10n.text("android.setupstate.give_me_a_short_tour_of_this_project_what.bd63b9e4")

sealed interface SetupCredential {
    data object None : SetupCredential
    data class Key(val id: String) : SetupCredential
    data object Password : SetupCredential

    fun ready(password: String): Boolean = when (this) {
        is None -> false
        is Password -> password.isNotEmpty()
        is Key -> true
    }
}

enum class AgentReadiness {
    NOT_INSTALLED, NEEDS_SIGN_IN, SIGNED_IN, EXPIRED, UNKNOWN;

    fun summary(): String = when (this) {
        NOT_INSTALLED -> L10n.text("android.setupstate.not_installed.d177cdc0")
        NEEDS_SIGN_IN -> L10n.text("android.setupstate.not_signed_in.491fc91c")
        SIGNED_IN -> L10n.text("android.setupstate.signed_in.ca566c89")
        EXPIRED -> L10n.text("android.setupstate.sign_in_expired.07fd892e")
        UNKNOWN -> L10n.text("android.setupstate.sign_in_not_checked.58904f56")
    }

    companion object {
        fun parse(raw: String?): AgentReadiness = when (raw) {
            "notInstalled" -> NOT_INSTALLED
            "needsSignIn" -> NEEDS_SIGN_IN
            "signedIn" -> SIGNED_IN
            "expired" -> EXPIRED
            else -> UNKNOWN
        }
    }
}

data class SetupAgent(
    val id: String,
    val name: String,
    val installed: Boolean,
    val readiness: AgentReadiness,
    val signInSupported: Boolean,
) {
    companion object {
        fun of(item: kotlinx.serialization.json.JsonObject): SetupAgent? {
            val id = item.stringOrNull("id") ?: return null
            val signIn = item["signIn"] as? kotlinx.serialization.json.JsonObject
            return SetupAgent(
                id = id,
                name = item.stringOrNull("name")?.takeIf { it.isNotBlank() } ?: id,
                installed = (item["installed"] as? kotlinx.serialization.json.JsonPrimitive)
                    ?.booleanOrNull == true,
                readiness = AgentReadiness.parse(item.stringOrNull("readiness")),
                signInSupported = (signIn?.get("supported") as? kotlinx.serialization.json.JsonPrimitive)
                    ?.booleanOrNull == true,
            )
        }
    }

    fun canSignIn(protocol: Long?): Boolean =
        installed && (readiness == AgentReadiness.NEEDS_SIGN_IN || readiness == AgentReadiness.EXPIRED) &&
            signInSupported && (protocol == null || protocol >= AGENT_SIGN_IN_MIN_PROTOCOL)
}

const val AGENT_SIGN_IN_MIN_PROTOCOL = 9L

private fun kotlinx.serialization.json.JsonObject.stringOrNull(key: String): String? =
    (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull

fun availableMachineName(want: String, labels: Set<String>): String {
    val stem = want.trim().ifEmpty { "server" }
    var candidate = stem
    var suffix = 2
    while (labels.contains(candidate)) {
        candidate = "${stem.take(54)}-$suffix"
        suffix += 1
    }
    return candidate
}
