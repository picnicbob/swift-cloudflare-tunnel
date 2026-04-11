# Spec: Extract Native Swift Cloudflare Tunnel Client into Standalone Library

## What This Is

This spec tells another Claude Code instance everything it needs to extract the native Swift Cloudflare Tunnel client from the PhoneServer project and turn it into a standalone, open-source Swift Package. The goal is a library that any Swift server (Vapor, Hummingbird, raw NIO, iOS app, macOS daemon) can use to expose itself via Cloudflare Tunnel without running `cloudflared`.

Nobody has built a native Swift replacement for `cloudflared`. The Go reference implementation is ~50,000 lines. Ours is ~2,000 lines of focused Swift that handles the QUIC connection, Cap'n Proto RPC registration, and HTTP request proxying. It works today inside PhoneServer. The job is to decouple it, clean it up, and package it.

## Name

**swift-cloudflare-tunnel**

- GitHub repo: `swift-cloudflare-tunnel`
- Swift package name: `swift-cloudflare-tunnel`
- Library/module name: `CloudflareTunnel` (what you `import`)
- Organization: `mrluker` (or a dedicated GitHub org if preferred)

## Source Files to Extract

All source lives in PhoneServer at:
```
Sources/PhoneServer/Core/Tunnel/
  CapnProto.swift              (~773 lines) - Cap'n Proto codec for tunnel RPC
  CloudflareAPI.swift          (~455 lines) - REST API client + config types
  CloudflareTunnelConnection.swift (~520 lines) - QUIC protocol handler
  TunnelManager.swift          (~384 lines) - Orchestration layer
  TunnelTypes.swift            (~70 lines)  - Status enums, TunnelInfo, TunnelError
```

Tests at:
```
Tests/PhoneServerTests/TunnelTests.swift (~200 lines, 28 tests across 7 suites)
```

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│                  Your App                         │
│                                                   │
│  1. Create TunnelManager                          │
│  2. Set request handler (you route HTTP yourself) │
│  3. Call startQuickTunnel() or setupNamedTunnel() │
│  4. Tunnel proxies internet traffic to your app   │
└────────────────┬─────────────────────────────────┘
                 │
    ┌────────────▼────────────┐
    │     TunnelManager       │  Orchestration: lifecycle, config, domains
    │     (public API)        │
    └────────────┬────────────┘
                 │
    ┌────────────▼────────────┐
    │  CloudflareTunnelConn   │  QUIC connection via Network.framework
    │  (protocol layer)       │  Cap'n Proto RPC registration handshake
    │                         │  Incoming data stream parsing + proxying
    └────────────┬────────────┘
                 │
    ┌────────────▼────────────┐
    │    CloudflareAPI        │  REST: token verify, tunnel CRUD, DNS, zones
    │    (HTTP client)        │  Edge IP discovery
    └────────────┬────────────┘
                 │
    ┌────────────▼────────────┐
    │    CapnProto            │  Minimal codec for tunnel RPC messages only
    │    (serialization)      │  NOT a general-purpose Cap'n Proto library
    └─────────────────────────┘
```

## Data Flow: Request Through Tunnel

```
User's browser -> Cloudflare CDN -> Cloudflare Edge
     -> QUIC data stream to phone/server
     -> CloudflareTunnelConnection.processDataStream()
     -> Parse Cap'n Proto ConnectRequest
     -> Call requestProxyHandler(TunnelConnectRequest, body) [YOUR CODE]
     -> Your app returns TunnelProxyResponse
     -> Build Cap'n Proto ConnectResponse
     -> Send over QUIC data stream
     -> Cloudflare Edge -> User's browser
```

## What Needs to Change During Extraction

### 1. Remove PhoneServer-Specific Coupling

**PSLogger references** - TunnelManager and CloudflareTunnelConnection use `PSLogger.tunnel`. Replace with:
- Swift's `os.Logger` directly, or
- A configurable logging delegate/closure, or
- Apple's `swift-log` package (common in server-side Swift)

Occurrences to replace:
- `TunnelManager.swift`: ~12 uses of `PSLogger.tunnel.info/error`
- `CloudflareTunnelConnection.swift`: ~15 uses of `PSLogger.tunnel.info/error/debug`

**`serviceId` concept** - `TunnelInfo` has a `serviceId: String` field. In PhoneServer this maps to a WordPress instance. In the standalone library, this should become a generic identifier that the consumer provides. The library doesn't need to know what's behind it. Keep the field but document it as "opaque identifier the caller uses to route requests."

**`DomainMapping.serviceId`** - Same idea. The library stores it but never interprets it.

**Tunnel name generation** - `TunnelManager.setupNamedTunnel` generates names like `phoneserver-{uuid}`. Change to a configurable parameter or use a generic prefix.

### 2. Public API Surface Design

The library should expose a clean public API. Here's the recommended structure:

```swift
// Primary entry point
public actor CloudflareTunnel {
    // Quick Tunnel (no account)
    public func startQuickTunnel() async throws -> QuickTunnelResult

    // Named Tunnel (with API token)
    public func setup(apiToken: String) async throws -> TunnelConfiguration
    public func addDomain(_ domain: String, routeIdentifier: String) async throws
    public func removeDomain(_ domain: String) async throws
    public func connect() async throws

    // Lifecycle
    public func disconnect() async
    public var isConnected: Bool { get async }
    public var status: TunnelStatus { get async }

    // Configuration
    public var configuration: TunnelConfiguration? { get async }

    // Request handling - consumer provides this
    public func setRequestHandler(
        _ handler: @escaping @Sendable (IncomingRequest, Data?) async -> ProxyResponse
    )

    // State observation
    public func setStateCallback(_ callback: @escaping @Sendable (ConnectionState) -> Void)
}
```

Rename some types for clarity outside PhoneServer context:
- `TunnelConnectRequest` -> `IncomingRequest` (or `TunnelRequest`)
- `TunnelProxyResponse` -> `ProxyResponse` (or `TunnelResponse`)
- `CloudflareConfig` -> `TunnelConfiguration`
- `TunnelInfo` -> `TunnelStatus` or `DomainStatus` (rename the existing `TunnelStatus` enum to `ConnectionStatus`)

### 3. Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-cloudflare-tunnel",
    platforms: [
        .iOS(.v15),      // Network.framework QUIC requires iOS 15+
        .macOS(.v12),    // Network.framework QUIC requires macOS 12+
        .tvOS(.v15),
    ],
    products: [
        .library(name: "CloudflareTunnel", targets: ["CloudflareTunnel"]),
    ],
    dependencies: [],  // Zero dependencies! Pure Foundation + Network.framework
    targets: [
        .target(
            name: "CloudflareTunnel",
            dependencies: [],
            path: "Sources/CloudflareTunnel"
        ),
        .testTarget(
            name: "CloudflareTunnelTests",
            dependencies: ["CloudflareTunnel"],
            path: "Tests/CloudflareTunnelTests"
        ),
    ]
)
```

Key point: **zero third-party dependencies**. The entire implementation uses only Foundation and Network.framework. This is a major selling point. Keep it that way.

### 4. File Organization for the New Package

```
swift-cloudflare-tunnel/
├── Package.swift
├── CLAUDE.md                           # Instructions for Claude Code working on this repo
├── README.md
├── LICENSE (MIT)
├── Sources/
│   └── CloudflareTunnel/
│       ├── CloudflareTunnel.swift          # Main public API (extracted from TunnelManager)
│       ├── Connection/
│       │   └── TunnelConnection.swift      # QUIC protocol (from CloudflareTunnelConnection)
│       ├── API/
│       │   └── CloudflareAPI.swift         # REST client (mostly unchanged)
│       ├── Protocol/
│       │   ├── CapnProto.swift             # Codec (unchanged)
│       │   └── RPCMessages.swift           # Could split builders out of CapnProto.swift
│       ├── Types/
│       │   ├── Configuration.swift         # CloudflareConfig -> TunnelConfiguration
│       │   ├── Credentials.swift           # TunnelCredentials (unchanged)
│       │   ├── Request.swift               # TunnelConnectRequest -> IncomingRequest
│       │   ├── Response.swift              # TunnelProxyResponse -> ProxyResponse
│       │   ├── Status.swift                # TunnelStatus, ConnectionState enums
│       │   └── Errors.swift                # All error types consolidated
│       └── Internal/
│           └── EdgeDiscovery.swift         # Edge IP resolution (from CloudflareAPI)
├── Tests/
│   └── CloudflareTunnelTests/
│       ├── CapnProtoTests.swift
│       ├── ConfigurationTests.swift
│       ├── ConnectionTests.swift
│       ├── APITests.swift
│       └── IntegrationTests.swift          # Quick Tunnel end-to-end (needs network)
└── Examples/
    ├── QuickTunnelExample/                 # Minimal: expose a local HTTP server
    │   ├── Package.swift
    │   └── main.swift
    └── NamedTunnelExample/                 # Full: API token, custom domain, auto-reconnect
        ├── Package.swift
        └── main.swift
```

### 5. Specific Code Changes Per File

#### CapnProto.swift
- **Change nothing** in the codec logic. It works.
- Remove any PhoneServer imports if present (there are none currently).
- Consider splitting `TunnelRPCBuilder` and `DataStreamBuilder` into a separate `RPCMessages.swift` for clarity, but this is optional.
- The `CloudflareRPC` constants enum stays as-is.

#### CloudflareAPI.swift
- Remove `PSLogger` references (there are none currently; this file is already clean).
- `CloudflareConfig` gets renamed to `TunnelConfiguration`.
- `DomainMapping.serviceId` becomes `DomainMapping.routeIdentifier` (or keep `serviceId` and document it as caller-defined).
- `UserAgent` string: change from `"PhoneServer/1.0"` to the library name.
- `discoverEdgeIPs()` could move to its own file for organization.
- All the REST API methods stay the same. They're already generic.

#### CloudflareTunnelConnection.swift
- Replace all `PSLogger.tunnel` calls with the chosen logging approach.
- The `import os` at the top stays (for `os.Logger` or similar).
- This file is already fully decoupled from PhoneServer. The only external dependency is `CloudflareAPI.discoverEdgeIPs()` for edge address resolution.
- Rename: `CloudflareTunnelConnection` -> `TunnelConnection` (shorter, since it's already in the `CloudflareTunnel` module namespace).

#### TunnelManager.swift -> CloudflareTunnel.swift
- This is the primary refactoring target. Rename `TunnelManager` -> `CloudflareTunnel` (the main public API type).
- Replace `PSLogger.tunnel` with the chosen logging approach.
- Change tunnel name generation: `"phoneserver-..."` -> configurable prefix or `"swift-tunnel-..."`.
- The `syncIngressRules()` method hardcodes `"http://localhost:8080"` as the service URL. This should come from the caller's configuration, not be hardcoded. Pass it through `DomainMapping` or a new field.
- `TunnelInfo` cleanup: `serviceId` -> `routeIdentifier`, `localPort` might not be needed (the library doesn't know what port the local service runs on; that's the caller's business).

#### TunnelTypes.swift
- Consolidate into `Types/Status.swift` and `Types/Errors.swift`.
- Remove `TunnelMode.companion` and `.native` since in the standalone library, native is the only mode.
- `TunnelError.companionUnreachable` goes away.

### 6. Ingress Rule Hardcoding Fix

Currently in `TunnelManager.syncIngressRules()`:
```swift
IngressRule(hostname: mapping.domain, service: "http://localhost:8080")
```

This is wrong for a general library. The service URL should be configurable per domain. Options:
1. Add `localServiceURL: String` to `DomainMapping` (simplest)
2. Let the caller set a default service URL on the tunnel config
3. Both (per-domain override, with a default fallback)

Recommended: option 3. Add `serviceURL` to `DomainMapping` defaulting to `"http://localhost:8080"`, and add `defaultServiceURL` to `TunnelConfiguration`.

### 7. Logging Strategy

Recommended approach for an open-source library:

```swift
public protocol TunnelLogger: Sendable {
    func info(_ message: String)
    func error(_ message: String)
    func debug(_ message: String)
}

// Default: os.Logger
public struct OSLogTunnelLogger: TunnelLogger {
    private let logger = Logger(subsystem: "com.cloudflare.tunnel", category: "tunnel")
    public func info(_ message: String) { logger.info("\(message)") }
    public func error(_ message: String) { logger.error("\(message)") }
    public func debug(_ message: String) { logger.debug("\(message)") }
}
```

Pass the logger into `CloudflareTunnel.init(logger:)`. Default to `OSLogTunnelLogger`. Users of swift-log can write a 5-line adapter.

## Protocol Constants Reference

These are hardcoded in the Cloudflare tunnel protocol. Do NOT change them:

| Constant | Value | Purpose |
|----------|-------|---------|
| QUIC ALPN | `["argotunnel"]` | Cloudflare QUIC protocol identifier |
| TLS SNI | `quic.cftunnel.com` | Cloudflare tunnel endpoint |
| Edge port | `7844` | QUIC connection port |
| RPC stream signature | `0x52BB825CDCDB65` | Control stream identifier |
| Data stream signature | `0x0A36CD12A13E` | Data stream identifier |
| Protocol version | `"01"` (ASCII `0x30 0x31`) | RPC protocol version |
| Registration interface | `0xf71695ec7fe85497` | Cap'n Proto interface ID |
| registerConnection method | `0` | RPC method index |
| unregisterConnection method | `1` | RPC method index |
| Message types | call=2, return=3, finish=4, bootstrap=8 | Cap'n Proto RPC message types |
| Idle timeout | 30 seconds | QUIC connection keepalive |
| Max reconnect attempts | 10 | Exponential backoff limit |
| Backoff schedule | 1,2,4,8,16,32,60s | Reconnection delays (capped at 60s) |
| Client features | `["serialized_headers"]` | Registration capability |

## Registration Handshake (6 Steps)

This is the core of the tunnel protocol. Do not modify the sequence:

1. Send RPC stream signature (`0x52BB825CDCDB65`) + version (`"01"`)
2. Send Bootstrap RPC call (Cap'n Proto message type 8)
3. Receive Bootstrap return (message type 3) -- extracts interface capability
4. Send Finish for Bootstrap (message type 4)
5. Send RegisterConnection RPC call (message type 2) with:
   - `TunnelCredentials` (account tag, tunnel secret, tunnel ID)
   - `connIndex` (0 for first connection)
   - `clientId` (random 16 bytes)
   - `features` array (["serialized_headers"])
   - `version` string ("2024.1.0")
   - `arch` string ("darwin_arm64")
6. Receive RegisterConnection return -- parse for `ConnectionRegistrationResult` or error
7. Send Finish for registration
8. Keep control stream alive (monitor for disconnection)

## Data Stream Protocol

Incoming QUIC data streams (HTTP requests from the internet):

1. Cloudflare sends: data signature (`0x0A36CD12A13E`) + Cap'n Proto `ConnectRequest`
2. Parse request: extract `dest`, `type` (HTTP/WS/TCP), metadata (HTTP method, host, headers)
3. Read optional body from stream
4. Call the consumer's `requestHandler(request, body)`
5. Consumer returns `ProxyResponse(statusCode, headers, body)`
6. Write back: data signature + Cap'n Proto `ConnectResponse` (status + headers)
7. Write response body
8. Close stream

## Testing Strategy

### Unit Tests (no network required)
- Cap'n Proto message building and parsing (serialization correctness)
- Configuration codable round-trips
- Error type descriptions
- Credential construction
- Edge address parsing
- ConnectRequest/ConnectResponse building
- Status enum transitions

### Integration Tests (require network, mark as such)
- Quick Tunnel: create, connect, verify hostname returned
- Token verification: valid/invalid token handling
- Named Tunnel: create, configure ingress, connect, add domain
- Request proxying end-to-end: tunnel receives request, handler returns response
- Reconnection: simulate disconnect, verify exponential backoff
- Clean shutdown: disconnect, verify resources released

Mark integration tests with a custom trait or skip flag so CI can run unit tests without Cloudflare credentials.

## Example Usage (What the README Should Show)

### Quick Tunnel (Zero Config)

```swift
import CloudflareTunnel

let tunnel = CloudflareTunnel()

// Handle incoming HTTP requests from the tunnel
tunnel.setRequestHandler { request, body in
    // Route to your local HTTP server
    let response = try await myServer.handle(request.method, path: request.dest, headers: request.headers, body: body)
    return ProxyResponse(statusCode: response.status, headers: response.headers, body: response.body)
}

// Get a temporary public URL instantly
let result = try await tunnel.startQuickTunnel()
print("Your site is live at: https://\(result.hostname)")
// e.g., https://random-word-random-word.trycloudflare.com
```

### Named Tunnel (Custom Domain)

```swift
import CloudflareTunnel

let tunnel = CloudflareTunnel()

tunnel.setRequestHandler { request, body in
    return try await myServer.handle(request)
}

// One-time setup (persisted by your app)
let config = try await tunnel.setup(apiToken: "your-cf-api-token")

// Add your domain
try await tunnel.addDomain("mysite.com", routeIdentifier: "main")

// Connect (call on every app launch)
try await tunnel.connect()

// Observe state changes
tunnel.setStateCallback { state in
    switch state {
    case .connected(let location):
        print("Connected via \(location)")
    case .reconnecting(let attempt):
        print("Reconnecting (attempt \(attempt))...")
    case .failed(let error):
        print("Failed: \(error)")
    default: break
    }
}
```

### With Vapor

```swift
import Vapor
import CloudflareTunnel

let app = try Application(.detect())
// ... configure Vapor routes ...

let tunnel = CloudflareTunnel()
tunnel.setRequestHandler { request, body in
    // Forward to Vapor's local server
    let url = URL(string: "http://localhost:8080\(request.dest)")!
    var req = URLRequest(url: url)
    req.httpMethod = request.method
    for (name, value) in request.headers {
        req.setValue(value, forHTTPHeaderField: name)
    }
    req.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: req)
    let httpResp = response as! HTTPURLResponse
    return ProxyResponse(statusCode: httpResp.statusCode, headers: [], body: data)
}

let result = try await tunnel.startQuickTunnel()
app.logger.info("Public URL: https://\(result.hostname)")

try app.run()
```

## What NOT to Include

- PhoneServer's `AppState`, `ServiceManager`, `WordPressService`, or any UI code
- The `PSLogger` system
- `ServiceTypes.swift` (except the tunnel-related types already in the tunnel files)
- Dashboard/onboarding/backup code
- Any reference to WordPress, PHP-WASM, or site management

## Platform Requirements

- **iOS 15+** / **macOS 12+** (Network.framework QUIC support)
- **Swift 5.9+** (structured concurrency, actors)
- No Objective-C bridging needed
- No third-party dependencies
- Works with Swift Package Manager (primary), CocoaPods/Carthage support optional

## License

MIT. The tunnel protocol is documented by Cloudflare (open source `cloudflared` is Apache 2.0). Our implementation is clean-room Swift code, not a port of the Go code.

## Decisions (Already Made)

1. **Name**: `swift-cloudflare-tunnel` (repo), `CloudflareTunnel` (module import)
2. **Logging**: Protocol-based injection with `os.Logger` default. Most flexible for a library.
3. **Config persistence**: Leave entirely to the consumer. Provide `Codable` conformance so they can serialize however they want.
4. **Multi-connection**: Start with 1 QUIC connection. Document multi-connection (cloudflared uses 4) as a future enhancement.
5. **WebSocket/TCP tunneling**: Add pass-through support for WebSocket and TCP alongside HTTP.

## Verification

After extraction, verify:
1. `swift build` succeeds with zero warnings
2. `swift test` passes all unit tests
3. Quick Tunnel example creates a working public URL
4. Named Tunnel example with a real domain serves HTTP
5. Reconnection works after network interruption
6. Clean shutdown releases all resources
7. No PhoneServer types remain in the public API
