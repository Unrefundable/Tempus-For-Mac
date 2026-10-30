# ADR 0002: Hand-written Subsonic models instead of a generated client

- **Status:** Accepted
- **Date:** 2026-10-29

## Context

The OpenSubsonic project publishes an OpenAPI 3.0 spec (v1.16.1, 87 paths, 195 schemas). ADR 0001 planned to try Apple's `swift-openapi-generator` on it before writing the API layer by hand.

## Experiment

I generated types for `getAlbum` and `ping` with swift-openapi-generator 1.x and decoded three responses:

| Response | Result |
|---|---|
| Classic Subsonic success (no `type`, `serverVersion`, `openSubsonic`) | **Rejected**: `keyNotFound "type"` |
| Auth failure (`status: failed`, code 40) from a classic server | **Rejected**: `keyNotFound "type"` |
| OpenSubsonic (Navidrome-style) success | Decodes only with the generator's own date strategy |

Every response is `subsonic-response: oneOf(success, failure)`, and both sides `allOf` a base that *requires* the OpenSubsonic-only fields. A generated client therefore can't talk to classic servers at all, and it can't even report their login errors.

## Decision

Hand-write `Codable` models and request builders in the `SubsonicAPI` module. Use the spec only as a checklist of endpoints and fields. Decode as leniently as upstream Tempus does with Gson (`RetrofitClient`, `EmptyDateTypeAdapter`, `BookmarksDeserializer`):

- Every field except `id` is optional.
- Ids may arrive as JSON numbers.
- Dates use one of three ISO-8601 forms. Empty or unparseable dates become `nil` instead of failing the response.
- A list may arrive as a single object.

## Consequences

- There's more code to write. It stays small because only the roughly 45 endpoints Tempus uses are modelled.
- Fixtures cover both classic and OpenSubsonic response shapes.
- Builds stay fast: there's no build plugin, and no generated code for 170 operations.
