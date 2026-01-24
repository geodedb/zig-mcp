# MCP Library Architecture

This document describes the architecture and design of the MCP (Model Context Protocol) Zig library.

## Overview

The MCP library provides a layered architecture for implementing MCP servers and clients in Zig. The design emphasizes:

- **Modularity** - Each component can be used independently
- **Testability** - Mock implementations for deterministic testing
- **Performance** - Zero-allocation parsing where possible
- **Type Safety** - Leveraging Zig's type system for correctness

## Layer Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Layer                        │
│  (User code: tool handlers, resource providers, prompts)    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      High-Level API                          │
│         ┌─────────────┐           ┌─────────────┐           │
│         │   Server    │           │   Client    │           │
│         └─────────────┘           └─────────────┘           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Component Layer                           │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Tools   │  │ Resources │  │ Prompts  │  │ Session  │   │
│  └──────────┘  └───────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Protocol Layer                            │
│  ┌──────────┐  ┌───────────┐  ┌──────────────────────────┐ │
│  │ Protocol │  │  Message  │  │         JSON-RPC         │ │
│  │  State   │  │  Builder  │  │   Request/Response/      │ │
│  │ Machine  │  │           │  │      Notification        │ │
│  └──────────┘  └───────────┘  └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Transport Layer                           │
│         ┌─────────────┐           ┌─────────────┐           │
│         │    stdio    │           │  HTTP/SSE   │           │
│         │  Transport  │           │  Transport  │           │
│         └─────────────┘           └─────────────┘           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Type Layer                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │   Types: RequestId, Method, ErrorCode, Capabilities   │  │
│  │   Tool, Resource, Prompt, Content, etc.               │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Module Descriptions

### Type Layer (`types.zig`)

Foundation module providing:
- Protocol constants (version, methods)
- Request/response ID types
- MCP method enumerations
- JSON-RPC error codes
- Capability structures
- Tool, Resource, Prompt definitions
- Content types (text, image, resource)

### JSON-RPC Layer (`jsonrpc.zig`)

JSON-RPC 2.0 implementation:
- Request parsing and serialization
- Response creation (success and error)
- Notification handling
- Message type discrimination

### Message Layer (`message.zig`)

MCP-specific message handling:
- Higher-level message abstraction
- Request builders for all MCP methods
- Response parsers
- Method-specific utilities

### Protocol Layer (`protocol.zig`)

Protocol state machine:
- Connection state tracking (uninitialized → initializing → ready → closed)
- Capability negotiation
- Request ID generation
- State transition validation

### Transport Layer (`transports/`)

Communication abstractions:

**stdio Transport** (`transports/stdio.zig`):
- Standard input/output communication
- Newline-delimited JSON messages
- Used for subprocess-based servers

**HTTP Transport** (`transports/http.zig`):
- HTTP POST for requests
- Server-Sent Events (SSE) for responses
- Used for web-based deployments

### Server Components (`server/`)

**Tools** (`server/tools.zig`):
- Tool registration and lookup
- Input schema management
- Handler invocation
- Result formatting

**Resources** (`server/resources.zig`):
- Resource registration
- URI-based lookup
- Content provider handlers
- Subscription management

**Prompts** (`server/prompts.zig`):
- Prompt template registration
- Argument handling
- Message generation

### Client Components (`client/`)

**Session** (`client/session.zig`):
- Pending request tracking
- Response correlation
- Subscription management
- Capability caching

### High-Level API

**Server** (`server.zig`):
- Complete server implementation
- Message routing
- Tool/resource/prompt coordination
- Transport integration

**Client** (`client.zig`):
- Complete client implementation
- Request creation
- Response handling
- Server capability discovery

### Utilities (`util/`)

**Clock** (`util/clock.zig`):
- Time abstraction
- Real and mock implementations
- Deterministic testing support

**Logging** (`util/logging.zig`):
- Log level management
- Structured logging
- MCP logging notifications

## Design Patterns

### Dependency Injection

Modules accept their dependencies explicitly, enabling:
- Unit testing with mocks
- Alternative implementations
- Clear dependency graphs

### State Machine

Protocol state is managed through explicit states:
```
UNINITIALIZED → INITIALIZING → READY → SHUTTING_DOWN → CLOSED
```

Invalid transitions return errors rather than silently failing.

### Handler Pattern

Tools, resources, and prompts use handler functions:
```zig
pub const ToolHandler = *const fn (
    allocator: Allocator,
    arguments: ?JsonValue,
) anyerror!JsonValue;
```

This allows flexible implementation while maintaining type safety.

### Builder Pattern

Message construction uses builders for complex message types:
```zig
var builder = MessageBuilder.init(allocator);
const msg = try builder.initializeRequest(id, client_info, capabilities);
```

## Testing Strategy

### Unit Tests

Each module contains embedded tests:
```zig
test "Protocol initialization flow" {
    // ...
}
```

Run with: `zig build test`

### Acceptance Tests

Integration tests in `tests/accept.zig`:
- Full protocol handshakes
- Multi-message exchanges
- Error handling

### Deterministic Testing

Mock utilities enable reproducible tests:
- `MockClock` - Fixed timestamps
- `MockTransport` - Controlled I/O
- `MockRandom` - Predictable randomness (for future PRNG needs)

## Thread Safety

The library is designed for single-threaded use per connection:
- Each Server/Client instance should be used from one thread
- Multiple instances can run in parallel on different threads
- Allocator must be thread-safe if shared

## Memory Management

- All dynamic allocation goes through user-provided allocator
- Returned slices are typically owned by caller
- `deinit()` methods clean up internal state
- No global state or allocations

## Error Handling

Errors are propagated through Zig's error union system:
- Protocol errors become `ProtocolError`
- JSON parsing errors bubble up from std.json
- Transport errors are transport-specific
- Application errors from handlers are wrapped in error responses
