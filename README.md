# swift-cloudflare-tunnel

Native Swift client for [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/). Expose any Swift server or app to the internet without running `cloudflared`.

~2,700 lines of Swift. Zero dependencies. Just Foundation + Network.framework.

## What This Does

Cloudflare Tunnel lets you expose a local server to the internet through Cloudflare's network. Normally you need to run the `cloudflared` binary (written in Go, ~50,000 lines) alongside your app. This library replaces `cloudflared` with a native Swift implementation that connects directly to Cloudflare's edge using QUIC.

Works with any Swift server: Vapor, Hummingbird, raw NIO, or just a closure that returns HTTP responses. Also works on iOS and macOS for exposing mobile services.

## Features

- **Quick Tunnel**: Get a public URL in one function call, no account needed
- **Named Tunnel**: Persistent custom domains with Cloudflare API token
- **Native QUIC**: Uses Network.framework, no C dependencies
- **Zero dependencies**: Pure Foundation + Network.framework
- **Connection multiplexing**: 4 redundant QUIC connections to Cloudflare edge
- **Origin HTTP proxying**: Forward requests to a local server automatically
- **WebSocket/TCP streaming**: Bidirectional relay for persistent connections
- **Streaming bodies**: Handles request/response bodies up to 10 MB
- **Graceful disconnect**: Sends UnregisterConnection RPC before closing
- **Actor-based**: Full Swift concurrency support
- **Automatic reconnection**: Per-connection exponential backoff
- **DNS SRV discovery**: Dynamic edge server discovery with static fallback
- **Pluggable logging**: Protocol-based, ships with `os.Logger` default
- **Configurable ingress**: Per-domain service URLs
- **Codable configuration**: Serialize and persist tunnel config easily

## Requirements

- **iOS 15+** / **macOS 12+** / **tvOS 15+**
- **Swift 5.9+**
- No third-party dependencies

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mrluker/swift-cloudflare-tunnel.git", from: "0.1.0"),
]
```

Then add `CloudflareTunnel` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "CloudflareTunnel", package: "swift-cloudflare-tunnel"),
    ]
),
```

## Quick Start

### Quick Tunnel (Zero Config)

```swift
import CloudflareTunnel

let tunnel = CloudflareTunnel()

// Handle incoming HTTP requests
await tunnel.setRequestHandler { request, body in
    return ProxyResponse(
        statusCode: 200,
        headers: [("Content-Type", "text/plain")],
        body: Data("Hello from Swift!".utf8)
    )
}

// Get a temporary public URL instantly
let result = try await tunnel.startQuickTunnel()
print("Live at: \(result.url)")
// e.g., https://random-word-random-word.trycloudflare.com
```

### Origin Proxy (Forward to Local Server)

The simplest mode: forward all tunnel traffic to a local HTTP server, just like `cloudflared`.

```swift
let tunnel = CloudflareTunnel()

// Forward everything to localhost:3000
try await tunnel.setOriginURL("http://localhost:3000")

let result = try await tunnel.startQuickTunnel()
print("Proxying to localhost:3000 at: \(result.url)")
```

Per-domain routing is supported via `DomainMapping.serviceURL` for named tunnels.

### Named Tunnel (Custom Domain)

```swift
let tunnel = CloudflareTunnel()

await tunnel.setRequestHandler { request, body in
    return try await myServer.handle(request)
}

// One-time setup (persist the returned config)
let config = try await tunnel.setup(apiToken: "your-cf-api-token")

// Add your domain
try await tunnel.addDomain("mysite.com", routeIdentifier: "main")

// Connect (call on every app launch)
try await tunnel.connect()
```

### WebSocket/TCP Streaming

For persistent bidirectional connections (WebSocket, TCP), set a stream handler:

```swift
await tunnel.setStreamHandler { request in
    print("New \(request.connectionType) connection to \(request.dest)")

    let session = StreamSession(
        initialResponse: ProxyResponse(
            statusCode: 101,
            headers: [("Upgrade", "websocket")],
            body: Data()
        ),
        onData: { data in
            // Data received from the client
            print("Received \(data.count) bytes")
            // Echo it back:
            session.send(data)
        },
        onClose: {
            print("Client disconnected")
        }
    )
    return session
}
```

If no stream handler is set, WebSocket/TCP connections fall through to the regular request handler as one-shot exchanges.

### Connection Multiplexing

The tunnel opens 4 redundant QUIC connections to Cloudflare's edge by default, alternating across regions. The tunnel stays up as long as any single connection is healthy.

```swift
// Customize the number of edge connections
let tunnel = CloudflareTunnel(connectionCount: 2)  // Use 2 instead of 4
```

### With Vapor

```swift
import Vapor
import CloudflareTunnel

let app = try Application(.detect())
// ... configure Vapor routes ...

let tunnel = CloudflareTunnel()

// Use origin proxy mode to forward to Vapor's local server
try await tunnel.setOriginURL("http://localhost:8080")

let result = try await tunnel.startQuickTunnel()
app.logger.info("Public URL: \(result.url)")

try app.run()
```

## Architecture

```
Your App
  |
  v
CloudflareTunnel (actor)        -- Public API: lifecycle, config, domains
  |
  v
TunnelConnection x4 (actor)    -- QUIC via Network.framework, Cap'n Proto RPC
  |                                (4 connections to different edge regions)
  v
CloudflareAPI (actor)           -- REST: token verify, tunnel CRUD, DNS, zones
  |
  v
CapnProto (internal)            -- Minimal codec for tunnel RPC messages only
```

### How It Works

1. Your app creates a `CloudflareTunnel` and sets a request handler (or origin URL)
2. The library opens 4 QUIC connections to Cloudflare's edge (port 7844), alternating across regions
3. Each connection performs a Cap'n Proto RPC handshake to register
4. Cloudflare routes incoming HTTP requests as QUIC data streams
5. HTTP requests are dispatched to your handler; WebSocket/TCP use the bidirectional relay
6. On disconnect, an UnregisterConnection RPC notifies the edge of graceful departure

## API Reference

### CloudflareTunnel

The main entry point. An actor that manages the tunnel lifecycle.

| Method | Description |
|--------|-------------|
| `init(connectionCount:)` | Create with custom edge connection count (default 4) |
| `startQuickTunnel()` | Get a temporary trycloudflare.com URL |
| `setup(apiToken:)` | Set up a named tunnel with API token |
| `addDomain(_:routeIdentifier:serviceURL:)` | Add a custom domain |
| `removeDomain(_:)` | Remove a custom domain |
| `connect()` | Connect the named tunnel |
| `disconnect()` | Disconnect all tunnels (graceful unregister) |
| `disconnect(domain:)` | Disconnect a specific domain |
| `isConnected()` | Check connection status |
| `setRequestHandler(_:)` | Set the HTTP request handler |
| `setStreamHandler(_:)` | Set the WebSocket/TCP stream handler |
| `setOriginURL(_:)` | Set origin URL for automatic HTTP proxying |
| `setStateCallback(_:)` | Observe connection state changes |
| `configure(with:)` | Load persisted configuration |
| `restoreFromConfig()` | Reconnect from persisted config |

### Key Types

| Type | Description |
|------|-------------|
| `IncomingRequest` | Parsed HTTP request with `.connectionType` (.http, .websocket, .tcp) |
| `ProxyResponse` | HTTP response to send back |
| `StreamSession` | Bidirectional stream for WebSocket/TCP connections |
| `TunnelConfiguration` | Codable tunnel config for persistence |
| `TunnelCredentials` | Codable tunnel credentials |
| `ConnectionState` | Detailed connection state (for callbacks) |
| `DomainStatus` | Per-domain status information |
| `QuickTunnelResult` | Result from quick tunnel creation |

### StreamSession

Manages a bidirectional data relay for WebSocket/TCP connections.

| Member | Description |
|--------|-------------|
| `initialResponse` | HTTP response sent before the relay starts |
| `send(_:)` | Send data to the client (origin -> client) |
| `close()` | Close the outbound direction |
| `onData` callback | Called when data arrives from the client |
| `onClose` callback | Called when the client closes the connection |

### Custom Logging

```swift
struct MyLogger: TunnelLogger {
    func info(_ message: String) { /* your logging */ }
    func error(_ message: String) { /* your logging */ }
    func debug(_ message: String) { /* your logging */ }
    func warning(_ message: String) { /* your logging */ }
}

let tunnel = CloudflareTunnel(logger: MyLogger())
```

## Examples

See the `Examples/` directory:

- **QuickTunnelExample**: Quick tunnel with in-process handler or origin proxy mode
- **NamedTunnelExample**: Named tunnel with custom domain, origin proxy, and configurable connection count

Run an example:
```bash
cd Examples/QuickTunnelExample
swift run                          # In-process handler
swift run QuickTunnelExample --origin 8080  # Proxy to localhost:8080
```

## Protocol Details

This library implements the Cloudflare Tunnel protocol natively:

- **QUIC ALPN**: `argotunnel`
- **Edge port**: 7844
- **TLS SNI**: `quic.cftunnel.com`
- **Edge discovery**: DNS SRV lookup (`_v2-origintunneld._tcp.argotunnel.com`) with static fallback
- **Registration**: Cap'n Proto RPC over the first QUIC bidirectional stream
- **Unregistration**: Cap'n Proto RPC on graceful disconnect
- **Data streams**: Cap'n Proto ConnectRequest/ConnectResponse per QUIC stream
- **Multiplexing**: 4 concurrent QUIC connections across 2 edge regions
- **Reconnection**: Per-connection exponential backoff (1s, 2s, 4s ... 60s max, 10 attempts)

The implementation is clean-room Swift code, not a port of the Go `cloudflared`.

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

### Development

```bash
git clone https://github.com/mrluker/swift-cloudflare-tunnel.git
cd swift-cloudflare-tunnel
swift build
swift test
```

## Authors

- **Luke Riley** ([@mrluker](https://github.com/mrluker))
- **Claude** (Anthropic)

## License

MIT. See [LICENSE](LICENSE) for details.
