// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.app.Activity
import android.content.Context
import ai.tokenstat.tokenstat.core.CoreClient
import com.android.billingclient.api.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.cancel
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
    val firstPrice: String = price,
    val introCaption: String? = null,
    val billingPeriod: String,
)
data class BillingState(
    val loading: Boolean = true,
    val products: List<PlanProduct> = emptyList(),
    val error: String? = null,
    val hasPlaySubscription: Boolean = false,
)

class PlayBillingManager(context: Context) : PurchasesUpdatedListener, BillingClientStateListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableState = MutableStateFlow(BillingState())
    val state = mutableState.asStateFlow()
    @Volatile var appAccountToken: String? = null
    @Volatile var onActivated: ((JsonElement) -> Unit)? = null

    @Volatile var trialUsed: Boolean = false
        set(value) {
            val changed = field != value
            field = value
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
    fun close() {
        onActivated = null
        scope.cancel()
        client.endConnection()
    }

    override fun onBillingSetupFinished(result: BillingResult) {
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            mutableState.value = BillingState(loading = false, error = result.debugMessage); return
        }
        queryProducts()
        scope.launch {
            val purchases = client.queryPurchasesAsync(
                QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()
            )
            if (purchases.billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
                mutableState.value = mutableState.value.copy(error = purchases.billingResult.debugMessage)
                return@launch
            }
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
                mutableState.update { it.copy(loading = false, error = result.debugMessage) }; return@queryProductDetailsAsync
            }
            val products = found.productDetailsList.flatMap { details ->
                details.subscriptionOfferDetails.orEmpty()
                    .groupBy { it.basePlanId }
                    .mapNotNull { (basePlanId, group) ->
                        val offer = bestOffer(group, trialUsed) {
                            OfferView(
                                it.offerId,
                                it.offerTags,
                                it.pricingPhases.pricingPhaseList.firstOrNull()?.priceAmountMicros ?: Long.MAX_VALUE,
                            )
                        } ?: return@mapNotNull null
                        val phases = offer.pricingPhases.pricingPhaseList
                        val phase = phases.lastOrNull() ?: return@mapNotNull null
                        val interval = intervalOfBasePlan(basePlanId, phase.billingPeriod)
                            ?: return@mapNotNull null
                        PlanProduct(
                            details,
                            interval,
                            offer.offerToken,
                            details.name,
                            phase.formattedPrice,
                            phases.first().formattedPrice,
                            introCaption(phases.map { PhaseView(it.formattedPrice, it.billingPeriod, it.billingCycleCount) }),
                            phase.billingPeriod,
                        )
                    }
            }
            mutableState.update { it.copy(loading = false, products = products, error = null) }
        }
    }

    fun purchase(activity: Activity, product: PlanProduct) {
        val token = appAccountToken?.trim().orEmpty()
        if (token.isEmpty()) {
            mutableState.value = mutableState.value.copy(error = L10n.text("android.playbillingmanager.sign_in_before_buying_a_plan.3ac13e51"))
            return
        }
        if (token.length > 64) {
            mutableState.value = mutableState.value.copy(error = L10n.text("android.playbillingmanager.this_account_token_is_too_long_for_play_bi.baea9663"))
            return
        }
        scope.launch {
            val fresh = runCatching {
                client.queryPurchasesAsync(
                    QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()
                )
            }.getOrElse { error ->
                if (error is CancellationException) throw error
                mutableState.value = mutableState.value.copy(error = L10n.text("android.playbillingmanager.could_not_check_your_play_subscription_ple.85eea382"))
                return@launch
            }
            if (fresh.billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
                mutableState.value = mutableState.value.copy(error = fresh.billingResult.debugMessage)
                return@launch
            }
            if (appAccountToken?.trim() != token) return@launch
            val previous = ourPurchase(fresh.purchasesList)
            val oldProductId = previous?.products?.firstOrNull()
            mutableState.value = mutableState.value.copy(hasPlaySubscription = previous != null)
            val change = runCatching {
                subscriptionChange(oldProductId, product.details.productId, PRODUCT_IDS)
            }.getOrElse {
                mutableState.value = mutableState.value.copy(error = L10n.text("android.playbillingmanager.could_not_check_your_play_subscription_ple.85eea382"))
                return@launch
            }
            val details = BillingFlowParams.ProductDetailsParams.newBuilder()
                .setProductDetails(product.details).setOfferToken(product.offerToken)
            val flow = BillingFlowParams.newBuilder()
                .setObfuscatedAccountId(token)
            val replacementMode = when (change) {
                SubscriptionChange.StoreDefault -> null
                SubscriptionChange.ProratedUpgrade -> BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode.CHARGE_PRORATED_PRICE
                SubscriptionChange.DeferredDowngrade -> BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode.DEFERRED
            }
            if (replacementMode != null && previous != null && oldProductId != null) {
                details.setSubscriptionProductReplacementParams(
                    BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.newBuilder()
                        .setOldProductId(oldProductId)
                        .setReplacementMode(replacementMode)
                        .build()
                )
                flow.setSubscriptionUpdateParams(
                    BillingFlowParams.SubscriptionUpdateParams.newBuilder()
                        .setOldPurchaseToken(previous.purchaseToken)
                        .build()
                )
            }
            flow.setProductDetailsParamsList(listOf(details.build()))
            val result = withContext(Dispatchers.Main) {
                if (appAccountToken?.trim() != token) null else client.launchBillingFlow(activity, flow.build())
            } ?: return@launch
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                mutableState.value = mutableState.value.copy(error = result.debugMessage)
            }
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> scope.launch { activate(purchases.orEmpty()) }
            BillingClient.BillingResponseCode.USER_CANCELED -> Unit
            else -> mutableState.value = mutableState.value.copy(error = result.debugMessage)
        }
    }

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
        if (expected.isEmpty()) return
        purchases.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }.forEach { purchase ->
            val product = purchase.products.firstOrNull { it in PRODUCT_IDS } ?: return@forEach
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
            }.onSuccess { account ->
                if (appAccountToken?.trim() == expected) onActivated?.invoke(account)
            }.onFailure {
                if (it is CancellationException) throw it
                mutableState.value = mutableState.value.copy(error = it.message)
            }
        }
    }

    companion object {
        const val PACKAGE_NAME = "ai.tokenstat.tokenstat"
        const val INTERVAL_MONTH = "month"
        const val INTERVAL_YEAR = "year"
        val PRODUCT_IDS = listOf(
            "ai.tokenstat.supporter.yearly",
            "ai.tokenstat.patron.yearly",
            "ai.tokenstat.legend.yearly",
        )
    }
}
