import CloudflareTunnel
import Foundation

// Quick Tunnel Example
//
// Creates a temporary public URL via trycloudflare.com.
// No Cloudflare account or API token needed.
//
// Usage:
//   swift run QuickTunnelExample                       # In-process handler (default)
//   swift run QuickTunnelExample --origin 8080          # Proxy to localhost:8080
//
// The tunnel opens 4 redundant connections to Cloudflare edge by default.

let args = CommandLine.arguments

// Check if user wants origin proxy mode
let useOriginProxy = args.contains("--origin")
let originPort = useOriginProxy ? (args.last.flatMap(Int.init) ?? 8080) : 0

// connectionCount can be customized (default 4)
let tunnel = CloudflareTunnel()

if useOriginProxy {
    // Origin proxy mode: forward all requests to a local HTTP server.
    // This is the standard cloudflared behavior.
    try await tunnel.setOriginURL("http://localhost:\(originPort)")
    print("Proxying to http://localhost:\(originPort)")
} else {
    // In-process handler mode: handle requests directly in Swift.
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
            <p>Connections: \(tunnel.connectionCount) redundant edge connections</p>
        </body>
        </html>
        """

        return ProxyResponse(
            statusCode: 200,
            headers: [("Content-Type", "text/html; charset=utf-8")],
            body: Data(html.utf8)
        )
    }

    // Optional: handle WebSocket/TCP connections with bidirectional streaming
    await tunnel.setStreamHandler { request in
        print("[STREAM] \(request.connectionType) \(request.host)\(request.dest)")

        return StreamSession(
            initialResponse: ProxyResponse(statusCode: 101, headers: [("Upgrade", "websocket")], body: Data()),
            onData: { data in
                print("  <- \(data.count) bytes from client")
            },
            onClose: {
                print("  Stream closed by client")
            }
        )
    }
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
