<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright (c) 2024-2026 CodePros -->

# FIPS-140-3 Mode (`-Dfips`)

## Flag semantics

`mcp` builds with a `-Dfips` flag (default `false`). When **off**, security
crypto routes through `src/std_shim.zig` (pure `std.crypto`) with zero overhead,
no `fips` dependency, and no OpenSSL link. When **on**
(`-Dfips=true -Dopenssl_path=<prefix>`), the seam routes through the linked
OpenSSL 3.x FIPS-140-3 provider via the lazy `fips` package, and
`crypto_backend.assertActive()` hard-fails if the validated provider is absent.

```sh
zig build test --summary all
OPENSSL_CONF=/usr/local/ssl/ssl/openssl.cnf zig build test -Dfips=true -Dopenssl_path=/usr/local/ssl --summary all
# or:  make test-dual
```

`-Dfips` is added to the SAME single `build_options` instance as the otel seam
(GAP-0020-safe). `crypto_backend` is threaded onto `mcp`, `server_ext`,
the unit-test root, and the `tls` test root.

## Routed / gated (security) call sites

| Site | Primitive | Behavior |
|------|-----------|----------|
| `src/mcp.zig` `generateWebSocketAcceptKey` | SHA-1 WebSocket accept-key (RFC 6455) | **REMOVED** under `-Dfips=true` (see below) |
| `src/server_ext.zig` `wsConnectionHandler` | WebSocket upgrade path | comptime-elided under `-Dfips=true` (closes the connection) |

The seam exposes the comptime-known `crypto_backend.fips_enabled` flag, used to
gate the SHA-1 path.

## `fips-exempt` (allow-listed / pending) uses

| Site | Reason |
|------|--------|
| `src/mcp.zig` `generateWebSocketAcceptKey` SHA-1 body | only compiled when `fips_enabled == false` (behind the `@compileError` guard) |
| `src/tls.zig` `const tls = crypto.tls` | **fips-exempt-pending**: stdlib TLS is the NON-FIPS transport; migrate to the validated `devnw/tls` backend for `-Dfips` (tracked here) |

## Behavior changes / removals under `-Dfips=true`

| Capability | Why | Effect |
|------------|-----|--------|
| WebSocket handshake (`generateWebSocketAcceptKey`) | SHA-1 is not FIPS-140-3 approved and RFC 6455 mandates SHA-1 — no interop-preserving substitute | Hard `@compileError` on reference; the single `server_ext.zig` call site is comptime-elided. FIPS deployments must front MCP with a TLS-terminating proxy or use a non-WebSocket transport. |
| TLS transport | stdlib `std.crypto.tls` is not the validated provider | Migration target: the validated `devnw/tls` backend (routes TLS 1.3 + AEAD through the OpenSSL FIPS provider). Documented; not yet wired. |
