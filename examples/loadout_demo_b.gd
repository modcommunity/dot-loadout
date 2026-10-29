extends "loadout_demo_a.gd"

## Suite part: wire, stores and the manager.

# --- Wire ------------------------------------------------------------------

## A stand-in for a DotNetWriter. dot-loadout never names one — see [DotLoadout.write].
class FakeWriter extends RefCounted:
	var parts: Array = []

	func write_string(value: String, _max_bytes: int = 1024) -> void:
		parts.append(value)

	func write_uint(value: int, _bits: int = 32) -> void:
		parts.append(value)


class FakeReader extends RefCounted:
	var parts: Array = []
	var index: int = 0
	var exhausted: bool = false

	func _init(p_parts: Array) -> void:
		parts = p_parts

	func _next() -> Variant:
		if index >= parts.size():
			exhausted = true
			return null
		var value: Variant = parts[index]
		index += 1
		return value

	func read_string(_max_bytes: int = 1024) -> String:
		var value: Variant = _next()
		return "" if value == null else str(value)

	func read_uint(_bits: int = 32) -> int:
		var value: Variant = _next()
		return 0 if value == null else int(value)

	func ok() -> bool:
		return not exhausted


func _test_wire() -> void:
	_section("wire")

	var loadout := _full_loadout()

	var writer := FakeWriter.new()
	loadout.write(writer)

	var reader := FakeReader.new(writer.parts)
	var res := DotLoadout.read(reader)

	_check(res.ok, "a loadout round-trips over the wire")
	_check(
		(res.value as DotLoadout).equals(loadout),
		"unchanged, including counts"
	)

	# A truncated stream must be a failure, not a plausible-looking loadout. The
	# reader's exhaustion is sticky for exactly this reason.
	var truncated := FakeReader.new(writer.parts.slice(0, 4))
	_check(
		not DotLoadout.read(truncated).ok,
		"a truncated stream is refused rather than half-decoded"
	)

	# A header claiming more entries than the bound.
	var hostile := FakeReader.new(["deathmatch", 1, 999])
	_check(
		not DotLoadout.read(hostile).ok,
		"a header claiming more entries than the bound is refused"
	)
	_done()


# --- Stores ----------------------------------------------------------------

func _test_store_contract(store: DotLoadoutStore, label: String) -> void:
	_section("store: %s" % label)

	var key := "abcdef0123456789"

	var opened: DotResult = await store.open()
	_check(opened.ok, "%s opens" % label)

	var empty: DotResult = await store.fetch(key)
	_check(empty.ok, "%s reads a player with nothing stored" % label)
	_check(
		empty.value_or(null) == null,
		"and reports absence rather than failing"
	)

	var loadouts: Array[DotLoadout] = [_full_loadout()]
	var stored: DotResult = await store.store(key, loadouts)
	_check(stored.ok, "%s stores" % label)

	var read: DotResult = await store.fetch(key)
	_check(read.ok, "%s reads back" % label)

	var got: Array = read.value
	_check(got.size() == 1, "the right number of loadouts")
	_check((got[0] as DotLoadout).equals(_full_loadout()), "unchanged")

	# A store must hand back copies. Handing back the stored object lets a caller
	# mutate what is "saved" without ever calling store().
	(got[0] as DotLoadout).set_item(&"primary", &"sniper")
	var again: DotResult = await store.fetch(key)
	_check(
		(again.value[0] as DotLoadout).item_in(&"primary") == &"rifle",
		"and mutating what was read does not change what is stored"
	)

	# A malformed key must never reach a filesystem path.
	var traversal: DotResult = await store.fetch("../../etc/passwd")
	_check(not traversal.ok, "a traversal key is refused before the store sees it")

	var short: DotResult = await store.fetch("ab")
	_check(not short.ok, "and so is one that is too short")

	var removed: DotResult = await store.remove(key)
	_check(removed.ok, "%s removes" % label)

	var gone: DotResult = await store.fetch(key)
	_check(gone.value_or(null) == null, "and it is gone")

	store.close()
	_done()


# --- Manager ---------------------------------------------------------------

## [param publishes_per_minute] is set before the node enters the tree, because
## `setup()` builds the rate limiter from it and a later change does nothing.
func _make_manager(publishes_per_minute: int = 240) -> DotLoadoutManager:
	var manager := DotLoadoutManager.new()
	manager.register_service = false
	manager.schema = _build_schema()
	manager.config = DotLoadoutConfig.new()
	manager.config.backend = "memory"
	manager.config.publishes_per_minute = publishes_per_minute
	manager.store = DotLoadoutStoreMemory.new()
	add_child(manager)
	return manager


func _test_manager() -> void:
	_section("manager")

	var manager := _make_manager()
	var key := "player0123456789"

	var loaded: DotResult = await manager.load_for(key)
	_check(loaded.ok, "a player with nothing stored loads")

	var active: DotResult = await manager.active_for(key)
	_check(active.ok, "and has an active loadout")
	_check(
		(active.value as DotLoadout).item_in(&"primary") == &"rifle",
		"which is the schema default"
	)

	# The trust boundary.
	var wanted := _full_loadout()
	wanted.set_item(&"utility", &"medkit")
	var published: DotResult = await manager.publish(key, wanted)
	_check(published.ok, "a legal loadout publishes")

	var after: DotResult = await manager.active_for(key)
	_check(
		(after.value as DotLoadout).item_in(&"utility") == &"medkit",
		"and becomes the active one"
	)

	# The synthesised default was an edit target, not a saved loadout. A player who
	# has published once holds one, not two.
	var held: DotResult = await manager.load_for(key)
	_check(
		(held.value as Array).size() == 1,
		"publishing over a synthesised default replaces it rather than adding to it",
		"holds %d" % (held.value as Array).size()
	)

	var illegal := _full_loadout()
	illegal.set_item(&"primary", &"rocket")
	var refused: DotResult = await manager.publish(key, illegal)
	_check(not refused.ok, "an unentitled loadout is refused")

	var still: DotResult = await manager.active_for(key)
	_check(
		(still.value as DotLoadout).item_in(&"primary") == &"rifle",
		"and the stored one is untouched"
	)

	# The bound on how many a client can create.
	manager.config.max_per_player = 2
	var second: DotResult = await manager.publish(key, _full_loadout())
	_check(second.ok, "a second loadout is accepted", str(second.error))
	var third: DotResult = await manager.publish(key, _full_loadout())
	_check(not third.ok, "a third is refused at the cap")

	# The rate limit, on its own manager: the cap case above needs a rate that does
	# not interfere with it, and a refused publish spends a token either way.
	var slow := _make_manager(12)
	var throttled := 0
	for index in range(40):
		var res: DotResult = await slow.publish(key, _full_loadout(), 0)
		if not res.ok:
			throttled += 1
	_check(throttled > 0, "publishing too fast is throttled", "%d refused" % throttled)
	slow.queue_free()
	remove_child(slow)

	# A failed write must not update the cache: a cache that disagrees with the store
	# shows the player a change they then lose with no explanation.
	var failing := _make_manager()
	failing.store = FailingStore.new()
	var lost: DotResult = await failing.publish("player9876543210", _full_loadout())
	_check(not lost.ok, "a store failure fails the publish")
	var unchanged: DotResult = await failing.load_for("player9876543210")
	_check(not unchanged.ok, "and the failure is reported rather than papered over")

	# resolve() gives a game the slot-to-item mapping without importing dot-combat.
	var mapped := manager.resolve(_full_loadout())
	_check(mapped.size() == 3, "resolve maps every filled slot")
	_check(int(mapped[0]["arsenal_slot"]) == 1, "carrying the arsenal slot hint")

	manager.queue_free()
	remove_child(manager)
	failing.queue_free()
	remove_child(failing)
	_done()


## A store whose reads and writes always fail, for the cache-consistency case.
class FailingStore extends DotLoadoutStore:
	func _store_name() -> String:
		return "FailingStore"

	func _open() -> DotResult:
		return DotResult.success(true)

	func _fetch(_user_key: String) -> DotResult:
		return DotResult.fail(DotError.CODE_IO, "disk on fire")

	func _store(_user_key: String, _loadouts: Array[DotLoadout]) -> DotResult:
		return DotResult.fail(DotError.CODE_IO, "disk on fire")


func _test_manager_entitlements() -> void:
	_section("manager: entitlements")

	var manager := _make_manager()
	var key := "entitled01234567"

	# Unwired: only free items. Loud rather than silent, on purpose.
	var restricted := manager.entitlements_for(key)
	_check(
		not restricted.allows(_catalogue.find(&"sniper")),
		"an unwired entitlement source grants nothing but free items"
	)

	manager.entitlement_source = func(_k: String) -> DotLoadoutEntitlements:
		return DotLoadoutEntitlements.of([&"sniper"])

	var wired := manager.entitlements_for(key)
	_check(wired.allows(_catalogue.find(&"sniper")), "a wired source grants")

	var sniper := _full_loadout()
	sniper.set_item(&"primary", &"sniper")
	var res: DotResult = await manager.publish(key, sniper)
	_check(res.ok, "and the loadout it grants publishes")

	# Turning enforcement off is the one setting that disables a security control.
	manager.config.enforce_entitlements = false
	var anything := manager.entitlements_for("nobody012345678")
	_check(
		anything.allows(_catalogue.find(&"rocket")),
		"enforcement off accepts anything, as documented"
	)

	# A source returning a plain array is accepted, because that is what a backbone
	# response deserialises to and requiring the wrapper would put a conversion in
	# every caller.
	manager.config.enforce_entitlements = true
	manager.entitlement_source = func(_k: String) -> Array:
		return [&"rocket"]
	_check(
		manager.entitlements_for(key).allows(_catalogue.find(&"rocket")),
		"a source returning an array of ids works too"
	)

	manager.queue_free()
	remove_child(manager)
	_done()
