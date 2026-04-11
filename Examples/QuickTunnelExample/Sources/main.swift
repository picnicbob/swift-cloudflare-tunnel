import CloudflareTunnel
import Foundation

// Quick Tunnel Example
//
// Creates a temporary public URL via trycloudflare.com.
// No Cloudflare account or API token needed.
//
// Run: swift run QuickTunnelExample

let tunnel = CloudflareTunnel()

// Handle incoming HTTP requests from the tunnel
await tunnel.setRequestHandler { request, body in
    print("[\(request.method)] \(request.host)\(request.dest)")

    let html = """
    <!DOCTYPE html>
    <html>
    <head><title>swift-cloudflare-tunnel</title></head>
    <body>
        <h1>Hello from Swift!</h1>
        <p>This page is served through a Cloudflare Tunnel using native Swift QUIC.</p>
        <p>Request: \(request.method) \(request.dest)</p>
    </body>
    </html>
    """

    return ProxyResponse(
        statusCode: 200,
        headers: [("Content-Type", "text/html; charset=utf-8")],
        body: Data(html.utf8)
    )
}

// Observe state changes
await tunnel.setStateCallback { state in
    switch state {
    case .connecting:
        print("Connecting to Cloudflare edge...")
    case .registering:
        print("Registering tunnel...")
    case .connected(let location):
        print("Connected via \(location)")
    case .reconnecting(let attempt):
        print("Reconnecting (attempt \(attempt))...")
    case .failed(let error):
        print("Failed: \(error)")
    case .disconnected:
        print("Disconnected")
    }
}

// Start the tunnel
let result = try await tunnel.startQuickTunnel()
print("")
print("========================================")
print("  Your site is live at: \(result.url)")
print("========================================")
print("")
print("Press Ctrl+C to stop.")

// Keep running until interrupted
signal(SIGINT) { _ in
    print("\nShutting down...")
    exit(0)
}
dispatchMain()
