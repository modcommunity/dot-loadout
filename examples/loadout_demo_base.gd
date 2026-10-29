extends Node

## Exercises everything in dot-loadout, offline; exits non-zero on any failure.
## Run: godot --headless --path . res://examples/loadout_demo.tscn
## Focus: mistakes that are vulnerabilities (locked items, wrong slot, budget, schema change).

const LOADOUT_DIR := "user://test_loadouts"

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose.
const SECTIONS := 22

## Every check this suite runs, including the two at the end that compare the counts. The
## section counter cannot see a section that aborted after announcing itself — its remaining
## checks simply never run — and a total can. See docs/testing.md.
const CHECKS := 239

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _catalogue: DotItemCatalogue = null
var _schema: DotLoadoutSchema = null


# Assertions

func _section(title: String) -> void:
	_entered += 1
	_group(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


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


# Fixtures

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
