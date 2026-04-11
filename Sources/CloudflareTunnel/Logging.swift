import Foundation
import os

/// Protocol for tunnel logging. Implement this to integrate with your app's logging system.
///
/// The library ships with ``OSLogTunnelLogger`` as the default. Users of swift-log
/// or other frameworks can write a simple adapter conforming to this protocol.
public protocol TunnelLogger: Sendable {
    func info(_ message: String)
    func error(_ message: String)
    func debug(_ message: String)
    func warning(_ message: String)
}

/// Default logger using Apple's `os.Logger`.
public struct OSLogTunnelLogger: TunnelLogger, Sendable {
    private let logger: os.Logger

    public init(subsystem: String = "com.cloudflare.tunnel", category: String = "tunnel") {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func info(_ message: String) { logger.info("\(message)") }
    public func error(_ message: String) { logger.error("\(message)") }
    public func debug(_ message: String) { logger.debug("\(message)") }
    public func warning(_ message: String) { logger.warning("\(message)") }
}
