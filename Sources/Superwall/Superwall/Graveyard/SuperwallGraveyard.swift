//
//  File.swift
//  
//
//  Created by Yusuf Tör on 04/10/2022.
//

import UIKit

public extension Superwall {
  // MARK: - Unavailable methods
  @available(*, unavailable, renamed: "configure(apiKey:delegate:options:)")
  @discardableResult
  static func configure(
    apiKey: String,
    userId: String?,
    delegate: SuperwallDelegate? = nil,
    options: SuperwallOptions? = nil
  ) -> Superwall {
    return shared
  }

  @available(*, unavailable, renamed: "configure(apiKey:delegate:options:)")
  @discardableResult
  @objc static func configure(
    apiKey: String,
    userId: String?,
    delegate: SuperwallDelegateObjc? = nil,
    options: SuperwallOptions? = nil
  ) -> Superwall {
    return shared
  }

  @available(*, unavailable, message: "Please use login(userId:) or createAccount(userId:).")
  @discardableResult
  @objc static func identify(userId: String) -> Superwall {
    return shared
  }

  @available(*, unavailable, renamed: "preloadPaywalls(forEvents:)")
  @objc static func preloadPaywalls(forTriggers triggers: Set<String>) {}

  @available(*, unavailable, renamed: "track(event:params:paywallOverrides:paywallState:)")
  @objc static func trigger(
    event: String? = nil,
    params: [String: Any]? = nil,
    on viewController: UIViewController? = nil,
    ignoreSubscriptionStatus: Bool = false,
    presentationStyleOverride: PaywallPresentationStyle = .none,
    onSkip: ((NSError?) -> Void)? = nil,
    onPresent: ((PaywallInfo) -> Void)? = nil,
    onDismiss: ((Bool, String?, PaywallInfo) -> Void)? = nil
  ) {}

  @available(*, unavailable, renamed: "track(event:params:)")
  @objc static func track(
    _ name: String,
    _ params: [String: Any] = [:]
  ) {}

  @available(*, unavailable, renamed: "SuperwallEvent")
  enum EventName: String {
    case fakeCase = "fake"
  }
}
