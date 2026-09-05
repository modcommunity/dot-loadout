class_name DotLoadoutValidator
extends RefCounted

## Decides whether a loadout is legal, and repairs it when it is not.
##
## [b]Conform before validate, always.[/b] Retiring an item, adding a required slot or
## tightening a budget makes every saved loadout containing the old thing invalid.
## Refusing those is a player who has not logged in for a month loading into an error
## rather than into a slightly different gun. So the manager conforms first and
## validates the result, and validation is then a check on the repair rather than a
## gate on the player.
##
## The one place that is not true is a loadout arriving from the network. There,
## [method validate] is the trust boundary and a failure is a refusal — a client that
## can make the server repair its way to a legal loadout can put anything in any slot
## and have the server fix it into the nearest legal thing, which is not the same as
## refusing it.

const CHANNEL := "loadout.validate"


## A repair, for a caller that wants to tell the player what changed.
class Change extends RefCounted:
	var slot: StringName = &""
	var was: StringName = &""
	var now: StringName = &""
	var reason: String = ""

	func _to_string() -> String:
		if now == &"":
			return "%s: removed %s (%s)" % [slot, was, reason]
		if was == &"":
			return "%s: added %s (%s)" % [slot, now, reason]
		return "%s: %s -> %s (%s)" % [slot, was, now, reason]


## Whether a loadout is legal exactly as given.
##
## Returns the first problem, not all of them: a client that gets a list of everything
## wrong with its submission gets a map of the validation rules, and a loadout screen
## that cannot produce a legal loadout has a bug in the screen rather than a need for
## better error reporting.
static func validate(
	loadout: DotLoadout,
	schema: DotLoadoutSchema,
	entitlements: DotLoadoutEntitlements
) -> DotResult:
	if loadout == null:
		return DotResult.fail(DotError.CODE_INVALID, "No loadout.")

	if schema == null or schema.catalogue == null:
		return DotResult.fail(DotError.CODE_STATE, "No schema to validate against.")

	if loadout.size() > DotLoadout.MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A loadout with %d entries." % loadout.size()
		)

	var seen_items := {}

	for slot_id in loadout.filled_slots():
		var slot := schema.slot(slot_id)

		if slot == null:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Slot '%s' is not in schema '%s'." % [slot_id, schema.id]
			)

		var item_id := loadout.item_in(slot_id)
		var item := schema.catalogue.find(item_id)

		if item == null:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Item '%s' is not in the catalogue." % item_id
			)

		if not slot.accepts(item):
			return DotResult.fail(
				DotError.CODE_INVALID, slot.rejection(item)
			)

		# Retired items stay valid in a saved loadout on purpose — see
		# [member DotItem.retired] — so this checks selectability, not validity, and
		# is deliberately not a failure here.

		if entitlements != null and not entitlements.allows(item):
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"This player is not entitled to '%s'." % item_id
			)

		if not schema.allow_duplicates:
			if seen_items.has(item_id):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"Item '%s' appears in two slots and this schema forbids it."
						% item_id
				)
			seen_items[item_id] = true

		var count := loadout.count_in(slot_id, item.count)

		if count < 1 or count > item.carry_limit():
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A count of %d for '%s', which allows at most %d."
					% [count, item_id, item.carry_limit()]
			)

	for slot in schema.required_slots():
		if not loadout.has_slot(slot.id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Required slot '%s' is empty." % slot.id
			)

	if schema.point_budget > 0:
		var points := schema.points_used(loadout)
		if points > schema.point_budget:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"This loadout costs %d against a budget of %d."
					% [points, schema.point_budget]
			)

	if schema.weight_budget > 0.0:
		var weight := schema.weight_used(loadout)
		if weight > schema.weight_budget + 0.0001:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"This loadout weighs %.1f against a limit of %.1f."
					% [weight, schema.weight_budget]
			)

	return DotResult.success(null)


## Repairs a loadout in place so that [method validate] would pass, and reports what
## changed.
##
## Never fails: the schema's default loadout is always reachable, which is why
## [method DotLoadoutSchema.validate] refuses a schema whose defaults are not
## themselves legal. A conform that could fail would leave a player unable to spawn.
##
## The order matters. Unknown slots and illegal items go first, then required slots
## are filled, then budgets are trimmed — because filling a required slot can push a
## loadout over budget and trimming first would leave it over.
static func conform(
	loadout: DotLoadout,
	schema: DotLoadoutSchema,
	entitlements: DotLoadoutEntitlements
) -> Array[Change]:
	var changes: Array[Change] = []

	if loadout == null or schema == null or schema.catalogue == null:
		return changes

	loadout.schema_id = schema.id
	loadout.catalogue_version = schema.catalogue.version

	var seen_items := {}

	for slot_id in loadout.filled_slots():
		var slot := schema.slot(slot_id)
		var item_id := loadout.item_in(slot_id)

		if slot == null:
			changes.append(_removal(slot_id, item_id, "no such slot in this schema"))
			loadout.clear_slot(slot_id)
			continue

		var item := schema.catalogue.find(item_id)

		if item == null:
			changes.append(_removal(slot_id, item_id, "no such item"))
			loadout.clear_slot(slot_id)
			continue

		if not slot.accepts(item):
			changes.append(_removal(slot_id, item_id, slot.rejection(item)))
			loadout.clear_slot(slot_id)
			continue

		if entitlements != null and not entitlements.allows(item):
			changes.append(_removal(slot_id, item_id, "not entitled"))
			loadout.clear_slot(slot_id)
			continue

		if not schema.allow_duplicates and seen_items.has(item_id):
			changes.append(_removal(slot_id, item_id, "duplicate"))
			loadout.clear_slot(slot_id)
			continue

		seen_items[item_id] = true

		var count := loadout.count_in(slot_id, item.count)
		var clamped := clampi(count, 1, item.carry_limit())

		if clamped != count:
			loadout.set_item(slot_id, item_id, clamped)

	for slot in schema.required_slots():
		if loadout.has_slot(slot.id):
			continue

		var fallback := _fillable(slot, schema, entitlements, seen_items)

		if fallback == &"":
			# Nothing legal fits. The slot stays empty and validate() will say so —
			# which is a schema problem, not a player problem, and hiding it by
			# putting something illegal in would make it a player problem.
			continue

		loadout.set_item(slot.id, fallback)
		seen_items[fallback] = true
		changes.append(_addition(slot.id, fallback, "required slot was empty"))

	changes.append_array(_trim_budgets(loadout, schema))

	return changes


## The best item that could fill a required slot: its default first, then anything
## legal.
static func _fillable(
	slot: DotLoadoutSlot,
	schema: DotLoadoutSchema,
	entitlements: DotLoadoutEntitlements,
	taken: Dictionary
) -> StringName:
	if slot.default_item != &"":
		var default_item := schema.catalogue.find(slot.default_item)
		var free_to_take := schema.allow_duplicates or not taken.has(slot.default_item)

		if (
			default_item != null
			and slot.accepts(default_item)
			and free_to_take
			and (entitlements == null or entitlements.allows(default_item))
		):
			return slot.default_item

	for item in schema.choices_for(slot.id, entitlements):
		if schema.allow_duplicates or not taken.has(item.id):
			return item.id

	return &""


## Drops the most expensive optional items until the loadout is inside its budgets.
##
## Most expensive first, and optional slots only: dropping a required slot would put
## the loadout straight back into the branch above, and dropping cheap things first
## can take several removals to achieve what one takes.
static func _trim_budgets(
	loadout: DotLoadout,
	schema: DotLoadoutSchema
) -> Array[Change]:
	var changes: Array[Change] = []

	if schema.point_budget <= 0 and schema.weight_budget <= 0.0:
		return changes

	# Bounded rather than while(true): a bug in the cost arithmetic that never brings
	# the total down would otherwise hang the server on the join path.
	for _pass in range(DotLoadout.MAX_SLOTS):
		var over_points := (
			schema.point_budget > 0
			and schema.points_used(loadout) > schema.point_budget
		)
		var over_weight := (
			schema.weight_budget > 0.0
			and schema.weight_used(loadout) > schema.weight_budget + 0.0001
		)

		if not over_points and not over_weight:
			break

		var worst_slot := &""
		var worst_value := -1.0

		for slot_id in loadout.filled_slots():
			var slot := schema.slot(slot_id)

			if slot == null or slot.required:
				continue

			var item := schema.catalogue.find(loadout.item_in(slot_id))

			if item == null:
				continue

			var value := float(item.cost) if over_points else item.weight

			if value > worst_value:
				worst_value = value
				worst_slot = slot_id

		if worst_slot == &"":
			break

		changes.append(
			_removal(worst_slot, loadout.item_in(worst_slot), "over budget")
		)
		loadout.clear_slot(worst_slot)

	return changes


static func _removal(slot: StringName, was: StringName, reason: String) -> Change:
	var change := Change.new()
	change.slot = slot
	change.was = was
	change.reason = reason
	return change


static func _addition(slot: StringName, now: StringName, reason: String) -> Change:
	var change := Change.new()
	change.slot = slot
	change.now = now
	change.reason = reason
	return change
