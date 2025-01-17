//
//  File 2.swift
//  
//
//  Created by Yusuf Tör on 20/10/2022.
//
// swiftlint:disable type_body_length file_length line_length function_body_length

import StoreKit
import UIKit
import Combine

final class TransactionManager {
  private let storeKitManager: StoreKitManager
  private let receiptManager: ReceiptManager
  private let purchaseController: PurchaseController
  private let sessionEventsManager: SessionEventsManager
  private let eventsQueue: EventsQueue
  private let factory: Factory
  typealias Factory = OptionsFactory
    & TriggerFactory
    & PurchasedTransactionsFactory
    & StoreTransactionFactory
    & DeviceHelperFactory
    & HasExternalPurchaseControllerFactory

  init(
    storeKitManager: StoreKitManager,
    receiptManager: ReceiptManager,
    purchaseController: PurchaseController,
    sessionEventsManager: SessionEventsManager,
    eventsQueue: EventsQueue,
    factory: Factory
  ) {
    self.storeKitManager = storeKitManager
    self.receiptManager = receiptManager
    self.purchaseController = purchaseController
    self.sessionEventsManager = sessionEventsManager
    self.eventsQueue = eventsQueue
    self.factory = factory
  }

  /// Purchases the given product and handles the result appropriately.
  ///
  /// - Parameters:
  ///   - productId: The ID of the product to purchase.
  ///   - paywallViewController: The `PaywallViewController` that the product is being
  ///   purchased from.
  @discardableResult
  func purchase(_ purchaseSource: PurchaseSource) async -> PurchaseResult {
    let product: StoreProduct

    switch purchaseSource {
    case .internal(let productId, _):
      guard let storeProduct = await storeKitManager.productsById[productId] else {
        Logger.debug(
          logLevel: .error,
          scope: .paywallTransactions,
          message: "Trying to purchase \(productId) but the product has failed to load. Visit https://superwall.com/l/missing-products to diagnose."
        )
        return .failed(PurchaseError.productUnavailable)
      }
      product = storeProduct
    case .external(let storeProduct):
      product = storeProduct
    }
    let isEligibleForFreeTrial = await receiptManager.isFreeTrialAvailable(for: product)

    await prepareToPurchase(product: product, purchaseSource: purchaseSource)

    let result = await purchase(product, purchaseSource: purchaseSource)

    switch result {
    case .purchased:
      await didPurchase(
        product: product,
        purchaseSource: purchaseSource,
        didStartFreeTrial: isEligibleForFreeTrial
      )
    case .restored:
      await didRestore(
        product: product,
        restoreSource: purchaseSource.toRestoreSource()
      )
    case .failed(let error):
      let superwallOptions = factory.makeSuperwallOptions()
      guard let outcome = TransactionErrorLogic.handle(
        error,
        triggers: factory.makeTriggers(),
        shouldShowPurchaseFailureAlert: superwallOptions.paywalls.shouldShowPurchaseFailureAlert
      ) else {
        await trackFailure(
          error: error,
          product: product,
          purchaseSource: purchaseSource
        )
        if case let .internal(_, paywallViewController) = purchaseSource {
          await paywallViewController.togglePaywallSpinner(isHidden: true)
        }
        return result
      }
      switch outcome {
      case .cancelled:
        await trackCancelled(
          product: product,
          purchaseSource: purchaseSource
        )
      case .presentAlert:
        await trackFailure(
          error: error,
          product: product,
          purchaseSource: purchaseSource
        )
        await presentAlert(
          title: "An error occurred",
          message: error.safeLocalizedDescription,
          source: purchaseSource.toGenericSource()
        )
      }
    case .pending:
      await handlePendingTransaction(purchaseSource: purchaseSource)
    case .cancelled:
      await trackCancelled(product: product, purchaseSource: purchaseSource)
    }

    return result
  }

  @MainActor
  @discardableResult
  func tryToRestore(_ restoreSource: RestoreSource) async -> RestorationResult {
    func logAndTrack(
      state: InternalSuperwallEvent.Restore.State,
      message: String,
      paywallInfo: PaywallInfo
    ) async {
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: message
      )
      let trackedEvent = InternalSuperwallEvent.Restore(
        state: state,
        paywallInfo: paywallInfo
      )
      await Superwall.shared.track(trackedEvent)
    }

    func handleRestoreResult(
      _ restorationResult: RestorationResult,
      paywallInfo: PaywallInfo,
      paywallViewController: PaywallViewController?
    ) async -> Bool {
      let hasRestored = restorationResult == .restored
      let isUserSubscribed = Superwall.shared.subscriptionStatus == .active

      if hasRestored && isUserSubscribed {
        await logAndTrack(
          state: .complete,
          message: "Transactions Restored",
          paywallInfo: paywallInfo
        )
        await didRestore(restoreSource: restoreSource)
        return true
      } else {
        var message = "Transactions Failed to Restore."
        if !isUserSubscribed && hasRestored {
          message += " The user's subscription status is \"inactive\", but the restoration result is \"restored\". Ensure the subscription status is active before confirming successful restoration."
        }
        if case .failed(let error) = restorationResult,
          let error = error {
          message += " Original restoration error message: \(error.safeLocalizedDescription)"
        }
        await logAndTrack(
          state: .fail(message),
          message: message,
          paywallInfo: paywallInfo
        )
        if let paywallViewController = paywallViewController {
          paywallViewController.webView.messageHandler.handle(.restoreFail(message))
        }
        return false
      }
    }

    switch restoreSource {
    case .internal(let paywallViewController):
      paywallViewController.loadingState = .loadingPurchase

      await logAndTrack(
        state: .start,
        message: "Attempting Restore",
        paywallInfo: paywallViewController.info
      )
      paywallViewController.webView.messageHandler.handle(.restoreStart)

      let restorationResult = await purchaseController.restorePurchases()
      let success = await handleRestoreResult(
        restorationResult,
        paywallInfo: paywallViewController.info,
        paywallViewController: paywallViewController
      )

      if success {
        paywallViewController.webView.messageHandler.handle(.restoreComplete)
      } else {
        paywallViewController.presentAlert(
          title: Superwall.shared.options.paywalls.restoreFailed.title,
          message: Superwall.shared.options.paywalls.restoreFailed.message,
          closeActionTitle: Superwall.shared.options.paywalls.restoreFailed.closeButtonTitle
        )
      }
      return restorationResult
    case .external:
      let hasExternalPurchaseController = factory.makeHasExternalPurchaseController()

      // If there's an external purchase controller, it means they'll be restoring inside the
      // restore function. So, when that function returns, it will hit the internal case first,
      // then here only to do the actual restore, before returning.
      if hasExternalPurchaseController {
        return await factory.restorePurchases(isExternal: true)
      }

      await logAndTrack(
        state: .start,
        message: "Attempting Restore",
        paywallInfo: .empty()
      )

      let restorationResult = await factory.restorePurchases(isExternal: true)
      let success = await handleRestoreResult(
        restorationResult,
        paywallInfo: .empty(),
        paywallViewController: nil
      )

      if !success {
        await presentAlert(
          title: Superwall.shared.options.paywalls.restoreFailed.title,
          message: Superwall.shared.options.paywalls.restoreFailed.message,
          closeActionTitle: Superwall.shared.options.paywalls.restoreFailed.closeButtonTitle,
          source: restoreSource
        )
      }

      return restorationResult
    }
  }

  private func didRestore(
    product: StoreProduct? = nil,
    restoreSource: RestoreSource
  ) async {
    let purchasingCoordinator = factory.makePurchasingCoordinator()
    var transaction: StoreTransaction?
    let restoreType: RestoreType

    if let product = product {
      // Product exists so much have been via a purchase of a specific product.
      transaction = await purchasingCoordinator.getLatestTransaction(
        forProductId: product.productIdentifier,
        factory: factory
      )
      restoreType = .viaPurchase(transaction)
    } else {
      // Otherwise it was a generic restore.
      restoreType = .viaRestore
    }

    switch restoreSource {
    case .internal(let paywallViewController):
      let paywallInfo = await paywallViewController.info

      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .restore(restoreType),
        paywallInfo: paywallInfo,
        product: product,
        model: transaction
      )
      await Superwall.shared.track(trackedEvent)
      await paywallViewController.webView.messageHandler.handle(.transactionRestore)

      let superwallOptions = factory.makeSuperwallOptions()
      if superwallOptions.paywalls.automaticallyDismiss {
        await Superwall.shared.dismiss(paywallViewController, result: .restored)
      }
    case .external:
      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .restore(restoreType),
        paywallInfo: .empty(),
        product: product,
        model: transaction
      )
      await Superwall.shared.track(trackedEvent)
    }
  }

  private func purchase(
    _ product: StoreProduct,
    purchaseSource: PurchaseSource
  ) async -> PurchaseResult {
    guard let sk1Product = product.sk1Product else {
      return .failed(PurchaseError.productUnavailable)
    }

    switch purchaseSource {
    case .internal:
      await factory.makePurchasingCoordinator().beginPurchase(
        of: product.productIdentifier,
        isExternal: false
      )
      return await purchaseController.purchase(product: sk1Product)
    case .external:
      await factory.makePurchasingCoordinator().beginPurchase(
        of: product.productIdentifier,
        isExternal: true
      )
      return await factory.purchase(
        product: sk1Product,
        isExternal: true
      )
    }
  }

  /// Cancels the transaction timeout when the application resigns active.
  ///
  /// When the purchase sheet appears, the application resigns active.

  // MARK: - Transaction lifecycle

  private func trackFailure(
    error: Error,
    product: StoreProduct,
    purchaseSource: PurchaseSource
  ) async {
    switch purchaseSource {
    case .internal(_, let paywallViewController):
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Error",
        info: [
          "product_id": product.productIdentifier,
          "paywall_vc": paywallViewController
        ],
        error: error
      )

      let paywallInfo = await paywallViewController.info
      Task {
        let trackedEvent = InternalSuperwallEvent.Transaction(
          state: .fail(.failure(error.safeLocalizedDescription, product)),
          paywallInfo: paywallInfo,
          product: product,
          model: nil
        )
        await Superwall.shared.track(trackedEvent)
        await paywallViewController.webView.messageHandler.handle(.transactionFail)
      }
    case .external:
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Error",
        info: [
          "product_id": product.productIdentifier
        ],
        error: error
      )

      Task {
        let trackedEvent = InternalSuperwallEvent.Transaction(
          state: .fail(.failure(error.safeLocalizedDescription, product)),
          paywallInfo: .empty(),
          product: product,
          model: nil
        )
        await Superwall.shared.track(trackedEvent)
      }
    }
  }

  /// Tracks the analytics and logs the start of the transaction.
  private func prepareToPurchase(
    product: StoreProduct,
    purchaseSource: PurchaseSource
  ) async {
    switch purchaseSource {
    case .internal(_, let paywallViewController):
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Purchasing",
        info: ["paywall_vc": paywallViewController],
        error: nil
      )

      let paywallInfo = await paywallViewController.info

      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .start(product),
        paywallInfo: paywallInfo,
        product: product,
        model: nil
      )
      await Superwall.shared.track(trackedEvent)
      await paywallViewController.webView.messageHandler.handle(.transactionStart)

      await MainActor.run {
        paywallViewController.loadingState = .loadingPurchase
      }
    case .external:
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "External Transaction Purchasing"
      )

      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .start(product),
        paywallInfo: .empty(),
        product: product,
        model: nil
      )
      await Superwall.shared.track(trackedEvent)
    }
  }

  /// Dismisses the view controller, if the developer hasn't disabled the option.
  private func didPurchase(
    product: StoreProduct,
    purchaseSource: PurchaseSource,
    didStartFreeTrial: Bool
  ) async {
    switch purchaseSource {
    case .internal(_, let paywallViewController):
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Succeeded",
        info: [
          "product_id": product.productIdentifier,
          "paywall_vc": paywallViewController
        ],
        error: nil
      )

      let purchasingCoordinator = factory.makePurchasingCoordinator()
      let transaction = await purchasingCoordinator.getLatestTransaction(
        forProductId: product.productIdentifier,
        factory: factory
      )

      await receiptManager.loadPurchasedProducts()

      await trackTransactionDidSucceed(
        transaction,
        product: product,
        purchaseSource: purchaseSource,
        didStartFreeTrial: didStartFreeTrial
      )

      let superwallOptions = factory.makeSuperwallOptions()
      if superwallOptions.paywalls.automaticallyDismiss {
        await Superwall.shared.dismiss(
          paywallViewController,
          result: .purchased(productId: product.productIdentifier)
        )
      }
    case .external:
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Succeeded",
        info: [
          "product_id": product.productIdentifier
        ],
        error: nil
      )

      let purchasingCoordinator = factory.makePurchasingCoordinator()
      let transaction = await purchasingCoordinator.getLatestTransaction(
        forProductId: product.productIdentifier,
        factory: factory
      )

      await receiptManager.loadPurchasedProducts()

      await trackTransactionDidSucceed(
        transaction,
        product: product,
        purchaseSource: purchaseSource,
        didStartFreeTrial: didStartFreeTrial
      )
    }
  }

  /// Track the cancelled
  private func trackCancelled(
    product: StoreProduct,
    purchaseSource: PurchaseSource
  ) async {
    switch purchaseSource {
    case .internal(_, let paywallViewController):
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Abandoned",
        info: ["product_id": product.productIdentifier, "paywall_vc": paywallViewController],
        error: nil
      )

      let paywallInfo = await paywallViewController.info
      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .abandon(product),
        paywallInfo: paywallInfo,
        product: product,
        model: nil
      )
      await Superwall.shared.track(trackedEvent)
      await paywallViewController.webView.messageHandler.handle(.transactionAbandon)

      await MainActor.run {
        paywallViewController.loadingState = .ready
      }
    case .external:
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Abandoned",
        info: ["product_id": product.productIdentifier],
        error: nil
      )

      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .abandon(product),
        paywallInfo: .empty(),
        product: product,
        model: nil
      )
      await Superwall.shared.track(trackedEvent)
    }
  }

  private func handlePendingTransaction(purchaseSource: PurchaseSource) async {
    switch purchaseSource {
    case .internal(_, let paywallViewController):
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Pending",
        info: ["paywall_vc": paywallViewController],
        error: nil
      )

      let paywallInfo = await paywallViewController.info

      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .fail(.pending("Needs parental approval")),
        paywallInfo: paywallInfo,
        product: nil,
        model: nil
      )
      await Superwall.shared.track(trackedEvent)
      await paywallViewController.webView.messageHandler.handle(.transactionFail)
    case .external:
      Logger.debug(
        logLevel: .debug,
        scope: .paywallTransactions,
        message: "Transaction Pending",
        error: nil
      )

      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .fail(.pending("Needs parental approval")),
        paywallInfo: .empty(),
        product: nil,
        model: nil
      )
      await Superwall.shared.track(trackedEvent)
    }

    await presentAlert(
      title: "Waiting for Approval",
      message: "Thank you! This purchase is pending approval from your parent. Please try again once it is approved.",
      source: purchaseSource.toGenericSource()
    )
  }

  private func presentAlert(
    title: String,
    message: String,
    closeActionTitle: String? = nil,
    source: GenericSource
  ) async {
    switch source {
    case .internal(let paywallViewController):
      await paywallViewController.presentAlert(
        title: title,
        message: message,
        closeActionTitle: closeActionTitle ?? "Done"
      )
    case .external:
      guard let topMostViewController = await UIViewController.topMostViewController else {
        Logger.debug(
          logLevel: .error,
          scope: .paywallTransactions,
          message: "Could not find the top-most view controller to present a transaction alert from."
        )
        return
      }
      let alertController = await AlertControllerFactory.make(
        title: title,
        message: message,
        closeActionTitle: closeActionTitle ?? "Done",
        sourceView: topMostViewController.view
      )
      await topMostViewController.present(alertController, animated: true)
    }
  }

  func trackTransactionDidSucceed(
    _ transaction: StoreTransaction?,
    product: StoreProduct,
    purchaseSource: PurchaseSource,
    didStartFreeTrial: Bool
  ) async {
    switch purchaseSource {
    case .internal(_, let paywallViewController):
      let paywallShowingFreeTrial = await paywallViewController.paywall.isFreeTrialAvailable == true
      let didStartFreeTrial = product.hasFreeTrial && paywallShowingFreeTrial

      let paywallInfo = await paywallViewController.info

      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .complete(product, transaction),
        paywallInfo: paywallInfo,
        product: product,
        model: transaction
      )
      await Superwall.shared.track(trackedEvent)
      await paywallViewController.webView.messageHandler.handle(.transactionComplete)

      // Immediately flush the events queue on transaction complete.
      await eventsQueue.flushInternal()

      if product.subscriptionPeriod == nil {
        let trackedEvent = InternalSuperwallEvent.NonRecurringProductPurchase(
          paywallInfo: paywallInfo,
          product: product
        )
        await Superwall.shared.track(trackedEvent)
      } else {
        if didStartFreeTrial {
          let trackedEvent = InternalSuperwallEvent.FreeTrialStart(
            paywallInfo: paywallInfo,
            product: product
          )
          await Superwall.shared.track(trackedEvent)

          let notifications = paywallInfo.localNotifications.filter {
            $0.type == .trialStarted
          }

          await NotificationScheduler.scheduleNotifications(notifications, factory: factory)
        } else {
          let trackedEvent = InternalSuperwallEvent.SubscriptionStart(
            paywallInfo: paywallInfo,
            product: product
          )
          await Superwall.shared.track(trackedEvent)
        }
      }
    case .external:
      let trackedEvent = InternalSuperwallEvent.Transaction(
        state: .complete(product, transaction),
        paywallInfo: .empty(),
        product: product,
        model: transaction
      )
      await Superwall.shared.track(trackedEvent)

      // Immediately flush the events queue on transaction complete.
      await eventsQueue.flushInternal()

      if product.subscriptionPeriod == nil {
        let trackedEvent = InternalSuperwallEvent.NonRecurringProductPurchase(
          paywallInfo: .empty(),
          product: product
        )
        await Superwall.shared.track(trackedEvent)
      } else {
        if didStartFreeTrial {
          let trackedEvent = InternalSuperwallEvent.FreeTrialStart(
            paywallInfo: .empty(),
            product: product
          )
          await Superwall.shared.track(trackedEvent)
        } else {
          let trackedEvent = InternalSuperwallEvent.SubscriptionStart(
            paywallInfo: .empty(),
            product: product
          )
          await Superwall.shared.track(trackedEvent)
        }
      }
    }
  }
}
