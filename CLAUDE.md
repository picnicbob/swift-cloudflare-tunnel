# CLAUDE.md - swift-cloudflare-tunnel

## Project Overview

Native Swift Cloudflare Tunnel client. Replaces `cloudflared` with ~2,000 lines of Swift using Foundation + Network.framework (zero third-party dependencies).

## Build & Test

```bash
swift build          # Build the library
swift test           # Run unit tests (no network required)
```

## Architecture

```
Sources/CloudflareTunnel/
  CloudflareTunnel.swift          -- Main public API actor (orchestration)
  Logging.swift                   -- TunnelLogger protocol + OSLog default
  Connection/
    TunnelConnection.swift        -- QUIC connection + Cap'n Proto RPC registration
  API/
    CloudflareAPI.swift           -- REST client for Cloudflare API
  Protocol/
    CapnProto.swift               -- Minimal Cap'n Proto codec (internal)
    RPCMessages.swift             -- RPC message builders/parsers (internal)
  Types/
    Configuration.swift           -- TunnelConfiguration, DomainMapping, IngressRule
    Credentials.swift             -- TunnelCredentials
    Errors.swift                  -- TunnelError, TunnelConnectionError, CloudflareAPIError
    Request.swift                 -- IncomingRequest
    Response.swift                -- ProxyResponse
    Status.swift                  -- ConnectionState, ConnectionStatus, DomainStatus
```

## Key Conventions

- **Zero dependencies** - Do NOT add third-party packages. This is a core selling point.
- **Actor isolation** - CloudflareTunnel and TunnelConnection are actors. CloudflareAPI is also an actor. Respect isolation boundaries.
- **Protocol constants** - Values in CloudflareRPC are hardcoded by Cloudflare's protocol. Never change them.
- **Logging** - Use `logger.info/error/debug/warning()`. Never use print() in library code.
- **Naming** - Module is `CloudflareTunnel`. Internal types don't need a CF/Tunnel prefix since they're namespaced.
- **Access control** - CapnProto codec and RPC builders are internal. Public API is on CloudflareTunnel actor.
- **Tests** - Unit tests must not require network. Mark integration tests that need Cloudflare connectivity.

## Protocol Reference

Do NOT modify these constants:
- QUIC ALPN: `["argotunnel"]`
- TLS SNI: `quic.cftunnel.com`
- Edge port: 7844
- RPC stream signature: `0x52BB825CDCDB65`
- Data stream signature: `0x0A36CD12A13E`
- Registration interface ID: `0xf71695ec7fe85497`

## Testing

Unit tests cover: Cap'n Proto codec, configuration Codable round-trips, error descriptions, type construction.

Integration tests (require network): Quick Tunnel creation, named tunnel setup, request proxying, reconnection.
