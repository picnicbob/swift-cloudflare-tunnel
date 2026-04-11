# swift-cloudflare-tunnel

Native Swift client for [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/). Expose any Swift server or app to the internet without running `cloudflared`.

~2,000 lines of Swift. Zero dependencies. Just Foundation + Network.framework.

## What This Does

Cloudflare Tunnel lets you expose a local server to the internet through Cloudflare's network. Normally you need to run the `cloudflared` binary (written in Go, ~50,000 lines) alongside your app. This library replaces `cloudflared` with a native Swift implementation that connects directly to Cloudflare's edge using QUIC.

Works with any Swift server: Vapor, Hummingbird, raw NIO, or just a closure that returns HTTP responses. Also works on iOS and macOS for exposing mobile services.

## Features

- **Quick Tunnel**: Get a public URL in one function call, no account needed
- **Named Tunnel**: Persistent custom domains with Cloudflare API token
- **Native QUIC**: Uses Network.framework, no C dependencies
- **Zero dependencies**: Pure Foundation + Network.framework
- **Actor-based**: Full Swift concurrency support
- **Automatic reconnection**: Exponential backoff on disconnect
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
tunnel.setRequestHandler { request, body in
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

### Named Tunnel (Custom Domain)

```swift
import CloudflareTunnel

let tunnel = CloudflareTunnel()

tunnel.setRequestHandler { request, body in
    return try await myServer.handle(request)
}

// One-time setup (persist the returned config)
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
    // Forward tunnel requests to Vapor's local server
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
TunnelConnection (actor)        -- QUIC via Network.framework, Cap'n Proto RPC
  |
  v
CloudflareAPI (actor)           -- REST: token verify, tunnel CRUD, DNS, zones
  |
  v
CapnProto (internal)            -- Minimal codec for tunnel RPC messages only
```

### How It Works

1. Your app creates a `CloudflareTunnel` and sets a request handler
2. The library opens a QUIC connection to Cloudflare's edge (port 7844)
3. It performs a Cap'n Proto RPC handshake to register the tunnel
4. Cloudflare routes incoming HTTP requests as QUIC data streams
5. Each stream is parsed and forwarded to your request handler
6. Your handler returns a response, which is sent back through the tunnel

## API Reference

### CloudflareTunnel

The main entry point. An actor that manages the tunnel lifecycle.

| Method | Description |
|--------|-------------|
| `startQuickTunnel()` | Get a temporary trycloudflare.com URL |
| `setup(apiToken:)` | Set up a named tunnel with API token |
| `addDomain(_:routeIdentifier:serviceURL:)` | Add a custom domain |
| `removeDomain(_:)` | Remove a custom domain |
| `connect()` | Connect the named tunnel |
| `disconnect()` | Disconnect all tunnels |
| `disconnect(domain:)` | Disconnect a specific domain |
| `isConnected()` | Check connection status |
| `setRequestHandler(_:)` | Set the HTTP request handler |
| `setStateCallback(_:)` | Observe connection state changes |
| `configure(with:)` | Load persisted configuration |
| `restoreFromConfig()` | Reconnect from persisted config |

### Key Types

| Type | Description |
|------|-------------|
| `IncomingRequest` | Parsed HTTP request from the tunnel |
| `ProxyResponse` | HTTP response to send back |
| `TunnelConfiguration` | Codable tunnel config for persistence |
| `TunnelCredentials` | Codable tunnel credentials |
| `ConnectionState` | Detailed connection state (for callbacks) |
| `ConnectionStatus` | Simple status enum (for persistence) |
| `DomainStatus` | Per-domain status information |
| `QuickTunnelResult` | Result from quick tunnel creation |

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

- **QuickTunnelExample**: Minimal quick tunnel that serves HTML
- **NamedTunnelExample**: Named tunnel with custom domain via env vars

Run an example:
```bash
cd Examples/QuickTunnelExample
swift run
```

## Protocol Details

This library implements the Cloudflare Tunnel protocol natively:

- **QUIC ALPN**: `argotunnel`
- **Edge port**: 7844
- **TLS SNI**: `quic.cftunnel.com`
- **Registration**: Cap'n Proto RPC over the first QUIC bidirectional stream
- **Data streams**: Cap'n Proto ConnectRequest/ConnectResponse per QUIC stream
- **Reconnection**: Exponential backoff (1s, 2s, 4s ... 60s max, 10 attempts)

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
