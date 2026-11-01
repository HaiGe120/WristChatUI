# Search sources implementation evidence

Date: November 1, 2026 (Asia/Shanghai)

Implemented an independent, explicitly selected retrieval layer for iPhone and Watch. Native search remains a separate choice. Custom remote MCP and MiniMax plan search do not read chat endpoint keys. Search credentials use a dedicated Keychain service with destination/authentication binding; profiles, conversation backups and generic API-key synchronization do not contain them. A dedicated companion payload carries profiles and credentials to Watch and rejects older snapshots using a persistent catalog generation and monotonic revision, including changes made within the same timestamp second. New generations after reinstall/restored settings use timestamp ordering; retired generations are remembered so delayed snapshots cannot restore old credentials. A separate local checkpoint excluded from device backup detects defaults revision rollback and starts a new generation.

## Supported subset

- HTTPS remote Streamable HTTP only. No desktop subprocess, stdio, deprecated 2024 HTTP+SSE, general agent runtime, interactive MCP OAuth, sampling, roots, elicitation, or input-response execution.
- Modern `2026-07-28` requests carry protocol/client metadata plus `Mcp-Method`, `Mcp-Name` and valid schema-annotated parameter headers. JSON and request-scoped SSE responses are supported. No GET stream or session header is used for modern requests.
- Legacy `2025-11-25`, `2025-06-18` and `2025-03-26` initialize/initialized/session-header handling is available after an explicit version or missing-session/not-initialized discovery rejection. Generic HTTP 400, authentication, quota and transport failures do not cause protocol or search replay. No actual search tool call is automatically replayed.
- Tool discovery supports up to 16 pages and 256 tools. The user selects one tool, its question field, and required fixed arguments. An input schema change requires setup again. Invalid header annotations are excluded from discovery.
- Modern input-required results and unsupported client requests produce an actionable error. HTTP, JSON-RPC and tool-level errors are not accepted as successful search.
- Results normalize structured JSON or JSON-in-text into actual returned HTTP(S) title/URL/excerpt records. User-configurable field mapping covers unusual JSON results. Plain text without reliable URLs remains uncited reference material. No source URL is generated or fetched automatically.
- Search is limited to 12 references, 1,200 excerpt characters per reference, 12,000 uncited text characters and a 512 KB transport response. Citations retain at most 200 excerpt characters. Setup and retrieval have a 90-second overall limit; cancellation closes the underlying request/session. Engine deadlines can terminate earlier.
- All redirects are rejected. Profile URLs cannot contain credentials, query parameters or fragments. Secrets are bound to their exact destination/authentication contract in Keychain, so interrupted writes cannot forward a new credential to an old URL. Keychain replacement/removal failures surface to the user.

## Provider contract verification

The provider-maintained [MiniMax Coding Plan MCP server](https://github.com/MiniMax-AI/MiniMax-Coding-Plan-MCP) was fetched and inspected on November 1, 2026. Its `minimax_mcp/server.py` sends `POST /v1/coding_plan/search` with `{ "q": query }`. `minimax_mcp/client.py` sends `Authorization: Bearer` and `MM-API-Source: Minimax-MCP` and requires `base_resp.status_code == 0`, with status `1004` treated as authentication failure. The README documents `https://api.minimax.io` and `https://api.minimaxi.com` as distinct key regions. The native Swift adapter uses that contract and permits only those exact regional hosts/search paths. This establishes the published contract, not successful live account entitlement or billing validation.

The official [modern MCP transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http), [tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools), [version negotiation](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning), [schema](https://modelcontextprotocol.io/specification/2026-07-28/schema), and [legacy transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) were fetched and inspected on the same date. The implementation intentionally supports the subset above.

## Validation

`scripts/test-search-fixtures.sh` compiles a standalone macOS fixture runner without a simulator. It exercises HTTPS/profile/credential isolation; schema/header mapping; source normalization; fragmented SSE plus JSON paginated discovery; legacy initialization; actual-question precedence over fixed arguments; unsupported interactive results; authentication-required setup; no replay after generic 400; transport cancellation; and bounded setup timeout.

Live testing against the user's chosen MCP server and MiniMax plan, physical Watch independent reachability, companion credential delivery, source opening, and combined device validation remain release requirements. No private account credential was read and no production search was performed by this implementation task.
