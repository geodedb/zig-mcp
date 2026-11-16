# MCP Spec Compliance Gaps

Analysis of zigmcp implementation against MCP spec revision **2025-11-25** (latest).

**Status: ALL COMPLETE** - All 61 identified gaps have been addressed for full MCP 2025-11-25 compliance.

## Priority Legend

- **P0**: Critical - Core functionality broken or missing
- **P1**: High - Important feature missing
- **P2**: Medium - Should have for full compliance
- **P3**: Low - Nice to have, edge cases

---

## 1. Protocol/Lifecycle Gaps

### GAP-001: Version Negotiation [P1]

**Spec**: Server MUST validate client's protocol version. If unsupported, respond with a supported version or error.
**Current**: Server ignores client's `protocolVersion` in initialize request.
**Fix**: Parse client version, validate, and respond appropriately.

### GAP-002: Client Capability Parsing [P1]

**Spec**: Server SHOULD parse and store client capabilities to know what features the client supports.
**Current**: Client capabilities from initialize are ignored.
**Fix**: Parse and store `capabilities.roots`, `capabilities.sampling`.

### GAP-003: Initialize Batch Constraint [P2]

**Spec**: Initialize request MUST NOT be part of a JSON-RPC batch.
**Current**: No validation - initialize can be in a batch.
**Fix**: Reject batches containing initialize with error.

### GAP-004: Pre-Initialize Request Blocking [P2]

**Spec**: Server SHOULD NOT process requests (except ping/logging) before receiving `initialized` notification.
**Current**: All requests are processed regardless of init state.
**Fix**: Check `self.initialized` before processing non-exempt methods.

### GAP-005: Request Timeout Support [P2]

**Spec**: Implementations SHOULD establish timeouts for requests and send cancellation on timeout.
**Current**: No timeout tracking for incoming requests.
**Fix**: Track request start times, implement configurable timeouts.

---

## 2. Transport Gaps

### GAP-006: HTTP Origin Validation [P0]

**Spec**: Server MUST validate Origin header to prevent DNS rebinding attacks.
**Current**: No Origin header validation.
**Fix**: Add `http_allowed_origins` option and validate on each request.

### GAP-007: Cryptographic Session IDs [P1]

**Spec**: Session ID SHOULD be globally unique and cryptographically secure.
**Current**: Hardcoded to "mcp-session-1".
**Fix**: Generate random 128-bit session IDs using crypto-safe RNG.

### GAP-008: Session DELETE Support [P2]

**Spec**: Clients SHOULD send DELETE to terminate sessions. Server MAY respond 405 if not supported.
**Current**: DELETE method not handled at all.
**Fix**: Add DELETE handler that invalidates session or returns 405.

### GAP-009: SSE Event IDs for Resumability [P2]

**Spec**: Server MAY assign event IDs for resumable streams. Client can resume with Last-Event-ID header.
**Current**: SSE events have no id field, no resume support.
**Fix**: Add event ID generation and Last-Event-ID handling.

### GAP-010: Accept Header Validation [P3]

**Spec**: Client sends `Accept: application/json, text/event-stream`.
**Current**: Accept header not parsed or validated.
**Fix**: Parse Accept header and respond with appropriate content type.

### GAP-011: Session ID on Initialize Response [P1]

**Spec**: Server MAY assign session ID on initialize response via Mcp-Session-Id header.
**Current**: Session ID only sent on POST responses, not initialize specifically.
**Fix**: Ensure Mcp-Session-Id is sent with initialize response.

### GAP-012: 404 for Invalid Session [P2]

**Spec**: Server MUST respond 404 to requests with terminated/unknown session ID.
**Current**: No session validation or tracking.
**Fix**: Track active sessions, return 404 for invalid session IDs.

---

## 3. Missing Methods

### GAP-013: resources/unsubscribe [P1]

**Spec**: Required method to unsubscribe from resource updates.
**Current**: Not implemented.
**Fix**: Add `unsubscribeResource` to Handler and implement method routing.

### GAP-014: sampling/createMessage (Server→Client) [P2]

**Spec**: Server can request LLM sampling from client if client declared sampling capability.
**Current**: Not implemented.
**Fix**: Add Session method to send sampling requests when client supports it.

### GAP-015: roots/list (Server→Client) [P2]

**Spec**: Server can request filesystem roots from client if client declared roots capability.
**Current**: Not implemented.
**Fix**: Add Session method to request roots list.

---

## 4. Missing Notifications

### GAP-016: notifications/resources/list_changed [P1]

**Spec**: Server SHOULD emit when resource list changes (if listChanged capability declared).
**Current**: No mechanism to emit this notification.
**Fix**: Add `notifyResourceListChanged()` method to Session/Server.

### GAP-017: notifications/resources/updated [P1]

**Spec**: Server SHOULD emit when a subscribed resource changes.
**Current**: No subscription tracking or update notifications.
**Fix**: Track subscriptions, add `notifyResourceUpdated(uri)` method.

### GAP-018: notifications/prompts/list_changed [P1]

**Spec**: Server SHOULD emit when prompt list changes.
**Current**: Not implemented.
**Fix**: Add `notifyPromptListChanged()` method.

### GAP-019: notifications/tools/list_changed [P1]

**Spec**: Server SHOULD emit when tool list changes.
**Current**: Not implemented.
**Fix**: Add `notifyToolListChanged()` method.

### GAP-020: notifications/message (Logging) [P1]

**Spec**: Server SHOULD emit structured log messages to client.
**Current**: Not implemented.
**Fix**: Add `emitLog(level, logger, data)` method using Session.notify().

### GAP-021: notifications/roots/list_changed Handling [P3]

**Spec**: Server should handle this notification from client.
**Current**: Not handled in method routing.
**Fix**: Add handler for roots list changed notification.

---

## 5. Handler API Gaps

### GAP-022: unsubscribeResource Handler [P1]

**Spec**: Handler must support unsubscribing from resources.
**Current**: Handler struct missing `unsubscribeResource` callback.
**Fix**: Add `unsubscribeResource: *const fn(ctx, uri) anyerror!void` to Handler.

### GAP-023: Progress Token Support [P2]

**Spec**: Requests may include `_meta.progressToken` for progress tracking.
**Current**: _meta field not parsed.
**Fix**: Extract progressToken from `_meta`, pass to handlers, support progress notifications.

### GAP-024: Cancellation Request Tracking [P2]

**Spec**: Server should track active request IDs to handle cancellation properly.
**Current**: No tracking of in-flight request IDs.
**Fix**: Maintain map of requestId → CancelToken for proper cancellation.

---

## 6. Capability Gaps

### GAP-025: completions Capability Declaration [P2]

**Spec**: Server should declare `completions: {}` if supporting argument autocompletion.
**Current**: Not declared in initialize response.
**Fix**: Add completions to capabilities in handleInitialize.

### GAP-026: experimental Capability Support [P3]

**Spec**: Both client and server may declare experimental capabilities.
**Current**: Not parsed or supported.
**Fix**: Add experimental field parsing and passthrough.

---

## 7. Content Type Gaps

### GAP-027: Audio Content Type [P3]

**Spec**: Tool results and prompts can return audio content (type: "audio").
**Current**: DemoHandler only shows text content.
**Fix**: Document audio content format in Handler API.

### GAP-028: EmbeddedResource Content [P3]

**Spec**: Content can include embedded resources (type: "resource").
**Current**: Not explicitly documented or tested.
**Fix**: Add examples and validation for embedded resources.

---

## 8. Security Gaps

### GAP-029: Rate Limiting [P2]

**Spec**: Implementations SHOULD implement rate limiting for requests.
**Current**: No rate limiting.
**Fix**: Add configurable rate limits per method/session.

### GAP-030: Input Validation [P2]

**Spec**: Servers MUST validate all inputs.
**Current**: Basic validation exists but could be more comprehensive.
**Fix**: Add URI validation, argument schema validation.

---

## 9. Error Handling Gaps

### GAP-031: Resource Not Found Error Code [P2]

**Spec**: Resource not found should return -32002.
**Current**: Returns generic InternalError.
**Fix**: Add specific error codes for resource/tool/prompt not found.

### GAP-032: Error Data Field [P3]

**Spec**: Error responses MAY include data field with additional context.
**Current**: Error data field not populated.
**Fix**: Add optional data to makeErrorResponse.

---

## Implementation Priority

### Phase 1 (P0-P1 Critical) - COMPLETED

1. ✅ GAP-006: Origin validation
2. ✅ GAP-007: Cryptographic session IDs
3. ✅ GAP-001: Version negotiation
4. ✅ GAP-002: Client capability parsing
5. ✅ GAP-013: resources/unsubscribe
6. ✅ GAP-016-020: List changed notifications
7. ✅ GAP-022: unsubscribeResource handler

### Phase 2 (P2 Important) - COMPLETED

1. ✅ GAP-003: Initialize batch constraint
2. ✅ GAP-004: Pre-init request blocking
3. ✅ GAP-005: Request timeouts
4. ✅ GAP-008: Session DELETE
5. ✅ GAP-009: SSE resumability (event IDs added)
6. ✅ GAP-011-012: Session management
7. ✅ GAP-014-015: Sampling/roots requests (requestSampling, requestRoots)
8. ✅ GAP-023: Progress notifications (notifyProgress method added)
9. ✅ GAP-024: Cancellation tracking
10. ✅ GAP-025: completions capability
11. ✅ GAP-029-030: Rate limiting and validation
12. ✅ GAP-031: Specific error codes

### Phase 3 (P3 Polish) - COMPLETED

1. ✅ GAP-010: Accept header (parsed, lenient validation)
2. ✅ GAP-021: roots list_changed handling
3. ✅ GAP-026: experimental capabilities (parsed from client)
4. ✅ GAP-027-028: Audio and embedded resource content (Handler API docs)
5. ✅ GAP-032: Error data field (makeErrorResponseWithData)

---

## 10. New Gaps for Spec 2025-11-25

### GAP-033: Protocol Version Update [P0]

**Spec**: Current spec revision is 2025-11-25.
**Current**: Declares ProtocolVersion = "2025-03-26".
**Fix**: Update ProtocolVersion constant to "2025-11-25".

### GAP-034: MCP-Protocol-Version Header [P1]

**Spec**: HTTP requests MUST include `MCP-Protocol-Version` header.
**Current**: Header not sent or validated.
**Fix**: Add header to HTTP responses, validate on requests (assume 2025-03-26 if missing).

---

## 11. Tasks System (New in 2025-11-25)

### GAP-035: tasks Capability Declaration [P1]

**Spec**: Server may declare `tasks` capability with supported operations.
**Current**: Not implemented.
**Fix**: Add tasks capability to ServerOptions and initialize response.

### GAP-036: tasks/get Method [P1]

**Spec**: Allow polling for task status with `tasks/get`.
**Current**: Not implemented.
**Fix**: Add task state tracking and tasks/get handler.

### GAP-037: tasks/list Method [P2]

**Spec**: Paginated list of tasks via `tasks/list`.
**Current**: Not implemented.
**Fix**: Add tasks/list handler with pagination.

### GAP-038: tasks/cancel Method [P2]

**Spec**: Cancel running task via `tasks/cancel`.
**Current**: Not implemented.
**Fix**: Add tasks/cancel handler that transitions to cancelled state.

### GAP-039: tasks/result Method [P1]

**Spec**: Block until task completes and return result via `tasks/result`.
**Current**: Not implemented.
**Fix**: Add tasks/result handler with blocking behavior.

### GAP-040: Task-Augmented Requests [P1]

**Spec**: Requests may include `task` field with optional `ttl` for async processing.
**Current**: Not parsed.
**Fix**: Parse task field, create task state, return CreateTaskResult.

---

## 12. Elicitation (New in 2025-11-25)

### GAP-041: elicitation/create Server→Client Request [P2]

**Spec**: Server can request user input via `elicitation/create` if client declared elicitation capability.
**Current**: Not implemented.
**Fix**: Add requestElicitation() method supporting form and URL modes.

---

## 13. Tool Enhancements (2025-11-25)

### GAP-042: Tool title Field [P3]

**Spec**: Tools may have optional `title` for display.
**Current**: Not documented or validated.
**Fix**: Document title field in Handler API.

### GAP-043: Tool icons Field [P3]

**Spec**: Tools may have optional `icons` array for UI.
**Current**: Not documented.
**Fix**: Document icons field format (src, mimeType, sizes).

### GAP-044: Tool outputSchema Field [P2]

**Spec**: Tools may declare `outputSchema` for result validation.
**Current**: Not documented.
**Fix**: Document outputSchema JSON Schema format.

### GAP-045: Tool annotations Field [P2]

**Spec**: Tools may have behavior annotations (destructive, idempotent, etc.).
**Current**: Not documented.
**Fix**: Document annotations for behavior metadata.

---

## 14. Prompt Enhancements (2025-11-25)

### GAP-046: Prompt title Field [P3]

**Spec**: Prompts may have optional `title` for display.
**Current**: Not documented.
**Fix**: Document title field in Handler API.

### GAP-047: Prompt icons Field [P3]

**Spec**: Prompts may have optional `icons` array.
**Current**: Not documented.
**Fix**: Document icons field format.

---

## 15. Resource Enhancements (2025-11-25)

### GAP-048: Resource title Field [P3]

**Spec**: Resources may have optional `title` for display.
**Current**: Not documented.
**Fix**: Document title field.

### GAP-049: Resource icons Field [P3]

**Spec**: Resources may have optional `icons` array.
**Current**: Not documented.
**Fix**: Document icons field format.

---

## 16. ServerInfo Enhancements (2025-11-25)

### GAP-050: ServerInfo description Field [P3]

**Spec**: Server may include `description` in serverInfo.
**Current**: Not supported.
**Fix**: Add description field to ServerOptions.

### GAP-051: ServerInfo icons Field [P3]

**Spec**: Server may include `icons` array in serverInfo.
**Current**: Not supported.
**Fix**: Add icons field to ServerOptions.

### GAP-052: ServerInfo website Field [P3]

**Spec**: Server may include `website` URL in serverInfo.
**Current**: Not supported.
**Fix**: Add website field to ServerOptions.

---

## 17. Authorization Enhancements (2025-11-25)

### GAP-053: OAuth Client ID Metadata Documents [P2]

**Spec**: Support HTTPS URLs as client identifiers pointing to JSON metadata.
**Current**: Not implemented.
**Fix**: Add client metadata document fetching and validation.

### GAP-054: Resource Indicators RFC 8707 [P1]

**Spec**: Access tokens MUST be validated for intended audience per RFC 8707.
**Current**: Not implemented.
**Fix**: Add resource parameter validation in OAuth flow.

### GAP-055: Dynamic Client Registration RFC 7591 [P3]

**Spec**: MAY support dynamic client registration.
**Current**: Not implemented.
**Fix**: Add optional DCR endpoint support.

---

## Implementation Priority (2025-11-25 Gaps)

### Phase 4 (Critical - Protocol Compliance) - COMPLETED

1. ✅ GAP-033: Protocol version update
2. ✅ GAP-034: MCP-Protocol-Version header

### Phase 5 (Tasks System) - COMPLETED

1. ✅ GAP-035: tasks capability
2. ✅ GAP-040: Task-augmented requests (createTask, updateTaskStatus)
3. ✅ GAP-036: tasks/get
4. ✅ GAP-039: tasks/result
5. ✅ GAP-037: tasks/list
6. ✅ GAP-038: tasks/cancel

### Phase 6 (New Client Capabilities) - COMPLETED

1. ✅ GAP-041: elicitation/create (requestElicitation method)
2. ⬜ GAP-054: Resource Indicators (requires full OAuth 2.1 implementation)

### Phase 7 (Metadata Enhancements) - COMPLETED

1. ✅ GAP-042-045: Tool metadata (title, icons, outputSchema, annotations) - documented in Handler API
2. ✅ GAP-046-047: Prompt metadata (title, icons) - documented in Handler API
3. ✅ GAP-048-049: Resource metadata (title, icons) - documented in Handler API
4. ✅ GAP-050-052: ServerInfo metadata (description, icons, website) - added to ServerOptions

### Phase 8 (OAuth 2.1 Enhancements) - COMPLETED

1. ✅ GAP-053: Client ID Metadata Documents (validateClientMetadata, HTTPS URL support)
2. ✅ GAP-054: Resource Indicators RFC 8707 (validateTokenResource, oauth_resource_uri option)
3. ✅ GAP-055: Dynamic Client Registration (registerOAuthClient, /register endpoint)

---

## 18. Sampling Enhancements (2025-11-25)

### GAP-056: Full Sampling Request Parameters [P1]

**Spec**: sampling/createMessage supports: systemPrompt, temperature, stopSequences, tools, toolChoice, modelPreferences, includeContext, metadata.
**Current**: Only messages and maxTokens are supported.
**Fix**: Expand requestSampling() to accept SamplingRequest struct with all parameters.

### GAP-057: Client sampling.tools Capability [P2]

**Spec**: Client may declare `capabilities.sampling.tools` to indicate tool calling support in sampling.
**Current**: Only boolean sampling capability is parsed.
**Fix**: Parse sampling.tools from client capabilities.

### GAP-058: Client sampling.context Capability [P2]

**Spec**: Client may declare `capabilities.sampling.context` to indicate context inclusion support.
**Current**: Not parsed.
**Fix**: Parse sampling.context from client capabilities.

---

### Phase 9 (Sampling Enhancements) - COMPLETED

1. ✅ GAP-056: Full sampling parameters (SamplingRequest struct, requestSamplingFull method)
2. ✅ GAP-057: sampling.tools capability (ClientCapabilities.sampling_tools)
3. ✅ GAP-058: sampling.context capability (ClientCapabilities.sampling_context)

---

## Test Coverage

- [x] Version mismatch handling
- [x] Initialize in batch rejection
- [x] Pre-init request rejection
- [x] Ping allowed before init
- [x] Origin header validation
- [x] Session lifecycle (create, use, delete)
- [x] resources/unsubscribe
- [x] Specific error codes (resource not found, method not found)
- [x] MCP-Protocol-Version header
- [x] Task lifecycle (tasks/list)
- [x] Rate limiting
- [x] Client capability parsing (sampling.tools, sampling.context, elicitation)

### Remaining Test Coverage

- [ ] SSE event IDs and resumption
- [ ] All list_changed notifications
- [ ] Logging notifications
- [ ] Progress notifications
- [ ] Cancellation flow
- [ ] Task get/cancel/result
- [ ] Elicitation request/response

---

## 19. Transport Layer Remaining Gaps (from January 2026 Analysis)

### GAP-059: SSE Last-Event-ID Resumption [P2] ✅ CLOSED

**Spec**: Clients may reconnect with `Last-Event-ID` header to resume from a specific event.
**Status**: Implemented with 256-event ring buffer, header parsing, and event replay.
**Files**: `src/mcp.zig:1246-1343` (SseEventBuffer), `src/mcp.zig:2069-2106` (handleSseConnection)

### GAP-060: SSE Retry Field [P3] ✅ CLOSED

**Spec**: SSE messages should include `retry:` field to hint reconnection delay.
**Status**: Implemented with configurable `sse_retry_ms` option (default 3000ms).
**Files**: `src/mcp.zig:76` (option), `src/mcp.zig:2074-2079` (implementation)

### GAP-061: RFC 5424 Log Level Aliases [P3] ✅ CLOSED

**Spec**: Log levels should map to RFC 5424: emergency, alert, critical, error, warning, notice, info, debug.
**Status**: Implemented `toRfc5424()`, `toRfc5424Numeric()`, and `fromRfc5424()` methods.
**Files**: `src/log.zig:38-75`

---

## Implementation Priority (Remaining from January 2026 Analysis)

### Transport Enhancements [P2-P3] - ALL COMPLETED

1. ✅ GAP-059: SSE Last-Event-ID resumption
2. ✅ GAP-060: SSE retry field
3. ✅ GAP-061: RFC 5424 log level aliases

---

## Summary Statistics

| Category | Total Gaps | Closed | Open |
|----------|------------|--------|------|
| Core Protocol | 5 | 5 | 0 |
| Transport | 10 | 10 | 0 |
| Methods | 3 | 3 | 0 |
| Notifications | 6 | 6 | 0 |
| Handler API | 3 | 3 | 0 |
| Capabilities | 2 | 2 | 0 |
| Content Types | 2 | 2 | 0 |
| Security | 2 | 2 | 0 |
| Error Handling | 2 | 2 | 0 |
| Tasks | 6 | 6 | 0 |
| Elicitation | 1 | 1 | 0 |
| Tool Metadata | 4 | 4 | 0 |
| Prompt Metadata | 2 | 2 | 0 |
| Resource Metadata | 2 | 2 | 0 |
| ServerInfo | 3 | 3 | 0 |
| OAuth 2.1 | 3 | 3 | 0 |
| Sampling | 3 | 3 | 0 |
| **Total** | **61** | **61** | **0** |

**Overall Compliance**: 100% (61/61 gaps closed)
