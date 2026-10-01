// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SubscriptionChangesTest {
    private val tiers = listOf("supporter", "patron", "legend")

    @Test fun newSubscriptionUsesStoreDefaults() {
        for (product in tiers) {
            assertEquals(SubscriptionChange.StoreDefault, subscriptionChange(null, product, tiers))
        }
    }

    @Test fun switchingBasePlansWithinAProductUsesConsoleTiming() {
        // Google only permits CHARGE_FULL_PRICE or WITHOUT_PRORATION for
        // same-product interval changes; the Console chooses that timing.
        for (product in tiers) {
            assertEquals(SubscriptionChange.StoreDefault, subscriptionChange(product, product, tiers))
        }
    }

    @Test fun tierUpgradesKeepTheProratedChargePolicy() {
        for (old in tiers.indices) for (new in old + 1 until tiers.size) {
            assertEquals(SubscriptionChange.ProratedUpgrade, subscriptionChange(tiers[old], tiers[new], tiers))
        }
    }

    @Test fun downgradesKeepTheAlreadyPaidTierUntilRenewal() {
        for (old in tiers.indices) for (new in 0 until old) {
            assertEquals(SubscriptionChange.DeferredDowngrade, subscriptionChange(tiers[old], tiers[new], tiers))
        }
    }

    @Test fun unknownProductsCannotTriggerAReplacement() {
        assertThrows(IllegalArgumentException::class.java) { subscriptionChange("foreign", "legend", tiers) }
        assertThrows(IllegalArgumentException::class.java) { subscriptionChange("legend", "foreign", tiers) }
    }
}
