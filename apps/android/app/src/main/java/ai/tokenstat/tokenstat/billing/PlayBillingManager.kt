// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

import android.app.Activity
import android.content.Context
import ai.tokenstat.tokenstat.core.CoreClient
import com.android.billingclient.api.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class PlanProduct(
    val details: ProductDetails,
    val interval: String,
    val offerToken: String,
    val label: String,
    val price: String,
    val introCaption: String? = null,
)
data class BillingState(
    val loading: Boolean = true,
    val products: List<PlanProduct> = emptyList(),
    val error: String? = null,
    /// Whether Play holds an active subscription of ours to replace. A plan
    /// change without it would stack a second subscription beside the first.
    val hasPlaySubscription: Boolean = false,
)

class PlayBillingManager(context: Context) : PurchasesUpdatedListener, BillingClientStateListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableState = MutableStateFlow(BillingState())
    val state = mutableState.asStateFlow()
    @Volatile var appAccountToken: String? = null
    @Volatile var onActivated: ((JsonElement) -> Unit)? = null

    /// Whether this account has already had its one trial, on any store.
    ///
    /// The gate is account-scoped and lives on the server: a trial taken on
    /// the App Store or through the website counts here, and the reverse. Play
    /// decides its own offer eligibility per Google account and we cannot
    /// refuse what it grants, but we can stop advertising a trial to somebody
    /// who has already had theirs, the way the iOS paywall does.
    @Volatile var trialUsed: Boolean = false
        set(value) {
            val changed = field != value
            field = value
            // The account usually lands after billing has already connected,
            // so the first query ran without knowing this.
            if (changed && client.isReady) queryProducts()
        }

    private val client = BillingClient.newBuilder(context.applicationContext)
        .setListener(this)
        .enablePendingPurchases(
            PendingPurchasesParams.newBuilder().enableOneTimeProducts().enablePrepaidPlans().build()
        )
        .enableAutoServiceReconnection()
        .build()

    fun start() = client.startConnection(this)
    fun close() = client.endConnection()

    override fun onBillingSetupFinished(result: BillingResult) {
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            mutableState.value = BillingState(loading = false, error = result.debugMessage); return
        }
        queryProducts()
        scope.launch {
            val purchases = client.queryPurchasesAsync(
                QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()
            )
            activate(purchases.purchasesList)
        }
    }

    override fun onBillingServiceDisconnected() = Unit

    private fun queryProducts() {
        val products = PRODUCT_IDS.map {
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(it).setProductType(BillingClient.ProductType.SUBS).build()
        }
        client.queryProductDetailsAsync(
            QueryProductDetailsParams.newBuilder().setProductList(products).build()
        ) { result, found ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                mutableState.value = BillingState(false, error = result.debugMessage); return@queryProductDetailsAsync
            }
            mutableState.value = BillingState(false, found.productDetailsList.flatMap { details ->
                // One product per tier, one entry per base plan: monthly and
                // yearly live under the same product id so an interval change
                // stays inside one subscription. An offer the user is
                // eligible for carries the price they would actually pay
                // first; otherwise the plain base plan price.
                details.subscriptionOfferDetails.orEmpty()
                    .groupBy { it.basePlanId }
                    .mapNotNull { (basePlanId, group) ->
                        // The plain base plan for somebody who has had their
                        // trial, the offer for somebody who has not. Play may
                        // still consider them eligible; this is about what the
                        // paywall promises, which must not be a second free
                        // month to an account that already had one.
                        val offer = if (trialUsed) {
                            group.firstOrNull { it.offerId == null } ?: group.firstOrNull()
                        } else {
                            group.firstOrNull { it.offerId != null } ?: group.firstOrNull()
                        } ?: return@mapNotNull null
                        val phases = offer.pricingPhases.pricingPhaseList
                        val phase = phases.lastOrNull() ?: return@mapNotNull null
                        // The regular phase decides the tab: a trial offer
                        // opens with days and ends with the real interval.
                        val interval = intervalOfBasePlan(basePlanId, phase.billingPeriod)
                            ?: return@mapNotNull null
                        PlanProduct(
                            details,
                            interval,
                            offer.offerToken,
                            details.name,
                            phase.formattedPrice,
                            introCaption(phases.map { PhaseView(it.formattedPrice, it.billingPeriod) }),
                        )
                    }
            })
        }
    }

    fun purchase(activity: Activity, product: PlanProduct) {
        val token = appAccountToken?.trim().orEmpty()
        if (token.isEmpty()) {
            mutableState.value = mutableState.value.copy(error = "Sign in before buying a plan.")
            return
        }
        if (token.length > 64) {
            mutableState.value = mutableState.value.copy(error = "This account token is too long for Play Billing.")
            return
        }
        scope.launch {
            // Read at buy time, not at connect time: a subscription bought,
            // cancelled or lapsed since the app started must neither be
            // stacked beside for want of a fresh token nor replaced by a
            // stale one.
            val fresh = runCatching {
                client.queryPurchasesAsync(
                    QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()
                ).purchasesList
            }.getOrNull().orEmpty()
            val oldToken = ourPurchase(fresh)?.purchaseToken
            mutableState.value = mutableState.value.copy(hasPlaySubscription = oldToken != null)
            val details = BillingFlowParams.ProductDetailsParams.newBuilder()
                .setProductDetails(product.details).setOfferToken(product.offerToken).build()
            val flow = BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(details))
                .setObfuscatedAccountId(token)
            if (oldToken != null) {
                // A plan change replaces the subscription Play already holds,
                // which is what the product shape is for: monthly and yearly
                // are base plans under one product id. Immediate, with the
                // price difference settled pro rata, and Play's own sheet
                // says so before anything is charged.
                flow.setSubscriptionUpdateParams(
                    BillingFlowParams.SubscriptionUpdateParams.newBuilder()
                        .setOldPurchaseToken(oldToken)
                        .setSubscriptionReplacementMode(
                            BillingFlowParams.SubscriptionUpdateParams.ReplacementMode.CHARGE_PRORATED_PRICE
                        )
                        .build()
                )
            }
            withContext(Dispatchers.Main) { client.launchBillingFlow(activity, flow.build()) }
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> scope.launch { activate(purchases.orEmpty()) }
            BillingClient.BillingResponseCode.USER_CANCELED -> Unit
            else -> mutableState.value = mutableState.value.copy(error = result.debugMessage)
        }
    }

    /// This account's active subscription among ours, if Play holds one.
    private fun ourPurchase(purchases: List<Purchase>): Purchase? {
        val expected = appAccountToken?.trim().orEmpty()
        return purchases
            .filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
            .firstOrNull { purchase ->
                purchase.products.firstOrNull() in PRODUCT_IDS && run {
                    val offered = purchase.accountIdentifiers?.obfuscatedAccountId
                    offered.isNullOrEmpty() || expected.isEmpty() || offered == expected
                }
            }
    }

    private suspend fun activate(purchases: List<Purchase>) {
        val expected = appAccountToken?.trim().orEmpty()
        val current = ourPurchase(purchases)
        mutableState.value = mutableState.value.copy(hasPlaySubscription = current != null)
        purchases.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }.forEach { purchase ->
            val product = purchase.products.firstOrNull() ?: return@forEach
            val offered = purchase.accountIdentifiers?.obfuscatedAccountId
            if (!offered.isNullOrEmpty() && expected.isNotEmpty() && offered != expected) {
                return@forEach
            }
            runCatching {
                CoreClient.call("account.googleActivate", buildJsonObject {
                    put("packageName", PACKAGE_NAME)
                    put("productId", product)
                    put("purchaseToken", purchase.purchaseToken)
                })
            }.onSuccess { account -> onActivated?.invoke(account) }
                .onFailure { mutableState.value = mutableState.value.copy(error = it.message) }
        }
    }

    companion object {
        const val PACKAGE_NAME = "ai.tokenstat.tokenstat"
        const val INTERVAL_MONTH = "month"
        const val INTERVAL_YEAR = "year"
        // One Play product per tier, unlike Apple where each interval is its
        // own product. Monthly and yearly are base plans under the tier
        // product, so an interval change is a subscription update instead of
        // a cancel plus a new purchase. The ".yearly" in the id is only a
        // name left over from before the monthly base plan existed.
        val PRODUCT_IDS = listOf(
            "ai.tokenstat.supporter.yearly",
            "ai.tokenstat.patron.yearly",
            "ai.tokenstat.legend.yearly",
        )
    }
}
