@tool
class_name DotLoadoutSlot
extends Resource

## One position in a loadout, and what may go in it.
##
## Slots are ordered and named by the schema; a loadout is a mapping from these ids to
## item ids. Keeping the rule about *what fits* on the slot rather than on the item is
## what lets a game mode swap one schema for another — hardcore, pistols-only, a
## gun-game ladder — without editing every item.

## Stable id. The key in a [DotLoadout] and on the wire.
@export var id: StringName = &""

@export var display_name: String = ""

## Must be filled. A loadout missing it is invalid, and is repaired to
## [member default_item] rather than refused — see [DotLoadoutValidator].
@export var required: bool = false

## Used when the slot is required and empty, and when conforming a broken loadout.
@export var default_item: StringName = &""

@export_group("Acceptance")

## Item kinds this accepts. Empty accepts every kind.
@export var kinds: Array[StringName] = []

## Tags an item must have at least one of. Empty requires none.
@export var require_tags: Array[StringName] = []

## Tags that disqualify an item outright. Checked after [member require_tags], so an
## item with both is rejected.
@export var forbid_tags: Array[StringName] = []

@export_group("Weapon slot")

## The 1-based `DotArsenal` slot this maps to, for a slot holding a weapon.
##
## Zero means this slot is not a weapon slot. dot-loadout never imports dot-combat;
## this is a number a game hands to `DotArsenal.give()`.
@export_range(0, 16, 1) var arsenal_slot: int = 0

@export_group("Presentation")

## Order in a loadout screen. Ties fall back to declaration order.
@export_range(0, 1000, 1) var order: int = 0


static func make(
	p_id: StringName,
	p_required: bool = false,
	p_default: StringName = &""
) -> DotLoadoutSlot:
	var slot := DotLoadoutSlot.new()
	slot.id = p_id
	slot.display_name = String(p_id).capitalize()
	slot.required = p_required
	slot.default_item = p_default
	return slot


## Whether [param item] may be placed here, ignoring entitlements and budgets.
##
## Entitlements are checked separately and later, on purpose: "you cannot put a hat in
## the rifle slot" and "you do not own that rifle" are different answers and a loadout
## screen wants to show them differently — one greys the item out, the other offers to
## sell it.
func accepts(item: DotItem) -> bool:
	if item == null:
		return false

	if not item.fits_slot(id):
		return false

	if not kinds.is_empty() and not kinds.has(item.kind):
		return false

	if not require_tags.is_empty():
		var matched := false
		for tag in require_tags:
			if item.has_tag(tag):
				matched = true
				break
		if not matched:
			return false

	for tag in forbid_tags:
		if item.has_tag(tag):
			return false

	return true


## Why [param item] does not fit, as a sentence. Empty when it does.
##
## Separate from [method accepts] because a boolean is what the validator needs and a
## reason is what a person debugging a schema needs, and computing the reason on every
## acceptance check would be a string allocation per item per slot per screen refresh.
func rejection(item: DotItem) -> String:
	if item == null:
		return "no item"

	if not item.fits_slot(id):
		return "'%s' does not list slot '%s'" % [item.id, id]

	if not kinds.is_empty() and not kinds.has(item.kind):
		return "slot '%s' does not accept kind '%s'" % [id, item.kind]

	if not require_tags.is_empty():
		var matched := false
		for tag in require_tags:
			if item.has_tag(tag):
				matched = true
				break
		if not matched:
			return "slot '%s' requires one of %s" % [id, str(Array(require_tags))]

	for tag in forbid_tags:
		if item.has_tag(tag):
			return "slot '%s' forbids tag '%s'" % [id, tag]

	return ""


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A slot needs an id.")

	if required and default_item == &"":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Slot '%s' is required but has no default, so a loadout missing it "
			% id + "cannot be repaired and can only be refused."
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"required": required,
		"default": String(default_item),
		"kinds": Array(kinds),
		"arsenal_slot": arsenal_slot,
	}


func _to_string() -> String:
	return "DotLoadoutSlot(%s)" % id
