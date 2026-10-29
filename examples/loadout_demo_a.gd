extends "loadout_demo_base.gd"

## Suite part: items through budgets.

# Items

func _test_items() -> void:
	_section("items")

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
	_done()


## Ids interned out of text order: StringName sort() follows interning order, not text.
## Thirty random ids make an accidental pass vanishingly unlikely; the seed keeps it reproducible.
func _unordered_ids(prefix: String, n: int) -> Array[StringName]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261011
	var out: Array[StringName] = []
	while out.size() < n:
		var text := prefix
		for _i in range(6):
			text += char(97 + rng.randi() % 26)
		var id := StringName(text)
		if not out.has(id):
			out.append(id)
	return out


static func _in_text_order(ids: Array[StringName]) -> bool:
	for i in range(ids.size() - 1):
		if String(ids[i]) > String(ids[i + 1]):
			return false
	return true


func _test_text_order() -> void:
	_section("lists are in text order, not interning order")

	var ids := _unordered_ids("s_", 30)
	var loadout := DotLoadout.empty(&"deathmatch")
	for id in ids:
		loadout.set_item(id, &"rifle")

	var slots := loadout.filled_slots()
	_check(_in_text_order(slots), "filled_slots() sorts by text", ", ".join(slots.slice(0, 6)))

	# The digest, computed here from a text sort, so it is what any other program
	# fingerprinting the same loadout gets.
	var text: Array[String] = []
	for id in ids:
		text.append(String(id))
	text.sort()
	var parts := PackedStringArray(["deathmatch"])
	for slot in text:
		parts.append("%s=rifle:0" % slot)
	_check(
		loadout.digest() == DotHash.sha256_text("\n".join(parts)),
		"so the digest is the one another program computes"
	)

	var owned := DotLoadoutEntitlements.of(_unordered_ids("e_", 30))
	_check(_in_text_order(owned.to_list()), "entitlements list by text")

	var items: Array[DotItem] = []
	for id in _unordered_ids("i_", 30):
		items.append(DotItem.make(id))
	var catalogue := DotItemCatalogue.of(items)
	_check(catalogue.ids().size() == 30, "the generated catalogue holds every item")
	_check(_in_text_order(catalogue.ids()), "and lists its ids by text")
	_done()


func _test_catalogue() -> void:
	_section("catalogue")

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
	_done()


func _test_slots() -> void:
	_section("slots")

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
	_done()


func _test_schema() -> void:
	_section("schema")

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
	_done()


# Document

func _test_document() -> void:
	_section("document")

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
	_done()


func _test_entitlements() -> void:
	_section("entitlements")

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
	_done()


func _test_validation() -> void:
	_section("validation")

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

	_check_duplicates()
	_done()


func _check_duplicates() -> void:
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
	_section("conform")

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
	_done()


func _test_budgets() -> void:
	_section("budgets")

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
	_done()
