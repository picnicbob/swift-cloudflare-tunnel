import CloudflareTunnel
import Foundation

// Named Tunnel Example
//
// Creates a persistent tunnel with a custom domain.
// Requires a Cloudflare API token and a domain managed by Cloudflare.
//
// Set environment variables:
//   CF_API_TOKEN  - Your Cloudflare API token
//   CF_DOMAIN     - The domain to tunnel (e.g., "app.example.com")
//
// Run: CF_API_TOKEN=xxx CF_DOMAIN=app.example.com swift run NamedTunnelExample

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

let tunnel = CloudflareTunnel()

// Handle incoming HTTP requests
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
print("Setting up named tunnel...")
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
print("========================================")
print("")
print("Press Ctrl+C to stop.")

// Keep running until interrupted
signal(SIGINT) { _ in
    print("\nShutting down...")
    exit(0)
}
dispatchMain()
