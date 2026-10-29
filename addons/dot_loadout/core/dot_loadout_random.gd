class_name DotLoadoutRandom
extends RefCounted

## The "Random" entry of a loadout menu: a fresh set of items every time it is used, under the
## server owner's settings. Pure data in, a loadout out; [DotLoadoutCommand] is what asks it.

const CHANNEL := "loadout.random"

const CVAR_ENABLED := "mp_loadout_random"
const CVAR_COUNT := "mp_loadout_random_count"
const CVAR_SLOTS := "mp_loadout_random_slots"
const CVAR_PRICE := "mp_loadout_random_price"
const CVAR_DUPES := "mp_loadout_random_dupes"
const CVAR_SEED := "mp_loadout_random_seed"
const CVAR_CLASS := "mp_loadout_random_class"

const PRICE_FREE := "free"
const PRICE_SUM := "sum"
const PRICE_FLAT := "flat"

## Off: the entry is not offered and the command refuses.
var enabled: bool = true
## Slots re-rolled per use; 0 is every eligible slot.
var count: int = 0
## Slot ids it may draw for; empty is every slot.
var slots: PackedStringArray = PackedStringArray()
## [constant PRICE_FREE], [constant PRICE_SUM] (the items' prices) or [constant PRICE_FLAT].
var price_mode: String = PRICE_FREE
var flat_cost: int = 0
## Whether one item id may fill two slots.
var duplicates: bool = false
## 0 draws from a time-seeded stream; any other value makes the whole sequence repeatable.
var seed_value: int = 0
## Class id to {count, slots, price} overrides.
var per_class: Dictionary = {}
## `func(item: DotItem) -> int`: what an item costs here; unset is its cost.
var price_fn: Callable = Callable()

var _stream: DotRandomStream = null
var _stream_seed: int = -1


## Reads the settings from cvar-shaped strings. [param price_text] is free, sum or flat:N;
## [param class_text] is `class.count=2 class.slots=primary+secondary class.price=sum`.
func configure(p_enabled: bool, p_count: int, slots_text: String, price_text: String, p_dupes: bool,
		p_seed: int, class_text: String) -> DotResult:
	var price := parse_price(price_text)
	if not price.ok:
		return price
	var classes := parse_classes(class_text)
	if not classes.ok:
		return classes
	enabled = p_enabled
	count = maxi(0, p_count)
	slots = split_slots(slots_text)
	price_mode = price.value["mode"]
	flat_cost = price.value["flat"]
	duplicates = p_dupes
	seed_value = p_seed
	per_class = classes.value
	return DotResult.success(self)


static func split_slots(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for w in text.replace("+", ",").split(",", false):
		out.append(w.strip_edges().to_lower())
	return out


static func parse_price(text: String) -> DotResult:
	var t := text.strip_edges().to_lower()
	if t == "" or t == PRICE_FREE or t == "0":
		return DotResult.success({"mode": PRICE_FREE, "flat": 0})
	if t == PRICE_SUM:
		return DotResult.success({"mode": PRICE_SUM, "flat": 0})
	if t.begins_with(PRICE_FLAT + ":") and t.substr(5).is_valid_int() and int(t.substr(5)) >= 0:
		return DotResult.success({"mode": PRICE_FLAT, "flat": int(t.substr(5))})
	return DotResult.fail(DotError.CODE_INVALID, "'%s' is not free, sum or flat:N." % text)


static func parse_classes(text: String) -> DotResult:
	var out: Dictionary = {}
	for word in text.strip_edges().split(" ", false):
		var eq := word.find("=")
		var dot := word.find(".")
		if eq <= 0 or dot <= 0 or dot > eq:
			return DotResult.fail(DotError.CODE_INVALID, "'%s' is not class.setting=value." % word)
		var cls := word.substr(0, dot).to_lower()
		var setting := word.substr(dot + 1, eq - dot - 1).to_lower()
		var value := word.substr(eq + 1)
		var entry: Dictionary = out.get(cls, {})
		match setting:
			"count":
				if not value.is_valid_int():
					return DotResult.fail(DotError.CODE_INVALID, "'%s': count is a whole number." % word)
				entry["count"] = maxi(0, int(value))
			"slots":
				entry["slots"] = split_slots(value)
			"price":
				var p := parse_price(value)
				if not p.ok:
					return p
				entry["price"] = p.value
			_:
				return DotResult.fail(DotError.CODE_INVALID, "'%s': unknown setting '%s'." % [word, setting])
		out[cls] = entry
	return DotResult.success(out)


## The settings that apply to [param class_id]: {count, slots, mode, flat}.
func effective(class_id: StringName) -> Dictionary:
	var out := {"count": count, "slots": slots, "mode": price_mode, "flat": flat_cost}
	var over: Dictionary = per_class.get(str(class_id).to_lower(), {})
	if over.has("count"):
		out["count"] = over["count"]
	if over.has("slots"):
		out["slots"] = over["slots"]
	if over.has("price"):
		out["mode"] = over["price"]["mode"]
		out["flat"] = over["price"]["flat"]
	return out


## What the menu says the entry costs.
func price_text(class_id: StringName = &"") -> String:
	var e := effective(class_id)
	match e["mode"]:
		PRICE_FLAT:
			return "%d" % e["flat"]
		PRICE_SUM:
			return "items"
	return ""


func _rng() -> DotRandomStream:
	if _stream == null or _stream_seed != seed_value:
		_stream_seed = seed_value
		var s := seed_value if seed_value != 0 else int(Time.get_ticks_usec() ^ (randi() << 16)) | 1
		_stream = DotRandomStream.new(s, &"loadout_random")
	return _stream


func _price(item: DotItem) -> int:
	return int(price_fn.call(item)) if price_fn.is_valid() else item.cost


## Rolls a new loadout for [param key] from [param current]. [param class_rules] (or null) is what
## the player's class may carry; [param money] is -1 for no limit. Returns
## {loadout, spent, changed: [slot ids]} or a failure saying why nothing was rolled.
func roll(manager: DotLoadoutManager, key: String, current: DotLoadout, class_id: StringName = &"",
		class_rules: DotLoadoutRules = null, money: int = -1) -> DotResult:
	if not enabled:
		return DotResult.fail(DotError.CODE_STATE, "Random loadouts are off on this server.")
	if manager == null or manager.schema == null:
		return DotResult.fail(DotError.CODE_STATE, "No loadout schema.")
	var schema := manager.schema
	var e := effective(class_id)
	var flat: bool = e["mode"] == PRICE_FLAT
	var sum: bool = e["mode"] == PRICE_SUM
	if flat and money >= 0 and money < int(e["flat"]):
		return DotResult.fail(DotError.CODE_STATE, "Random costs %d; you have %d." % [e["flat"], money])
	var filter: PackedStringArray = e["slots"]
	var pool: Array = []
	for slot in schema.ordered_slots():
		var fixed: bool = manager.rules != null and (manager.rules.is_fixed(slot.id) or not manager.rules.choose)
		if fixed or (not filter.is_empty() and not filter.has(str(slot.id))):
			continue
		pool.append(slot.id)
	var n: int = pool.size() if int(e["count"]) <= 0 else mini(int(e["count"]), pool.size())
	var picked: Array = _rng().next_sample(pool, n)
	var loadout := current.duplicate_loadout()
	var spent := 0 if not flat else int(e["flat"])
	var changed: Array[StringName] = []
	for slot_id: StringName in picked:
		var options: Array = []
		for item in manager.choices_for(key, slot_id):
			if class_rules != null and not class_rules.permits(slot_id, item):
				continue
			if not duplicates and _held_elsewhere(loadout, slot_id, item.id):
				continue
			var without := loadout.duplicate_loadout()
			without.clear_slot(slot_id)
			if schema.point_budget > 0 and schema.points_used(without) + item.cost > schema.point_budget:
				continue
			if schema.weight_budget > 0.0 and schema.weight_used(without) + item.weight * item.count > schema.weight_budget:
				continue
			if sum and money >= 0 and spent + _price(item) > money:
				continue
			options.append(item)
		if options.is_empty():
			continue
		var item: DotItem = _rng().next_pick(options)
		loadout.set_item(slot_id, item.id)
		if sum:
			spent += _price(item)
		changed.append(slot_id)
	if changed.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "Nothing could be rolled for you.")
	return DotResult.success({"loadout": loadout, "spent": spent, "changed": changed})


static func _held_elsewhere(loadout: DotLoadout, slot_id: StringName, item_id: StringName) -> bool:
	for other in loadout.filled_slots():
		if other != slot_id and loadout.item_in(other) == item_id:
			return true
	return false


func describe() -> Dictionary:
	return {"enabled": enabled, "count": count, "slots": slots, "price": price_mode, "flat": flat_cost,
		"duplicates": duplicates, "seed": seed_value, "classes": per_class.keys()}
