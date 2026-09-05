@tool
class_name DotLoadoutManager
extends Node

## Loads, validates and saves what players take into a match.
##
## [b]The trust boundary is [method publish].[/b] Everything else here is convenience;
## that one method is the place a document from an untrusted client is turned into a
## document the game will act on, and it is the only place both the schema and the
## entitlements are in scope at once.
##
## [b]No autoload.[/b] It registers itself in [DotRegistry] under [constant SERVICE].
## A process running a server and a client at once needs two of these, and
## [member service_scope] is how they coexist.

const CHANNEL := "loadout"
const SERVICE := &"dot_loadout"

## A player's loadouts were loaded or changed.
signal loadouts_changed(user_key: String)

## A published loadout was repaired on its way in. [param changes] is an
## [code]Array[DotLoadoutValidator.Change][/code].
signal loadout_conformed(user_key: String, changes: Array)

## A published loadout was refused. The reason is for logs and admin tools.
signal loadout_refused(user_key: String, reason: String)

@export_group("Configuration")

@export var config: DotLoadoutConfig = null

@export var config_file: String = "user://cfg/loadout.json"

@export var load_layered_config: bool = false

@export_group("Rules")

## The schema every loadout is validated against. Required.
@export var schema: DotLoadoutSchema = null

@export_group("Service")

@export var register_service: bool = true

@export var service_scope: StringName = &""

## Where loadouts are read and written. Built from [member config] at setup if null.
var store: DotLoadoutStore = null

## `func(user_key: String) -> DotLoadoutEntitlements`.
##
## [b]Left unset, every player is entitled to nothing but the free items.[/b] That is
## deliberate: an unwired server that refused everything is loud and gets fixed in a
## minute, and one that accepted everything is silent and is a game where every unlock
## is free.
var entitlement_source: Callable = Callable()

## user key -> Array[DotLoadout].
var _cache: Dictionary = {}

## user key -> index of the loadout in force.
var _selected: Dictionary = {}

## user key -> Unix seconds the player left, for the cache TTL. Absent while present.
var _idle_since: Dictionary = {}

## Players whose only loadout was synthesised from the schema rather than loaded.
##
## Their first publish replaces it instead of adding alongside it — see [method publish].
var _synthesised: Dictionary = {}

var _publish_limiter: DotRateLimiter = null
var _registered_name: StringName = &""


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := setup()

	if not res.ok:
		DotLog.result(CHANNEL, "loadout setup", res)


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""

	if store != null:
		store.close()


func setup() -> DotResult:
	if config == null:
		config = DotLoadoutConfig.new()

	if load_layered_config:
		var loaded := config.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Could not load the loadout configuration.")

	var valid := config.validate()

	if not valid.ok:
		return valid

	if schema == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"A loadout manager needs a schema; without one it cannot validate anything."
		)

	var schema_res := schema.validate()

	if not schema_res.ok:
		return schema_res.wrap("The loadout schema is not usable.")

	if store == null:
		store = (
			DotLoadoutStoreMemory.new()
			if config.backend == "memory"
			else DotLoadoutStoreLocal.at(config.directory)
		)

	# The burst matters more than the sustained rate here. A player opening a loadout
	# screen changes several slots and submits, and a burst so small that the second
	# submission is throttled reads as a broken screen. A refused publish still spends
	# a token — that is the point, since spamming invalid loadouts is the abuse.
	_publish_limiter = DotRateLimiter.new(
		float(config.publishes_per_minute) / 60.0,
		maxf(4.0, float(config.publishes_per_minute) / 3.0)
	)

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	return DotResult.success(null)


# --- Entitlements ----------------------------------------------------------

## What a player is allowed to take.
##
## Never returns null: an unwired source produces an empty set, which permits only
## items marked [member DotItem.free].
func entitlements_for(user_key: String) -> DotLoadoutEntitlements:
	if not config.enforce_entitlements:
		return DotLoadoutEntitlements.everything()

	if not entitlement_source.is_valid():
		return DotLoadoutEntitlements.none()

	var value: Variant = entitlement_source.call(user_key)

	if value is DotLoadoutEntitlements:
		return value

	if value is Array:
		return DotLoadoutEntitlements.of(value as Array)

	return DotLoadoutEntitlements.none()


# --- Loading ---------------------------------------------------------------

## Reads a player's loadouts, conforming them to the current schema.
##
## A store failure is [b]not[/b] a reason to hand back defaults: that would overwrite
## a player's real loadouts with a blank the moment the store hiccups, and the next
## publish would make it permanent. The failure comes back as a failure.
func load_for(user_key: String) -> DotResult:
	if _cache.has(user_key):
		_idle_since.erase(user_key)
		return DotResult.success(_cache[user_key])

	var res: DotResult = await store.fetch(user_key)

	if not res.ok:
		return res.wrap("Could not load loadouts for this player.")

	var loadouts: Array[DotLoadout] = []
	var value: Variant = res.value_or(null)

	if value is Array:
		for entry in (value as Array):
			if entry is DotLoadout:
				loadouts.append(entry)

	if loadouts.is_empty():
		if not config.allow_default_loadout:
			_cache[user_key] = loadouts
			return DotResult.success(loadouts)

		loadouts.append(schema.default_loadout())
		_synthesised[user_key] = true

	if config.conform_on_load:
		var entitlements := entitlements_for(user_key)

		for loadout in loadouts:
			var changes := DotLoadoutValidator.conform(loadout, schema, entitlements)

			if not changes.is_empty():
				loadout_conformed.emit(user_key, changes)

	_cache[user_key] = loadouts
	_idle_since.erase(user_key)
	loadouts_changed.emit(user_key)

	return DotResult.success(loadouts)


## The loadout a player will spawn with. Loads them if needed.
func active_for(user_key: String) -> DotResult:
	var res: DotResult = await load_for(user_key)

	if not res.ok:
		return res

	var loadouts: Array = res.value

	if loadouts.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE, "This player has no loadout and defaults are off."
		)

	var index := clampi(int(_selected.get(user_key, 0)), 0, loadouts.size() - 1)
	return DotResult.success(loadouts[index])


func select(user_key: String, index: int) -> DotResult:
	var loadouts: Array = _cache.get(user_key, [])

	if index < 0 or index >= loadouts.size():
		return DotResult.fail(
			DotError.CODE_INVALID, "No loadout %d for this player." % index
		)

	_selected[user_key] = index
	loadouts_changed.emit(user_key)
	return DotResult.success(index)


func selected_index(user_key: String) -> int:
	return int(_selected.get(user_key, 0))


# --- The trust boundary ----------------------------------------------------

## Accepts a loadout from a client, validates it, and saves it.
##
## [b]This is the only place a document a client controls becomes one the game acts
## on.[/b] Everything a hostile client can influence is checked here:
##
## - The rate, because a loadout screen can publish on every click.
## - The count, because a client that can add loadouts without bound can fill a disk.
## - The schema, because a slot the schema does not have is not a slot.
## - The entitlements, because that is what an unlock is.
##
## [b]It validates rather than conforming.[/b] Conforming is right on the way
## [i]out[/i] of a store, where the alternative is a player who cannot spawn. It is
## wrong here: a client that can make the server repair its way to a legal loadout can
## put anything in any slot and have the server pick the nearest legal thing for it,
## which is a different feature from the one being offered.
func publish(
	user_key: String,
	loadout: DotLoadout,
	index: int = -1
) -> DotResult:
	if loadout == null:
		return _refuse(user_key, "no loadout")

	if not DotLoadoutKey.is_usable(user_key):
		return _refuse(user_key, "unusable player key")

	if config.read_only:
		return _refuse(user_key, "the loadout store is read-only")

	if not _publish_limiter.allow(user_key):
		return _refuse(user_key, "publishing too fast")

	var entitlements := entitlements_for(user_key)
	var valid := DotLoadoutValidator.validate(loadout, schema, entitlements)

	if not valid.ok:
		loadout_refused.emit(user_key, str(valid.error))
		return valid

	var existing: Array = _cache.get(user_key, [])
	var loadouts: Array[DotLoadout] = []

	for entry in existing:
		loadouts.append(entry as DotLoadout)

	var target := index

	# A player with nothing saved was handed a synthesised default so they could
	# spawn. Their first publish is an edit of that, not a second loadout: appending
	# would leave someone who has saved once holding two, and on a schema with a cap
	# of one it would refuse the only publish they ever make.
	if target < 0 and bool(_synthesised.get(user_key, false)) and loadouts.size() == 1:
		target = 0

	if target < 0 or target >= loadouts.size():
		if loadouts.size() >= config.max_per_player:
			return _refuse(
				user_key,
				"a player may keep %d loadouts" % config.max_per_player
			)
		loadouts.append(loadout.duplicate_loadout())
		target = loadouts.size() - 1
	else:
		loadouts[target] = loadout.duplicate_loadout()

	var stored: DotResult = await store.store(user_key, loadouts)

	if not stored.ok:
		# The cache is not updated on a failed write. A cache that disagrees with the
		# store is worse than a refused publish: the player sees their change, plays
		# with it, and loses it at the next load with no explanation.
		return stored.wrap("Could not save the loadout.")

	_cache[user_key] = loadouts
	_selected[user_key] = target
	_synthesised.erase(user_key)
	loadouts_changed.emit(user_key)

	return DotResult.success(target)


func _refuse(user_key: String, reason: String) -> DotResult:
	loadout_refused.emit(user_key, reason)
	return DotResult.fail(DotError.CODE_FORBIDDEN, reason)


# --- Applying --------------------------------------------------------------

## Turns a loadout into `[slot, item]` pairs a game can act on, in schema order.
##
## Deliberately not "give these to a `DotArsenal`": dot-loadout does not import
## dot-combat, and a game that maps items to weapons does so with its own table. The
## `arsenal_slot` on each [DotLoadoutSlot] is the hint that makes that table small.
func resolve(loadout: DotLoadout) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	if loadout == null or schema == null or schema.catalogue == null:
		return out

	for slot in schema.ordered_slots():
		var item_id := loadout.item_in(slot.id)

		if item_id == &"":
			continue

		var item := schema.catalogue.find(item_id)

		if item == null:
			continue

		out.append({
			"slot": slot.id,
			"arsenal_slot": slot.arsenal_slot,
			"item": item,
			"count": loadout.count_in(slot.id, item.count),
		})

	return out


# --- Cache -----------------------------------------------------------------

## Marks a player as gone. Their loadouts stay cached until the TTL expires.
##
## Kept rather than dropped because a player who reconnects within the TTL — which is
## most reconnects — would otherwise cost a store round trip on the join path.
func release(user_key: String) -> void:
	if _cache.has(user_key):
		_idle_since[user_key] = int(Time.get_unix_time_from_system())


## Drops cached players who have been gone longer than the TTL.
##
## Not automatic. A manager that swept on a timer would need a [Timer] child, an
## autoload's worth of lifecycle, or a `_process` that runs on a server doing nothing
## else — the host calls this from whatever loop it already has.
func sweep() -> int:
	var now := int(Time.get_unix_time_from_system())
	var dropped := 0

	for key in _idle_since.keys():
		if float(now - int(_idle_since[key])) < config.cache_ttl_sec:
			continue

		_cache.erase(key)
		_selected.erase(key)
		_synthesised.erase(key)
		_idle_since.erase(key)
		dropped += 1

	if config.max_cached > 0 and _cache.size() > config.max_cached:
		# Over the cap, idle players go first and present ones are kept: dropping a
		# player who is in the match costs a store round trip the moment they respawn.
		for key in _idle_since.keys():
			if _cache.size() <= config.max_cached:
				break
			_cache.erase(key)
			_selected.erase(key)
			_synthesised.erase(key)
			_idle_since.erase(key)
			dropped += 1

	return dropped


func cached_count() -> int:
	return _cache.size()


func forget(user_key: String) -> void:
	_cache.erase(user_key)
	_selected.erase(user_key)
	_synthesised.erase(user_key)
	_idle_since.erase(user_key)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"schema": String(schema.id) if schema != null else "<none>",
		"cached": _cache.size(),
		"idle": _idle_since.size(),
		"store": store.describe() if store != null else {},
		"entitlements": (
			"unenforced" if not config.enforce_entitlements
			else ("wired" if entitlement_source.is_valid() else "free items only")
		),
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"schema   %s" % (schema.id if schema != null else &"<none>"),
		"cached   %d players (%d idle)" % [_cache.size(), _idle_since.size()],
		"store    %s" % (store._store_name() if store != null else "<none>"),
	])
