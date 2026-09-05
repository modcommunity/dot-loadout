extends Node

## Exercises everything in dot-loadout, offline.
##
## [codeblock]
## godot --headless --path . res://examples/loadout_demo.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## The cases that matter most are the ones where a mistake is a vulnerability rather
## than a crash: a client carrying something it has not unlocked, an item in a slot
## that does not accept it, a budget a client can exceed by publishing twice, and a
## schema change making every saved loadout unloadable.

const LOADOUT_DIR := "user://test_loadouts"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _catalogue: DotItemCatalogue = null
var _schema: DotLoadoutSchema = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-loadout self-test")
	print("")

	DotPaths.remove_tree(LOADOUT_DIR)

	_catalogue = _build_catalogue()
	_schema = _build_schema()

	_test_items()
	_test_catalogue()
	_test_slots()
	_test_schema()
	_test_document()
	_test_entitlements()
	_test_validation()
	_test_conform()
	_test_budgets()
	_test_wire()
	await _test_store_contract(DotLoadoutStoreMemory.new(), "memory")
	await _test_store_contract(DotLoadoutStoreLocal.at(LOADOUT_DIR), "local")
	await _test_manager()
	await _test_manager_entitlements()
	_test_pickups()

	DotPaths.remove_tree(LOADOUT_DIR)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Assertions ------------------------------------------------------------

func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


func _group(title: String) -> void:
	print("")
	print("%s" % title)


# --- Fixtures --------------------------------------------------------------

## The catalogue a game would ship: free starters, paid unlocks, a retired item and
## one whose content is not downloaded yet.
func _build_catalogue() -> DotItemCatalogue:
	var pistol := DotItem.make(&"pistol", DotItem.KIND_WEAPON, true)
	pistol.slots = [&"secondary"]
	pistol.cost = 0
	pistol.weight = 1.0

	var rifle := DotItem.make(&"rifle", DotItem.KIND_WEAPON, true)
	rifle.slots = [&"primary"]
	rifle.tags = [&"starter"]
	rifle.cost = 2
	rifle.weight = 4.0

	var sniper := DotItem.make(&"sniper", DotItem.KIND_WEAPON, false)
	sniper.slots = [&"primary"]
	sniper.tags = [&"heavy"]
	sniper.cost = 5
	sniper.weight = 7.0

	var rocket := DotItem.make(&"rocket", DotItem.KIND_WEAPON, false)
	rocket.slots = [&"primary"]
	rocket.tags = [&"heavy", &"explosive"]
	rocket.cost = 6
	rocket.weight = 9.0

	var grenade := DotItem.make(&"grenade", DotItem.KIND_CONSUMABLE, true)
	grenade.slots = [&"utility"]
	grenade.count = 2
	grenade.max_count = 4
	grenade.cost = 1
	grenade.weight = 0.5

	var medkit := DotItem.make(&"medkit", DotItem.KIND_CONSUMABLE, true)
	medkit.slots = [&"utility"]
	medkit.cost = 1
	medkit.weight = 0.5

	var armour := DotItem.make(&"armour", DotItem.KIND_EQUIPMENT, false)
	armour.slots = [&"gear"]
	armour.cost = 3
	armour.weight = 5.0

	var retired := DotItem.make(&"old_rifle", DotItem.KIND_WEAPON, true)
	retired.slots = [&"primary"]
	retired.retired = true
	retired.cost = 2

	var streamed := DotItem.make(&"gold_rifle", DotItem.KIND_WEAPON, false)
	streamed.slots = [&"primary"]
	streamed.content_id = "sha256:notdownloadedyet"
	streamed.fallback_id = &"rifle"
	streamed.cost = 2

	# Two items, one unlock: buying the pack grants both.
	var pack_a := DotItem.make(&"camo_rifle", DotItem.KIND_COSMETIC, false)
	pack_a.slots = [&"skin"]
	pack_a.entitlement_id = &"camo_pack"

	var pack_b := DotItem.make(&"camo_pistol", DotItem.KIND_COSMETIC, false)
	pack_b.slots = [&"skin"]
	pack_b.entitlement_id = &"camo_pack"

	return DotItemCatalogue.of([
		pistol, rifle, sniper, rocket, grenade, medkit,
		armour, retired, streamed, pack_a, pack_b,
	])


func _build_schema() -> DotLoadoutSchema:
	var primary := DotLoadoutSlot.make(&"primary", true, &"rifle")
	primary.kinds = [DotItem.KIND_WEAPON]
	primary.arsenal_slot = 1
	primary.order = 10

	var secondary := DotLoadoutSlot.make(&"secondary", true, &"pistol")
	secondary.kinds = [DotItem.KIND_WEAPON]
	secondary.arsenal_slot = 2
	secondary.order = 20

	var utility := DotLoadoutSlot.make(&"utility")
	utility.kinds = [DotItem.KIND_CONSUMABLE]
	utility.arsenal_slot = 3
	utility.order = 30

	var gear := DotLoadoutSlot.make(&"gear")
	gear.kinds = [DotItem.KIND_EQUIPMENT]
	gear.order = 40

	var skin := DotLoadoutSlot.make(&"skin")
	skin.kinds = [DotItem.KIND_COSMETIC]
	skin.order = 50

	var schema := DotLoadoutSchema.of(
		&"deathmatch", [primary, secondary, utility, gear, skin], _catalogue
	)
	schema.point_budget = 10
	schema.weight_budget = 20.0
	return schema


func _full_loadout() -> DotLoadout:
	var loadout := DotLoadout.empty(&"deathmatch")
	loadout.catalogue_version = _catalogue.version
	loadout.set_item(&"primary", &"rifle")
	loadout.set_item(&"secondary", &"pistol")
	loadout.set_item(&"utility", &"grenade", 2)
	return loadout


# --- Items -----------------------------------------------------------------

func _test_items() -> void:
	_group("items")

	var rifle := _catalogue.find(&"rifle")
	_check(rifle != null, "an item is found by id")
	_check(rifle.fits_slot(&"primary"), "and lists the slot it fits")
	_check(not rifle.fits_slot(&"utility"), "and not one it does not")

	var grenade := _catalogue.find(&"grenade")
	_check(grenade.carry_limit() == 4, "a carry limit above the default is honoured")

	var pistol := _catalogue.find(&"pistol")
	_check(pistol.unlock_id() == &"pistol", "an item unlocks by its own id")

	var camo := _catalogue.find(&"camo_rifle")
	_check(
		camo.unlock_id() == &"camo_pack",
		"unless it names a shared entitlement"
	)

	var loop := DotItem.make(&"loop")
	loop.fallback_id = &"loop"
	_check(not loop.validate().ok, "an item that falls back to itself is refused")

	var backwards := DotItem.make(&"backwards")
	backwards.count = 5
	backwards.max_count = 2
	_check(
		not backwards.validate().ok,
		"a default count above the maximum is refused"
	)


func _test_catalogue() -> void:
	_group("catalogue")

	_check(_catalogue.validate().ok, "the fixture catalogue validates")
	_check(_catalogue.size() == 11, "every item is indexed", str(_catalogue.size()))
	_check(_catalogue.of_kind(DotItem.KIND_CONSUMABLE).size() == 2, "kinds filter")
	_check(_catalogue.with_tag(&"heavy").size() == 2, "tags filter")

	# A fallback pointing at nothing is a runtime failure at the worst moment: a
	# player whose content did not download loads into an error.
	var broken := DotItemCatalogue.of([DotItem.make(&"a")])
	broken.items[0].fallback_id = &"missing"
	_check(
		not broken.validate().ok,
		"a fallback outside the catalogue is refused at validation"
	)

	# A server has no resolver and must not need one.
	var res := _catalogue.resolve(&"rifle")
	_check(
		not res.ok and res.code() == DotError.CODE_STATE,
		"resolving without a resolver says so rather than pretending"
	)

	var client := _build_catalogue()
	client.resolver = func(item: DotItem) -> Variant:
		return null if item.content_id != "" else String(item.id)

	var resolved := client.resolve(&"rifle")
	_check(resolved.ok and str(resolved.value) == "rifle", "a resolver resolves")

	var fell_back := client.resolve(&"gold_rifle")
	_check(
		fell_back.ok and str(fell_back.value) == "rifle",
		"and falls back when the content is not there"
	)


func _test_slots() -> void:
	_group("slots")

	var slot := DotLoadoutSlot.make(&"primary")
	slot.kinds = [DotItem.KIND_WEAPON]

	_check(slot.accepts(_catalogue.find(&"rifle")), "a weapon slot accepts a weapon")
	_check(
		not slot.accepts(_catalogue.find(&"grenade")),
		"and refuses a consumable"
	)
	_check(slot.rejection(_catalogue.find(&"grenade")) != "", "with a reason")

	slot.forbid_tags = [&"heavy"]
	_check(
		not slot.accepts(_catalogue.find(&"sniper")),
		"a forbidden tag disqualifies an item"
	)

	slot.forbid_tags = []
	slot.require_tags = [&"starter"]
	_check(slot.accepts(_catalogue.find(&"rifle")), "a required tag lets one through")
	_check(
		not slot.accepts(_catalogue.find(&"sniper")),
		"and keeps the rest out"
	)

	# A required slot with no default cannot be repaired, so the player can never
	# spawn. Refusing the schema is the only way that is visible before a match.
	var orphan := DotLoadoutSlot.make(&"orphan", true)
	_check(
		not orphan.validate().ok,
		"a required slot with no default is refused"
	)


func _test_schema() -> void:
	_group("schema")

	_check(_schema.validate().ok, "the fixture schema validates")
	_check(_schema.slot_ids().size() == 5, "every slot is indexed")

	var order := _schema.slot_ids()
	_check(
		order[0] == &"primary" and order[4] == &"skin",
		"slots come back in presentation order",
		str(Array(order))
	)

	var defaults := _schema.default_loadout()
	_check(defaults.size() == 2, "the default loadout fills the required slots")
	_check(defaults.item_in(&"primary") == &"rifle", "from their declared defaults")

	# The one that only shows up in a match: a default the slot itself rejects makes
	# every repair produce an invalid loadout.
	var broken := _build_schema()
	broken.slot(&"primary").default_item = &"grenade"
	_check(
		not broken.validate().ok,
		"a default its own slot rejects is refused at validation"
	)

	var missing := _build_schema()
	missing.slot(&"primary").default_item = &"nonexistent"
	_check(
		not missing.validate().ok,
		"a default outside the catalogue is refused too"
	)

	var choices := _schema.choices_for(&"primary", DotLoadoutEntitlements.none())
	var ids: Array[StringName] = []
	for item in choices:
		ids.append(item.id)
	_check(ids.has(&"rifle"), "an unentitled player is offered the free rifle")
	_check(not ids.has(&"sniper"), "and not the sniper they have not unlocked")
	_check(
		not ids.has(&"old_rifle"),
		"and not a retired item, even though they own it"
	)


# --- Document --------------------------------------------------------------

func _test_document() -> void:
	_group("document")

	var loadout := _full_loadout()
	_check(loadout.size() == 3, "a loadout holds what was put in it")
	_check(loadout.item_in(&"primary") == &"rifle", "keyed by slot")
	_check(loadout.count_in(&"utility", 1) == 2, "with counts where given")

	loadout.clear_slot(&"utility")
	_check(not loadout.has_slot(&"utility"), "clearing a slot removes it")
	_check(loadout.count_in(&"utility", 7) == 7, "and its count")

	# Setting an empty item is how a loadout screen unequips; making it store an empty
	# string would produce a slot the validator then rejects.
	loadout.set_item(&"gear", &"")
	_check(not loadout.has_slot(&"gear"), "setting an empty item clears the slot")

	var round_trip := DotLoadout.from_dictionary(_full_loadout().to_dictionary())
	_check(round_trip.ok, "a loadout round-trips through a dictionary")
	_check(
		(round_trip.value as DotLoadout).equals(_full_loadout()),
		"unchanged"
	)

	# The digest must not depend on the order slots happened to be filled in.
	var a := DotLoadout.empty(&"deathmatch")
	a.set_item(&"primary", &"rifle")
	a.set_item(&"secondary", &"pistol")

	var b := DotLoadout.empty(&"deathmatch")
	b.set_item(&"secondary", &"pistol")
	b.set_item(&"primary", &"rifle")

	_check(a.digest() == b.digest(), "the digest is insertion-order independent")

	b.set_item(&"utility", &"grenade")
	_check(a.digest() != b.digest(), "and changes when the contents do")

	# Everything below is reachable from a file or from the network.
	_check(
		not DotLoadout.from_dictionary({"entries": "not a dictionary"}).ok,
		"entries that are not a dictionary are refused"
	)
	_check(
		not DotLoadout.from_dictionary({"entries": {"primary": {"nested": 1}}}).ok,
		"an item that is not a string is refused rather than coerced"
	)
	_check(
		not DotLoadout.from_dictionary({
			"entries": {"primary": "x".repeat(200)}
		}).ok,
		"an over-long id is refused"
	)

	var too_many := {}
	for index in range(DotLoadout.MAX_SLOTS + 5):
		too_many["slot_%d" % index] = "rifle"
	_check(
		not DotLoadout.from_dictionary({"entries": too_many}).ok,
		"a loadout with more entries than the bound is refused"
	)

	_check(not DotLoadout.from_json("[]").ok, "a JSON array is not a loadout")
	_check(not DotLoadout.from_json("not json").ok, "and neither is nonsense")


func _test_entitlements() -> void:
	_group("entitlements")

	var none := DotLoadoutEntitlements.none()
	_check(
		none.allows(_catalogue.find(&"rifle")),
		"a free item is allowed with no entitlements at all"
	)
	_check(
		not none.allows(_catalogue.find(&"sniper")),
		"and a paid one is not"
	)

	var owner := DotLoadoutEntitlements.of([&"sniper"])
	_check(owner.allows(_catalogue.find(&"sniper")), "granting an id allows it")
	_check(not owner.allows(_catalogue.find(&"rocket")), "and only it")

	# The shared-unlock indirection: one grant, two items.
	var pack := DotLoadoutEntitlements.of([&"camo_pack"])
	_check(
		pack.allows(_catalogue.find(&"camo_rifle"))
			and pack.allows(_catalogue.find(&"camo_pistol")),
		"a shared entitlement unlocks every item that names it"
	)

	var everything := DotLoadoutEntitlements.everything()
	_check(
		everything.allows(_catalogue.find(&"rocket")),
		"an unrestricted set allows anything"
	)

	owner.revoke(&"sniper")
	_check(not owner.allows(_catalogue.find(&"sniper")), "revoking works")

	var merged := DotLoadoutEntitlements.of([&"sniper"])
	merged.merge(DotLoadoutEntitlements.of([&"rocket"]))
	_check(merged.count() == 2, "merging combines two sets")


func _test_validation() -> void:
	_group("validation")

	var owner := DotLoadoutEntitlements.of([&"sniper", &"armour"])

	var good := _full_loadout()
	_check(
		DotLoadoutValidator.validate(good, _schema, owner).ok,
		"a legal loadout validates"
	)

	var unowned := _full_loadout()
	unowned.set_item(&"primary", &"rocket")
	var res := DotLoadoutValidator.validate(unowned, _schema, owner)
	_check(
		not res.ok and res.code() == DotError.CODE_FORBIDDEN,
		"an item the player has not unlocked is refused as forbidden",
		res.code()
	)

	var wrong_slot := _full_loadout()
	wrong_slot.set_item(&"utility", &"rifle")
	_check(
		not DotLoadoutValidator.validate(wrong_slot, _schema, owner).ok,
		"a weapon in a consumable slot is refused"
	)

	var invented := _full_loadout()
	invented.set_item(&"backpack", &"rifle")
	_check(
		not DotLoadoutValidator.validate(invented, _schema, owner).ok,
		"a slot the schema does not have is refused"
	)

	var missing := _full_loadout()
	missing.clear_slot(&"secondary")
	_check(
		not DotLoadoutValidator.validate(missing, _schema, owner).ok,
		"an empty required slot is refused"
	)

	var over_count := _full_loadout()
	over_count.set_item(&"utility", &"grenade", 99)
	_check(
		not DotLoadoutValidator.validate(over_count, _schema, owner).ok,
		"a count above the carry limit is refused"
	)

	# A retired item stays valid in a saved loadout. Refusing it is how a player who
	# has not logged in for a month loads into an error.
	var retired := _full_loadout()
	retired.set_item(&"primary", &"old_rifle")
	_check(
		DotLoadoutValidator.validate(retired, _schema, owner).ok,
		"a retired item is still valid in a saved loadout"
	)

	# Duplicates. A local fixture, because every item in the shared catalogue is
	# locked to one slot and the same item could never appear in two of them — which
	# would make this pass for the wrong reason.
	var anywhere := DotItem.make(&"anywhere", DotItem.KIND_WEAPON, true)
	var dup_schema := DotLoadoutSchema.of(
		&"dup",
		[
			DotLoadoutSlot.make(&"a", true, &"anywhere"),
			DotLoadoutSlot.make(&"b", true, &"anywhere"),
		],
		DotItemCatalogue.of([anywhere])
	)

	var duplicated := DotLoadout.empty(&"dup")
	duplicated.set_item(&"a", &"anywhere")
	duplicated.set_item(&"b", &"anywhere")
	_check(
		not DotLoadoutValidator.validate(
			duplicated, dup_schema, DotLoadoutEntitlements.everything()
		).ok,
		"the same item in two slots is refused when the schema forbids it"
	)

	dup_schema.allow_duplicates = true
	_check(
		DotLoadoutValidator.validate(
			duplicated, dup_schema, DotLoadoutEntitlements.everything()
		).ok,
		"and permitted when it allows it"
	)


func _test_conform() -> void:
	_group("conform")

	var owner := DotLoadoutEntitlements.none()

	var broken := DotLoadout.empty(&"old_schema")
	broken.set_item(&"primary", &"rocket")
	broken.set_item(&"backpack", &"rifle")
	broken.set_item(&"utility", &"grenade", 99)

	var changes := DotLoadoutValidator.conform(broken, _schema, owner)

	_check(changes.size() >= 2, "conforming reports what it changed", str(changes.size()))
	_check(broken.schema_id == &"deathmatch", "and restamps the schema")
	_check(not broken.has_slot(&"backpack"), "an unknown slot is dropped")
	_check(
		broken.item_in(&"primary") == &"rifle",
		"an unentitled item is replaced by the slot default",
		String(broken.item_in(&"primary"))
	)
	_check(broken.item_in(&"secondary") == &"pistol", "a missing required slot is filled")
	_check(broken.count_in(&"utility", 0) == 4, "an over-large count is clamped")

	# The whole point: a conformed loadout validates.
	_check(
		DotLoadoutValidator.validate(broken, _schema, owner).ok,
		"and the result is a loadout that validates"
	)

	# Conforming an empty loadout must produce a playable one.
	var empty := DotLoadout.empty()
	DotLoadoutValidator.conform(empty, _schema, owner)
	_check(
		DotLoadoutValidator.validate(empty, _schema, owner).ok,
		"conforming an empty loadout produces a playable one"
	)


func _test_budgets() -> void:
	_group("budgets")

	var rich := DotLoadoutEntitlements.everything()

	var expensive := DotLoadout.empty(&"deathmatch")
	expensive.set_item(&"primary", &"rocket")
	expensive.set_item(&"secondary", &"pistol")
	expensive.set_item(&"gear", &"armour")
	expensive.set_item(&"utility", &"grenade")

	_check(_schema.points_used(expensive) == 10, "points are summed",
		str(_schema.points_used(expensive)))

	expensive.set_item(&"utility", &"grenade", 2)
	var over := DotLoadout.empty(&"deathmatch")
	over.set_item(&"primary", &"rocket")
	over.set_item(&"secondary", &"pistol")
	over.set_item(&"gear", &"armour")
	over.set_item(&"utility", &"medkit")
	over.set_item(&"skin", &"camo_rifle")

	var tight := _build_schema()
	tight.point_budget = 8

	_check(
		not DotLoadoutValidator.validate(over, tight, rich).ok,
		"a loadout over its point budget is refused"
	)

	# Conforming trims the most expensive optional item, not a required one.
	var trimmed := over.duplicate_loadout()
	DotLoadoutValidator.conform(trimmed, tight, rich)
	_check(
		trimmed.has_slot(&"primary") and trimmed.has_slot(&"secondary"),
		"trimming keeps the required slots"
	)
	_check(
		tight.points_used(trimmed) <= tight.point_budget,
		"and brings the loadout inside its budget",
		"%d of %d" % [tight.points_used(trimmed), tight.point_budget]
	)
	_check(
		DotLoadoutValidator.validate(trimmed, tight, rich).ok,
		"so the trimmed loadout validates"
	)

	var heavy := _build_schema()
	heavy.weight_budget = 6.0
	var loaded := DotLoadout.empty(&"deathmatch")
	loaded.set_item(&"primary", &"rocket")
	loaded.set_item(&"secondary", &"pistol")
	_check(
		not DotLoadoutValidator.validate(loaded, heavy, rich).ok,
		"weight is a separate budget and is enforced separately"
	)


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
	_group("wire")

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


# --- Stores ----------------------------------------------------------------

func _test_store_contract(store: DotLoadoutStore, label: String) -> void:
	_group("store: %s" % label)

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
	_group("manager")

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
	_group("manager: entitlements")

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


# --- Pickups ---------------------------------------------------------------

func _test_pickups() -> void:
	_group("pickups")

	var field := DotPickupField.new()
	field.tick_rate = 60
	add_child(field)

	var health := DotPickup.new()
	health.item_id = &"medkit"
	health.respawn_sec = 1.0
	health.position = Vector3(0.0, 0.0, 0.0)
	field.add_child(health)

	var ammo := DotPickup.new()
	ammo.ammo_pool = &"rifle"
	ammo.ammo_amount = 30
	ammo.respawn_sec = 0.0
	ammo.position = Vector3(10.0, 0.0, 0.0)
	field.add_child(ammo)

	field.refresh()
	_check(field.pickups().size() == 2, "the field collects its pickups")
	_check(field.available_count() == 2, "both start available")

	_check(health.in_range(Vector3(0.5, 0.0, 0.5)), "a nearby player is in range")
	_check(not health.in_range(Vector3(5.0, 0.0, 0.0)), "a distant one is not")
	_check(
		not health.in_range(Vector3(0.0, 5.0, 0.0)),
		"and neither is one on a walkway overhead"
	)

	var taken: Array[int] = []
	field.collected.connect(
		func(_p: DotPickup, taker: int, _t: int) -> void: taken.append(taker)
	)

	var got := field.sweep(7, Vector3.ZERO, 100)
	_check(got.size() == 1, "sweeping takes what is in reach")
	_check(taken.size() == 1 and taken[0] == 7, "and reports who took it")
	_check(not health.available, "the pickup is gone")

	var again := field.sweep(8, Vector3.ZERO, 101)
	_check(again.is_empty(), "and cannot be taken twice")

	# Respawn is a target tick, not a countdown. Ticking twice on the same tick must
	# respawn once, or a replayed tick brings something back early.
	field.tick(140)
	_check(not health.available, "it does not come back early")
	field.tick(160)
	_check(health.available, "and does come back on schedule")

	field.sweep(9, Vector3.ZERO, 200)
	field.tick(260)
	field.tick(260)
	_check(health.available, "ticking the same tick twice is idempotent")

	# A pickup nobody has room for stays on the floor.
	field.wants_fn = func(_taker: int, _pickup: DotPickup) -> bool: return false
	var refused := field.sweep(10, Vector3.ZERO, 300)
	_check(refused.is_empty(), "a pickup nobody needs is not taken")
	_check(health.available, "and is left for someone who does")

	health.allow_wasteful_pickup = true
	var wasteful := field.sweep(11, Vector3.ZERO, 301)
	_check(wasteful.size() == 1, "unless the pickup permits it")

	# A client instance reports what is nearby and takes nothing.
	field.reset(400)
	field.is_authority = false
	field.wants_fn = Callable()
	var previewed := field.sweep(12, Vector3.ZERO, 400)
	_check(previewed.size() == 1, "a client still reports what it is standing on")
	_check(health.available, "but takes nothing")

	field.queue_free()
	remove_child(field)
