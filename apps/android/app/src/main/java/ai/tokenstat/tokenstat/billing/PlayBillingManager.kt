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
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class PlanProduct(val details: ProductDetails, val label: String, val price: String)
data class BillingState(val loading: Boolean = true, val products: List<PlanProduct> = emptyList(), val error: String? = null)

class PlayBillingManager(context: Context) : PurchasesUpdatedListener, BillingClientStateListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableState = MutableStateFlow(BillingState())
    val state = mutableState.asStateFlow()
    @Volatile var appAccountToken: String? = null
    @Volatile var onActivated: ((JsonElement) -> Unit)? = null

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
            mutableState.value = BillingState(false, found.productDetailsList.mapNotNull { details ->
                val offer = details.subscriptionOfferDetails?.firstOrNull() ?: return@mapNotNull null
                val phase = offer.pricingPhases.pricingPhaseList.lastOrNull() ?: return@mapNotNull null
                PlanProduct(details, details.name, phase.formattedPrice)
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
        val offer = product.details.subscriptionOfferDetails?.firstOrNull() ?: return
        val details = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(product.details).setOfferToken(offer.offerToken).build()
        client.launchBillingFlow(
            activity,
            BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(details))
                .setObfuscatedAccountId(token)
                .build(),
        )
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> scope.launch { activate(purchases.orEmpty()) }
            BillingClient.BillingResponseCode.USER_CANCELED -> Unit
            else -> mutableState.value = mutableState.value.copy(error = result.debugMessage)
        }
    }

    private suspend fun activate(purchases: List<Purchase>) {
        val expected = appAccountToken?.trim().orEmpty()
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
        val PRODUCT_IDS = listOf(
            "ai.tokenstat.supporter.yearly",
            "ai.tokenstat.patron.yearly",
            "ai.tokenstat.legend.yearly",
        )
    }
}
