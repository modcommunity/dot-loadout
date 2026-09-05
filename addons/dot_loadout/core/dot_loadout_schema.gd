@tool
class_name DotLoadoutSchema
extends Resource

## The shape a loadout must have: which slots exist, what goes in them, and what a
## player may spend.
##
## A game mode's rules about equipment, in one resource. Swapping schemas is how a
## hardcore round, a pistols-only round and a normal one differ without any item
## changing.

const CHANNEL := "loadout.schema"

@export var id: StringName = &"default"

@export var display_name: String = ""

## Bumped when the slots change in a way that invalidates saved loadouts. Carried by
## every [DotLoadout] so a mismatch is visible rather than mysterious.
@export_range(1, 100000, 1) var version: int = 1

@export var slots: Array[DotLoadoutSlot] = []

## Where item ids are looked up.
@export var catalogue: DotItemCatalogue = null

@export_group("Budgets")

## Total [member DotItem.cost] a loadout may spend. Zero means unlimited.
@export_range(0, 10000, 1) var point_budget: int = 0

## Total [member DotItem.weight] a loadout may carry. Zero means unlimited.
@export_range(0.0, 10000.0, 0.5) var weight_budget: float = 0.0

@export_group("Policy")

## Whether the same item may appear in two slots.
@export var allow_duplicates: bool = false

var _by_id: Dictionary = {}
var _indexed: bool = false


static func of(
	p_id: StringName,
	p_slots: Array[DotLoadoutSlot],
	p_catalogue: DotItemCatalogue
) -> DotLoadoutSchema:
	var schema := DotLoadoutSchema.new()
	schema.id = p_id
	schema.slots = p_slots
	schema.catalogue = p_catalogue
	return schema


func reindex() -> void:
	_by_id.clear()

	for slot in slots:
		if slot != null and slot.id != &"":
			_by_id[slot.id] = slot

	_indexed = true


func _ensure_indexed() -> void:
	if not _indexed:
		reindex()


func slot(slot_id: StringName) -> DotLoadoutSlot:
	_ensure_indexed()
	return _by_id.get(slot_id)


func has_slot(slot_id: StringName) -> bool:
	_ensure_indexed()
	return _by_id.has(slot_id)


func slot_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for slot in ordered_slots():
		out.append(slot.id)
	return out


## Slots in presentation order, then declaration order.
##
## A stable sort: two slots with the same [member DotLoadoutSlot.order] keep the order
## they were declared in. Godot's `sort_custom` is not stable, so the comparator falls
## back to the declared index rather than leaving it to the algorithm — otherwise a
## loadout screen's slot order changes between runs.
func ordered_slots() -> Array[DotLoadoutSlot]:
	var indexed: Array[Vector2i] = []

	for index in range(slots.size()):
		if slots[index] != null:
			indexed.append(Vector2i(slots[index].order, index))

	indexed.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y
	)

	var out: Array[DotLoadoutSlot] = []

	for entry in indexed:
		out.append(slots[entry.y])

	return out


func required_slots() -> Array[DotLoadoutSlot]:
	var out: Array[DotLoadoutSlot] = []
	for slot in ordered_slots():
		if slot.required:
			out.append(slot)
	return out


## What a player may put in [param slot_id], given what they own.
##
## This is what a loadout screen is built on. It returns items the player can actually
## take — the slot accepts them, they are not retired, and they are entitled — which
## is different from everything the slot accepts. A screen that shows the second and
## refuses on submit is a screen that lies.
func choices_for(
	slot_id: StringName,
	entitlements: DotLoadoutEntitlements
) -> Array[DotItem]:
	var out: Array[DotItem] = []
	var target := slot(slot_id)

	if target == null or catalogue == null:
		return out

	for item in catalogue.items:
		if item == null or item.retired:
			continue

		if not target.accepts(item):
			continue

		if entitlements != null and not entitlements.allows(item):
			continue

		out.append(item)

	return out


## A loadout with every required slot filled from its default and nothing else.
##
## What a player with no saved loadout gets, and what conforming falls back to.
func default_loadout() -> DotLoadout:
	var loadout := DotLoadout.empty(id)
	loadout.catalogue_version = catalogue.version if catalogue != null else 0

	for slot in ordered_slots():
		if slot.required and slot.default_item != &"":
			loadout.set_item(slot.id, slot.default_item)

	return loadout


## Points a loadout spends.
func points_used(loadout: DotLoadout) -> int:
	var total := 0

	if catalogue == null:
		return total

	for slot_id in loadout.filled_slots():
		var item := catalogue.find(loadout.item_in(slot_id))
		if item != null:
			total += item.cost

	return total


func weight_used(loadout: DotLoadout) -> float:
	var total := 0.0

	if catalogue == null:
		return total

	for slot_id in loadout.filled_slots():
		var item := catalogue.find(loadout.item_in(slot_id))
		if item != null:
			total += item.weight * float(loadout.count_in(slot_id, item.count))

	return total


func validate() -> DotResult:
	reindex()

	if slots.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "Schema '%s' declares no slots." % id
		)

	if catalogue == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "Schema '%s' has no catalogue." % id
		)

	var catalogue_res := catalogue.validate()

	if not catalogue_res.ok:
		return catalogue_res.wrap("Schema '%s' has an invalid catalogue." % id)

	var seen := {}

	for slot in slots:
		if slot == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "Schema '%s' holds a null slot." % id
			)

		var res := slot.validate()

		if not res.ok:
			return res

		if seen.has(slot.id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Schema '%s' declares slot '%s' twice." % [id, slot.id]
			)

		seen[slot.id] = true

		if slot.default_item == &"":
			continue

		var item := catalogue.find(slot.default_item)

		if item == null:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Slot '%s' defaults to '%s', which is not in the catalogue."
					% [slot.id, slot.default_item]
			)

		# A default the slot itself rejects makes every repair produce an invalid
		# loadout, which then repairs again. The loop terminates but the result is a
		# player who cannot spawn, and the cause is three files away.
		if not slot.accepts(item):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Slot '%s' defaults to '%s', which it does not accept: %s"
					% [slot.id, slot.default_item, slot.rejection(item)]
			)

		if not item.free:
			# A required default nobody owns means every player without that
			# entitlement is repaired into an invalid loadout.
			DotLog.warn(
				CHANNEL,
				"a slot default is not free, so players without it cannot be repaired",
				{"slot": String(slot.id), "item": String(item.id)}
			)

	var baseline := default_loadout()

	if point_budget > 0 and points_used(baseline) > point_budget:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Schema '%s' has a default loadout costing %d against a budget of %d."
				% [id, points_used(baseline), point_budget]
		)

	return DotResult.success(slots.size())


func describe() -> Dictionary:
	var out := []
	for slot in ordered_slots():
		out.append(slot.describe())

	return {
		"id": String(id),
		"version": version,
		"slots": out,
		"points": point_budget,
		"weight": weight_budget,
		"catalogue": catalogue.describe() if catalogue != null else {},
	}


func _to_string() -> String:
	return "DotLoadoutSchema(%s, %d slots)" % [id, slots.size()]
