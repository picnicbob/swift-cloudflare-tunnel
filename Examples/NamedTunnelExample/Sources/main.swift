import CloudflareTunnel
import Foundation

// Named Tunnel Example
//
// Creates a persistent tunnel with a custom domain.
// Requires a Cloudflare API token and a domain managed by Cloudflare.
//
// Environment variables:
//   CF_API_TOKEN  - Your Cloudflare API token
//   CF_DOMAIN     - The domain to tunnel (e.g., "app.example.com")
//   CF_ORIGIN     - (Optional) Local origin to proxy to (e.g., "http://localhost:3000")
//   CF_CONNECTIONS - (Optional) Number of edge connections (default: 4)
//
// Usage:
//   CF_API_TOKEN=xxx CF_DOMAIN=app.example.com swift run NamedTunnelExample
//   CF_API_TOKEN=xxx CF_DOMAIN=app.example.com CF_ORIGIN=http://localhost:3000 swift run NamedTunnelExample

guard let apiToken = ProcessInfo.processInfo.environment["CF_API_TOKEN"] else {
    print("Error: Set CF_API_TOKEN environment variable")
    print("Usage: CF_API_TOKEN=xxx CF_DOMAIN=app.example.com swift run NamedTunnelExample")
    exit(1)
}

guard let domain = ProcessInfo.processInfo.environment["CF_DOMAIN"] else {
    print("Error: Set CF_DOMAIN environment variable")
    print("Usage: CF_API_TOKEN=xxx CF_DOMAIN=app.example.com swift run NamedTunnelExample")
    exit(1)
}

let originURL = ProcessInfo.processInfo.environment["CF_ORIGIN"]
let connCount = ProcessInfo.processInfo.environment["CF_CONNECTIONS"].flatMap(UInt8.init) ?? 4

let tunnel = CloudflareTunnel(connectionCount: connCount)

if let originURL {
    // Origin proxy mode: forward to a local HTTP server
    try await tunnel.setOriginURL(originURL)
    print("Proxying to \(originURL)")
} else {
    // In-process handler mode
    await tunnel.setRequestHandler { request, body in
        print("[\(request.method)] \(request.host)\(request.dest)")

        let json = """
        {"message": "Hello from Swift!", "path": "\(request.dest)", "method": "\(request.method)"}
        """

        return ProxyResponse(
            statusCode: 200,
            headers: [("Content-Type", "application/json")],
            body: Data(json.utf8)
        )
    }
}

// Observe state changes
await tunnel.setStateCallback { state in
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

// Set up the named tunnel
print("Setting up named tunnel with \(connCount) edge connections...")
let config = try await tunnel.setup(apiToken: apiToken)
print("Tunnel created: \(config.tunnelName ?? "unknown")")

// Add domain
print("Adding domain: \(domain)...")
try await tunnel.addDomain(domain, routeIdentifier: "main")

// Connect
print("Connecting...")
try await tunnel.connect()

print("")
print("========================================")
print("  Your site is live at: https://\(domain)")
print("  Edge connections: \(connCount)")
print("========================================")
print("")
print("Press Ctrl+C to stop.")

// Graceful shutdown on Ctrl+C
let shutdownTunnel = tunnel
signal(SIGINT) { _ in
    print("\nShutting down gracefully...")
    Task {
        await shutdownTunnel.disconnect()
        exit(0)
    }
}
dispatchMain()
