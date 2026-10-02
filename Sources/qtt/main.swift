//
//  main.swift
//  swift-cloudflare-tunnel
//
//  Created by Dan Jabbour on 10/2/26.
//

import Foundation
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
