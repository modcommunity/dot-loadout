@tool
class_name DotItem
extends Resource

## One thing a player can be given, carry or wear into a match.
##
## [b]Deliberately not a weapon.[/b] A weapon is a `DotWeapon` in dot-combat, which
## dot-loadout does not import — an item names one by id and something else resolves
## it. That is what makes a loadout a document a server can validate without loading a
## mesh, a scene or a weapon resource, which is the same trade dot-user-avatar makes
## and for the same reason: **the thing a client sends must be checkable by a machine
## that has none of the content.**

## What this is, so a slot can say what it accepts.
##
## Not exhaustive, and not an enum for the reason [DotHitGroup] is not one: a game
## with a deployable, a vehicle key or a spell has a kind dot-loadout has never heard
## of, and an enum would make adding one a fork.
const KIND_WEAPON := &"weapon"
const KIND_EQUIPMENT := &"equipment"
const KIND_CONSUMABLE := &"consumable"
const KIND_COSMETIC := &"cosmetic"
const KIND_PERK := &"perk"

@export_group("Identity")

## Stable id. Travels on the wire, keys the entitlement, and is what a resolver turns
## into an actual asset.
@export var id: StringName = &""

@export var display_name: String = ""

@export var kind: StringName = KIND_WEAPON

@export_group("Placement")

## Slot ids this may go in. Empty means any slot that accepts its kind.
@export var slots: Array[StringName] = []

## Free-form tags a slot or a game mode can filter on: `starter`, `heavy`, `sniper`.
@export var tags: Array[StringName] = []

@export_group("Cost")

## Points this costs against [member DotLoadoutSchema.point_budget].
##
## The mechanism behind "you may take one heavy weapon, or three light ones" without
## the schema having to enumerate every legal combination.
@export_range(0, 1000, 1) var cost: int = 0

## Counts against [member DotLoadoutSchema.weight_budget]. Distinct from cost so a
## game can have both a balance budget and a carry limit.
@export_range(0.0, 1000.0, 0.1) var weight: float = 0.0

@export_group("Entitlement")

## Everyone has this. The default is [b]false[/b], deliberately — see
## [DotLoadoutEntitlements].
@export var free: bool = false

## Entitlement checked instead of [member id], when several items share one unlock.
@export var entitlement_id: StringName = &""

@export_group("Lifecycle")

## No longer selectable, but still valid in a saved loadout.
##
## Distinct from deleting the item: an item that vanishes makes every loadout
## containing it invalid, and a player who has not logged in for a month then loads
## into an error rather than into a slightly different gun.
@export var retired: bool = false

## Content this needs before it can be used, for dot-cloud. An id, not a path.
@export var content_id: String = ""

## Used when [member content_id] is not available yet. Must itself be available.
@export var fallback_id: StringName = &""

@export_group("Quantities")

## How many a slot holds by default. Grenades, medkits.
@export_range(1, 999, 1) var count: int = 1

## Most a player may carry. Zero means [member count].
@export_range(0, 999, 1) var max_count: int = 0


static func make(
	p_id: StringName,
	p_kind: StringName = KIND_WEAPON,
	p_free: bool = false
) -> DotItem:
	var item := DotItem.new()
	item.id = p_id
	item.display_name = String(p_id).capitalize()
	item.kind = p_kind
	item.free = p_free
	return item


## The id an entitlement check uses.
func unlock_id() -> StringName:
	return entitlement_id if entitlement_id != &"" else id


func carry_limit() -> int:
	return max_count if max_count > 0 else count


func has_tag(tag: StringName) -> bool:
	return tags.has(tag)


func fits_slot(slot_id: StringName) -> bool:
	return slots.is_empty() or slots.has(slot_id)


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "An item needs an id.")

	if fallback_id == id:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Item '%s' falls back to itself, which cannot terminate." % id
		)

	if max_count > 0 and max_count < count:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Item '%s' has a default count of %d above its maximum of %d."
				% [id, count, max_count]
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"kind": String(kind),
		"slots": Array(slots),
		"tags": Array(tags),
		"cost": cost,
		"weight": weight,
		"free": free,
		"retired": retired,
		"count": count,
	}


func _to_string() -> String:
	return "DotItem(%s)" % id
