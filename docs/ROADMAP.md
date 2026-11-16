# MCP Library Roadmap

Development roadmap for the MCP (Model Context Protocol) Zig library.

## Version History

| Version | Status | Description |
|---------|--------|-------------|
| 0.1.0   | Complete | Initial release with core functionality |
| 0.2.0   | Current | Full MCP 2025-11-25 spec compliance |

## Phase 1: Core Protocol (Complete)

- [x] JSON-RPC 2.0 implementation
  - [x] Request parsing
  - [x] Response creation
  - [x] Notification handling
  - [x] Error handling
  - [x] Batch request support

- [x] MCP type definitions
  - [x] Protocol constants (2025-11-25)
  - [x] Method enumerations
  - [x] Capability structures
  - [x] Tool/Resource/Prompt types

- [x] Protocol state machine
  - [x] Connection lifecycle
  - [x] State transitions
  - [x] Capability negotiation
  - [x] Version negotiation (GAP-001)

## Phase 2: Server Implementation (Complete)

- [x] Server core
  - [x] Message routing
  - [x] Request handling
  - [x] Notification processing
  - [x] Pre-init request blocking (GAP-004)

- [x] Tool support
  - [x] Tool registration
  - [x] Input schema validation
  - [x] Handler invocation
  - [x] Result formatting
  - [x] Tool metadata (title, icons, outputSchema, annotations)

- [x] Resource support
  - [x] Resource registration
  - [x] URI-based lookup
  - [x] Content retrieval
  - [x] Subscribe/unsubscribe (GAP-013)
  - [x] Resource metadata (title, icons)

- [x] Prompt support
  - [x] Prompt registration
  - [x] Argument handling
  - [x] Message generation
  - [x] Prompt metadata (title, icons)

## Phase 3: Client Capabilities (Complete)

- [x] Client capability parsing (GAP-002)
  - [x] roots, roots.listChanged
  - [x] sampling, sampling.tools, sampling.context
  - [x] elicitation
  - [x] experimental

- [x] Server-to-client requests
  - [x] requestSampling with full parameters (GAP-056)
  - [x] requestRoots (GAP-015)
  - [x] requestElicitation (GAP-041)

- [x] Session management
  - [x] Cryptographic session IDs (GAP-007)
  - [x] Session lifecycle (create, use, delete) (GAP-008, GAP-011, GAP-012)
  - [x] Pending request tracking

## Phase 4: Transport Layer (Complete)

- [x] stdio transport
  - [x] Basic read/write
  - [x] Newline delimiting

- [x] HTTP/SSE transport
  - [x] SSE parsing
  - [x] HTTP server
  - [x] Origin validation (GAP-006)
  - [x] MCP-Protocol-Version header (GAP-034)
  - [x] SSE event IDs for resumability (GAP-009)
  - [x] Accept header validation (GAP-010)

## Phase 5: Advanced Features (Complete)

### Resource Subscriptions

- [x] Subscribe/unsubscribe handling
- [x] Change notification generation
- [x] Subscription state management

### Sampling (GAP-056-058)

- [x] Sampling request handling
- [x] Full parameter support (systemPrompt, temperature, tools, etc.)
- [x] sampling.tools capability
- [x] sampling.context capability

### Logging (GAP-020)

- [x] Log level management
- [x] Structured log messages
- [x] Log notification routing

### Progress Reporting (GAP-023)

- [x] Progress token handling
- [x] Progress notifications
- [x] Cancellation support (GAP-024)

### Roots (GAP-015, GAP-021)

- [x] Root listing request
- [x] Root change notifications handling

### Tasks System (GAP-035-040)

- [x] Task capability declaration
- [x] Task-augmented requests
- [x] tasks/get, tasks/list, tasks/cancel, tasks/result

### List Changed Notifications (GAP-016-019)

- [x] notifications/resources/list_changed
- [x] notifications/resources/updated
- [x] notifications/prompts/list_changed
- [x] notifications/tools/list_changed

## Phase 6: Production Hardening (Complete)

### Performance

- [x] Parallel request handling with worker thread pool
- [x] Cached initialize response

### Reliability

- [x] Request timeout handling (GAP-005)
- [x] Graceful degradation
- [x] Error recovery

### Security

- [x] Input validation (GAP-030)
- [x] Rate limiting (GAP-029)
- [x] Authentication (Bearer, Basic, OAuth2.1)
- [x] OAuth 2.1 with PKCE
- [x] Resource Indicators RFC 8707 (GAP-054)
- [x] Dynamic Client Registration RFC 7591 (GAP-055)
- [x] Client ID Metadata Documents (GAP-053)

### Error Handling (GAP-031-032)

- [x] Specific error codes (ResourceNotFound, ToolNotFound, etc.)
- [x] Error data field support

## Phase 7: Transport Enhancements (Complete)

### Transport Enhancements

- [x] Buffered I/O optimization (Zig 0.15 API)
- [x] HTTP client (for outbound connections)
- [x] Connection pooling (built into std.http.Client)
- [x] WebSocket transport (RFC 6455 frames, upgrade, ping/pong)

### Performance

- [x] Arena allocator support (RequestArena)
- [ ] Zero-copy parsing where possible
- [ ] Request pipelining

### Observability

- [x] Metrics collection (Prometheus format)
- [x] Tracing support (spans and timing)
- [x] Health checks (JSON status)
- [ ] Debug logging

## Phase 8: Remaining Items (Planned)

### Security

- [ ] TLS support for transports

### CLI Tools

- [ ] MCP server runner
- [ ] Protocol inspector
- [ ] Test client

### Documentation

- [ ] API documentation generation
- [ ] Example gallery
- [ ] Migration guides

### Testing

- [ ] Protocol conformance tests
- [ ] Fuzz testing
- [ ] Performance benchmarks

## Contributing

Contributions are welcome! Please see the [CONTRIBUTING.md](../CONTRIBUTING.md) guide for details.

### Priority Areas

1. **TLS support** - Required for secure deployments
2. **Performance optimization** - Zero-copy parsing
3. **Tooling** - CLI tools for development and debugging
4. **Testing** - Fuzz testing and benchmarks

### How to Contribute

1. Check the issue tracker for open tasks
2. Comment on an issue to claim it
3. Fork and create a feature branch
4. Submit a merge request

## References

- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
- [Server-Sent Events Specification](https://html.spec.whatwg.org/multipage/server-sent-events.html)
- [OAuth 2.1 Draft](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-12)
- [RFC 8707 Resource Indicators](https://datatracker.ietf.org/doc/html/rfc8707)
- [RFC 7591 Dynamic Client Registration](https://datatracker.ietf.org/doc/html/rfc7591)
