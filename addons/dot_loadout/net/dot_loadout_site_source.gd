class_name DotLoadoutSiteSource
extends RefCounted

## Entitlements from the site store: what a player owns in this game's stores, as unlock ids.
##
## Bind [method source] to [member DotLoadoutManager.entitlement_source]. The source is
## synchronous, so it answers from a cache and starts a refresh when the entry is stale;
## call [method refresh] on join to have it ready before the first publish. Nothing owned
## means nothing granted, as the manager's default. The backbone client is held as an
## [Object] with `get_integration(path, query)` (dot-auth's), so dot-auth is not a dependency.
## The response's Ed25519 token is not checked: Godot has no EdDSA, and the bearer-authenticated
## HTTPS fetch is the trust boundary. Needs the credential's STORE_READ scope.

const CHANNEL := "loadout.site"
const PATH := "store/entitlements"

## Any object with `get_integration(String, Dictionary) -> DotResult`.
var client: Object = null

## Seconds a player's answer is trusted before the next read is started.
var ttl_secs: float = 30.0

## player key -> {"ids": Array, "at": float}
var _cache: Dictionary = {}
var _inflight: Dictionary = {}


static func with_client(p_client: Object) -> DotLoadoutSiteSource:
	var s := DotLoadoutSiteSource.new()
	s.client = p_client
	return s


## Unlock ids from an entitlements response: each item's key, plus a string or array under `grant.unlock`.
static func ids_from(body: Dictionary) -> Array:
	var ids := {}
	var items: Variant = body.get("items", [])
	if not items is Array:
		return []
	for item: Variant in items:
		if not item is Dictionary:
			continue
		var d: Dictionary = item
		var key := str(d.get("key", ""))
		if key != "":
			ids[key] = true
		var grant: Variant = d.get("grant")
		if grant is Dictionary:
			var extra: Variant = (grant as Dictionary).get("unlock")
			if extra is String and extra != "":
				ids[extra] = true
			elif extra is Array:
				for e: Variant in extra:
					if e is String and e != "":
						ids[e] = true
	return ids.keys()


## Reads the player's entitlements now and caches them. The value is the id array.
func refresh(player_key: String) -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(DotError.CODE_STATE, "No backbone client with get_integration.")
	if _inflight.has(player_key):
		return DotResult.success(ids_of(player_key))
	_inflight[player_key] = true
	var res: DotResult = await client.call("get_integration", PATH, {"player": player_key})
	_inflight.erase(player_key)
	if not res.ok:
		DotLog.warn(CHANNEL, "store entitlements read failed", {"error": str(res.error)})
		return res
	if not res.value is Dictionary:
		return DotResult.fail(DotError.CODE_INVALID, "The entitlements response is not an object.")
	var ids := ids_from(res.value)
	_cache[player_key] = {"ids": ids, "at": Time.get_ticks_msec() / 1000.0}
	return DotResult.success(ids)


## What is cached for the player, empty when nothing has been read.
func ids_of(player_key: String) -> Array:
	var entry: Dictionary = _cache.get(player_key, {})
	return entry.get("ids", [])


## The manager's `entitlement_source`.
func source(player_key: String) -> DotLoadoutEntitlements:
	var entry: Dictionary = _cache.get(player_key, {})
	var stale: bool = entry.is_empty() or Time.get_ticks_msec() / 1000.0 - float(entry["at"]) > ttl_secs
	if stale and client != null:
		refresh(player_key)
	return DotLoadoutEntitlements.of(ids_of(player_key))


func forget(player_key: String) -> void:
	_cache.erase(player_key)
