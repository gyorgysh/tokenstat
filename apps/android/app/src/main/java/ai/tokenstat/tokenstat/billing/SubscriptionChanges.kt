// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

internal enum class SubscriptionChange {
    StoreDefault, ProratedUpgrade, DeferredDowngrade,
}

internal fun subscriptionChange(oldProductId: String?, newProductId: String, tiers: List<String>): SubscriptionChange {
    require(newProductId in tiers) { "Unknown new subscription product" }
    require(oldProductId == null || oldProductId in tiers) { "Unknown existing subscription product" }
    return when {
        oldProductId == null || oldProductId == newProductId -> SubscriptionChange.StoreDefault
        tiers.indexOf(newProductId) > tiers.indexOf(oldProductId) -> SubscriptionChange.ProratedUpgrade
        else -> SubscriptionChange.DeferredDowngrade
    }
}
