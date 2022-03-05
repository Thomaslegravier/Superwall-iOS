//
//  Network2.swift
//  Paywall
//
//  Created by Yusuf Tör on 04/03/2022.
//

import Foundation


final class Network2 {
  static let shared = Network2()
  private let urlSession = URLSession(configuration: .ephemeral)
  enum NetworkError: LocalizedError {
    case unknown
    case notAuthenticated
    case decoding
    case notFound
    case invalidUrl

    var errorDescription: String? {
      switch self {
      case .unknown: return NSLocalizedString("An unknown error occurred.", comment: "")
      case .notAuthenticated: return NSLocalizedString("Unauthorized.", comment: "")
      case .decoding: return NSLocalizedString("Decoding error.", comment: "")
      case .notFound: return NSLocalizedString("Not found", comment: "")
      case .invalidUrl: return NSLocalizedString("URL invalid", comment: "")
      }
    }
  }

  private init() {}

  func send<Response>(
    _ endpoint: Endpoint<Response>,
    isForDebugging: Bool = false,
    completion: @escaping (Result<Response, Error>) -> Void
  ) {
    guard let request = endpoint.makeRequest(forDebugging: isForDebugging) else {
      //TODO: Add logging here
      return completion(.failure(NetworkError.invalidUrl))
    }

    Logger.debug(
      logLevel: .debug,
      scope: .network,
      message: "Request Started",
      info: [
        "body": String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "none",
        "url": request.url?.absoluteString ?? "unknown"
      ]
    )

    let startTime = Date().timeIntervalSince1970
    
    let task = urlSession.dataTask(with: request) { data, response, error in
      let requestDuration = Date().timeIntervalSince1970 - startTime

      do {
        guard let data = data else {
          return completion(.failure(error ?? NetworkError.unknown))
        }
        var requestId = "unknown"

        if let response = response as? HTTPURLResponse,
          let rid = response.allHeaderFields["x-request-id"] as? String {
          requestId = rid
        }

        if let response = response as? HTTPURLResponse {
          if response.statusCode == 401 {
            Logger.debug(
              logLevel: .error,
              scope: .network,
              message: "Unable to Authenticate",
              info: [
                "request": request.debugDescription,
                "api_key": auth,
                "url": request.url?.absoluteString ?? "unknown",
                "request_id": requestId,
                "request_duration": requestDuration
              ],
              error: error
            )
            return completion(.failure(NetworkError.notAuthenticated))
          }

          if response.statusCode == 404 {
            Logger.debug(
              logLevel: .error,
              scope: .network,
              message: "Not Found",
              info: [
                "request": request.debugDescription,
                "api_key": auth,
                "url": request.url?.absoluteString ?? "unknown",
                "request_id": requestId,
                "request_duration": requestDuration
              ],
              error: error
            )
            return completion(.failure(NetworkError.notFound))
          }
        }

        Logger.debug(
          logLevel: .debug,
          scope: .network,
          message: "Request Completed",
          info: [
            "request": request.debugDescription,
            "api_key": auth,
            "url": request.url?.absoluteString ?? "unknown",
            "request_id": requestId,
            "request_duration": requestDuration
          ]
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        completion(.success(response))
      } catch {
        Logger.debug(
          logLevel: .error,
          scope: .network,
          message: "Request Error",
          info: [
            "request": request.debugDescription,
            "api_key": auth,
            "url": request.url?.absoluteString ?? "unknown",
            "message": "Unable to decode response to type \(Response.self)",
            "info": String(decoding: data ?? Data(), as: UTF8.self),
            "request_duration": requestDuration
          ],
          error: error
        )
        completion(.failure(NetworkError.decoding))
      }
    }
    task.resume()
  }
}