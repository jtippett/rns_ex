# Transport Path Request & Remote Management Port

**Date:** 2026-03-14
**Status:** Approved
**Scope:** Review items 2 & 3 — port `Transport.path_request`, wire remote handlers, clean up implementation shortcuts

## Overview

Port the Transport path request routing logic from Python RNS, wire the remote management handlers to return real data, and complete the narrower implementation shortcuts identified in code review.

## 1. New ETS Tables

Three new tables added to `Transport.create_ets_tables`:

| Table | Key | Value | Purpose |
|-------|-----|-------|---------|
| `@discovery_pr_tags_table` | `unique_tag` (binary) | `inserted_at` (timestamp) | Deduplicates incoming path requests |
| `@discovery_path_requests_table` | `destination_hash` | `%{timeout: timestamp, requesting_interface: interface}` | Tracks pending discovery requests (15s timeout) |
| `@pending_local_path_requests_table` | `destination_hash` | `attached_interface` | Maps destinations to requesting interface for local client response forwarding |

Tag table is culled when size exceeds 32,000 entries — delete entries older than the 32,000th newest via `:ets.select_delete` with a timestamp threshold. Discovery path requests culled by timeout. Both run in the existing periodic `cull_tables` job.

## 2. Core Function: `path_request/5`

Private function called within the Transport GenServer process (from `path_request_handler`).

**Signature:** `path_request(destination_hash, is_from_local_client, attached_interface, requestor_transport_id, tag)`

**Five branches (evaluated in order):**

1. **Local destination exists** — Look up in `@destinations_table`. Call `Destination.announce(dest, path_response: true, tag: tag, attached_interface: interface)`.

2. **Path known in table** (transport enabled OR from local client) — Fetch cached announce packet from path table. Set retransmit timing:
   - Immediate for local clients
   - Immediate if next hop is on a local client interface
   - Delayed by `PATH_REQUEST_GRACE` (0.4s) otherwise
   - Extra delay `PATH_REQUEST_RG` (1.5s) for roaming-mode interfaces
   - Handle held-announces edge case (move existing announce_table entry to held_announces before overwriting)
   - Skip if next hop is the requestor transport ID
   - Skip if roaming-mode interface and next hop is on same interface

3. **From local client, no known path** — Forward `request_path` on all interfaces except the requesting one.

4. **Should search for unknown** (transport enabled + discoverable interface mode) — Add to `@discovery_path_requests_table` with 15s timeout. Forward `request_path` on all interfaces except requestor, passing original tag to avoid loops. Use `recursive: true`.

5. **Not from local client, local clients exist** — Forward `request_path` to all local client interfaces.

## 3. Helper Functions

- `from_local_client?(packet)` — Checks if `packet.receiving_interface` has a `parent_interface` with `is_local_shared_instance: true`.
- `local_client_interface?(interface)` — Checks if interface has a `parent_interface` with `is_local_shared_instance: true`.

## 4. Wiring `path_request_handler`

Replace the log-only stub. After parsing destination hash, transport instance, and tag bytes:

1. Build `unique_tag = destination_hash <> tag_bytes`
2. Check `@discovery_pr_tags_table` — if tag exists, log duplicate and return
3. Insert `{unique_tag, now}` into `@discovery_pr_tags_table`
4. Call `path_request(destination_hash, from_local_client?(packet), packet.receiving_interface, requestor_transport_id, tag_bytes)`

## 5. Extending `request_path`

The existing `request_path/1` cast becomes `request_path/3`: `request_path(destination_hash, on_interface \\ nil, opts \\ [])`.

- `opts[:tag]` — tag to include in path request data
- `opts[:recursive]` — when true, check announce cap timing before sending (prevents flooding on recursive forwards)

Builds path request packet: `destination_hash + [transport_identity_hash +] tag`. Sends via `Packet.send/1`.

## 6. Reticulum Stats Functions

Four new public functions on `RNS.Reticulum`, all reading ETS directly (no GenServer call needed):

- **`get_interface_stats/0`** — Iterates `@interfaces_table`, pulls common fields: `name`, `hash`, `type`, `rxb`, `txb`, `status`, `mode`, `bitrate`, `peers` count. Top-level map includes aggregate traffic stats from Transport and `transport_id`/`transport_uptime` if transport enabled.

- **`get_link_count/0`** — Returns `:ets.info(@link_table, :size)`.

- **`get_path_table/1`** — Takes optional `max_hops`. Folds over `@path_table`, builds `%{hash, timestamp, via, hops, expires, interface}` maps, filters by max_hops.

- **`get_rate_table/0`** — Folds over `@announce_rate_table`, builds `%{hash, last, rate_violations, blocked_until, timestamps}` maps.

## 7. Remote Handlers

- **`remote_status_handler/2`** — Calls `RNS.Reticulum.get_interface_stats()`. If `data == [true]`, appends `RNS.Reticulum.get_link_count()`.
- **`remote_path_handler/2`** — Parses command from data. `"table"` calls `get_path_table/1` with optional max_hops and destination filter. `"rates"` calls `get_rate_table/0` with optional destination filter.

## 8. Transport.owner Wiring

`Reticulum.start_transport/1` calls `GenServer.call(RNS.Transport, {:set_owner, self()})` after starting Transport. Stores Reticulum pid in state. Not on critical path for stats (ETS reads are direct), but needed for `is_connected_to_shared_instance` checks and future shared instance support.

## 9. GenServer State Additions

```elixir
# Added to Transport init state:
local_client_interfaces: [],    # populated when LocalInterface clients connect
```

## 10. Testing Strategy

- Unit tests for each `path_request` branch using mock interfaces/destinations in ETS
- Unit tests for tag deduplication (insert, duplicate rejection, cull)
- Unit tests for the four Reticulum stats functions with seeded ETS data
- Integration test: register a local destination, send a path request packet, verify announce comes back as path response

## Constants

```elixir
@path_request_timeout  15      # seconds
@path_request_grace    0.4     # seconds
@path_request_rg       1.5     # seconds — extra grace for roaming interfaces
@max_pr_tags           32_000  # max unique path request tags to remember
```
