import Foundation
import Combine
import GoogleMobileAds
import StoreKit
import UserMessagingPlatform

enum RemoveAdsStoreStatus: Equatable {
    case idle
    case loadingProduct
    case ready
    case purchasing
    case pending
    case purchased
    case restoring
    case restored
    case nothingToRestore
    case unavailable
    case failed
}

@MainActor
final class AdsManager: ObservableObject {
    static let productionNativeAdUnitID = "ca-app-pub-5711059975397542/2929729241"
    static let removeAdsSubscriptionProductID = "com.jock.game.tractor.removeads.monthly"

    static var nativeAdUnitID: String {
        #if DEBUG
        // Google's dedicated iOS Native Advanced test unit prevents invalid production traffic.
        return "ca-app-pub-3940256099942544/3986624511"
        #else
        return productionNativeAdUnitID
        #endif
    }

    @Published private(set) var canRequestAds = false
    @Published private(set) var isPrivacyOptionsRequired = false
    @Published private(set) var hasActiveRemoveAdsSubscription = false
    @Published private(set) var isAdEligibilityResolved = false
    @Published private(set) var removeAdsSubscriptionProduct: Product?
    @Published private(set) var removeAdsStoreStatus: RemoveAdsStoreStatus = .idle
    @Published private(set) var removeAdsStoreError: String?

    private var isGatheringConsent = false
    private var didStartMobileAds = false
    private var didResolveAdEligibility = false
    private var transactionUpdatesTask: Task<Void, Never>?

    var hasAdFreeAccess: Bool {
        hasActiveRemoveAdsSubscription
    }

    var isRemoveAdsStoreBusy: Bool {
        removeAdsStoreStatus == .purchasing || removeAdsStoreStatus == .restoring
    }

    init() {
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.handleTransactionUpdate(result)
            }
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    /// Resolves the active remove-ads subscription before touching UMP or the ads SDK.
    func prepareForAds() async {
        guard !didResolveAdEligibility else { return }
        didResolveAdEligibility = true

        await refreshRemoveAdsSubscriptionEntitlement()
        isAdEligibilityResolved = true
        reconcileAdsWithEntitlements()

        await loadRemoveAdsProductIfNeeded()
    }

    func loadRemoveAdsProductIfNeeded(forceReload: Bool = false) async {
        guard forceReload || removeAdsSubscriptionProduct == nil else { return }
        guard !isRemoveAdsStoreBusy else { return }

        removeAdsStoreStatus = .loadingProduct
        removeAdsStoreError = nil

        do {
            let product = try await Product.products(
                for: [Self.removeAdsSubscriptionProductID]
            ).first
            guard product?.type == .autoRenewable,
                  product?.subscription != nil else {
                removeAdsSubscriptionProduct = nil
                removeAdsStoreStatus = .unavailable
                return
            }
            removeAdsSubscriptionProduct = product
            removeAdsStoreStatus = .ready
        } catch {
            failRemoveAdsStore(with: error)
        }
    }

    func subscribeToRemoveAds() async {
        guard !hasAdFreeAccess else {
            removeAdsStoreStatus = .purchased
            return
        }

        if removeAdsSubscriptionProduct == nil {
            await loadRemoveAdsProductIfNeeded(forceReload: true)
        }
        guard let product = removeAdsSubscriptionProduct else {
            removeAdsStoreStatus = .unavailable
            return
        }

        removeAdsStoreStatus = .purchasing
        removeAdsStoreError = nil

        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    guard transaction.productID == Self.removeAdsSubscriptionProductID,
                          transaction.revocationDate == nil,
                          transaction.expirationDate.map({ $0 > Date() }) ?? true else {
                        removeAdsStoreStatus = .failed
                        return
                    }

                    // The verified purchase itself is authoritative. Setting the entitlement
                    // immediately avoids a short local-StoreKit race before currentEntitlements
                    // publishes the new transaction.
                    hasActiveRemoveAdsSubscription = true
                    await transaction.finish()
                    reconcileAdsWithEntitlements()
                    removeAdsStoreStatus = .purchased

                case .unverified(_, let error):
                    failRemoveAdsStore(with: error)
                }

            case .pending:
                removeAdsStoreStatus = .pending

            case .userCancelled:
                removeAdsStoreStatus = .ready

            @unknown default:
                removeAdsStoreStatus = .failed
            }
        } catch {
            failRemoveAdsStore(with: error)
        }
    }

    func restoreRemoveAdsSubscription() async {
        guard !isRemoveAdsStoreBusy else { return }

        removeAdsStoreStatus = .restoring
        removeAdsStoreError = nil

        do {
            // AppStore.sync() may prompt for credentials, so this is only called from the button.
            try await AppStore.sync()
            await refreshRemoveAdsSubscriptionEntitlement()
            reconcileAdsWithEntitlements()
            removeAdsStoreStatus = hasActiveRemoveAdsSubscription ? .restored : .nothingToRestore
        } catch {
            failRemoveAdsStore(with: error)
        }
    }

    /// Re-checks subscription expiry and billing changes whenever the app returns to foreground.
    func refreshAdFreeAccess() async {
        guard isAdEligibilityResolved else { return }
        await refreshRemoveAdsSubscriptionEntitlement()
        reconcileAdsWithEntitlements()
    }

    /// Refreshes UMP consent, presents any required form, and only then starts ads.
    private func gatherConsent() {
        guard !isGatheringConsent else { return }
        isGatheringConsent = true

        let parameters = RequestParameters()
        ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { [weak self] updateError in
            Task { @MainActor in
                guard let self else { return }

                // UMP can retain a usable consent decision from an earlier session even if refresh fails.
                guard updateError == nil else {
                    self.finishConsentGathering()
                    return
                }

                do {
                    try await ConsentForm.loadAndPresentIfRequired(from: nil)
                } catch {
                    // The cached UMP value remains authoritative; never bypass canRequestAds on error.
                }
                self.finishConsentGathering()
            }
        }
    }

    func presentPrivacyOptions() async {
        do {
            try await ConsentForm.presentPrivacyOptionsForm(from: nil)
        } catch {
            // Keep the entry point available so the user can retry if presentation was interrupted.
        }
        refreshConsentState()
    }

    private func finishConsentGathering() {
        isGatheringConsent = false
        refreshConsentState()
        startMobileAdsIfAllowed()
    }

    private func refreshConsentState() {
        canRequestAds = ConsentInformation.shared.canRequestAds && !hasAdFreeAccess
        isPrivacyOptionsRequired = !hasAdFreeAccess &&
            ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    private func startMobileAdsIfAllowed() {
        guard canRequestAds, !hasAdFreeAccess, !didStartMobileAds else { return }
        didStartMobileAds = true
        MobileAds.shared.start()
    }

    private func refreshRemoveAdsSubscriptionEntitlement() async {
        var isEntitled = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.removeAdsSubscriptionProductID,
                  transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > Date() }) ?? true else { continue }
            isEntitled = true
            break
        }

        hasActiveRemoveAdsSubscription = isEntitled
    }

    private func handleTransactionUpdate(
        _ result: VerificationResult<Transaction>
    ) async {
        guard case .verified(let transaction) = result,
              transaction.productID == Self.removeAdsSubscriptionProductID else { return }

        // Never finish transactions for products that this service does not own.
        await transaction.finish()
        await refreshRemoveAdsSubscriptionEntitlement()
        reconcileAdsWithEntitlements()
        removeAdsStoreStatus = hasActiveRemoveAdsSubscription ? .purchased : .ready
    }

    private func failRemoveAdsStore(with error: Error) {
        removeAdsStoreStatus = .failed
        removeAdsStoreError = error.localizedDescription
    }

    private func reconcileAdsWithEntitlements() {
        guard isAdEligibilityResolved else { return }

        if hasAdFreeAccess {
            canRequestAds = false
            isPrivacyOptionsRequired = false
        } else {
            gatherConsent()
        }
    }

}
