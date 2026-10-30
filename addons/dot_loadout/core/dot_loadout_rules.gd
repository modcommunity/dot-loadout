class_name DotLoadoutRules
extends RefCounted

## What a server owner lets players carry: whether they choose at all, which items each slot
## may hold, and the slots the server fills itself.
##
## [codeblock]
## # Snipers only: the primary is any scoped weapon, everything else as usual.
## var rules: DotLoadoutRules = DotLoadoutRules.parse(true, "primary=tag:scoped", "").value
## # Everybody gets the same kit and nobody chooses.
## var locked: DotLoadoutRules = DotLoadoutRules.parse(false, "",
## 	"primary=marksman secondary=pistol melee=knife thrown=frag").value
## manager.rules = rules
## [/codeblock]
##
## [b]Separate from the schema and from entitlements, on purpose.[/b] The schema is the game's
## design (which slots exist, what each accepts, the budget) and entitlements are what one player
## has unlocked; both are fixed when the game ships. These are what one SERVER's owner decided
## tonight, read from cvars and changed while players are connected. Folding them into the schema
## would mean rebuilding it, and every saved loadout conformed against it, on a cvar change; folding
## them into entitlements would lose the slot (an owner who allows a pistol as a sidearm has not
## allowed it everywhere).
##
## [b]The grammar is the cvar's[/b]: whitespace-separated `slot=pattern,pattern` entries, where a
## pattern is an item id, `tag:<tag>`, or either with a leading `-` to forbid it. A slot whose
## patterns are all forbids allows everything else; `*` is every slot. `fixed` names one item per
## slot, or `none` to keep the slot empty. No semicolons, because a server console splits lines on
## them.
##
## [codeblock]
## mp_loadout_allow "primary=tag:scoped"                 # snipers only
## mp_loadout_allow "*=-tag:explosive"                   # no launchers or grenades
## mp_loadout_allow "primary=rifle,carbine secondary=pistol"
## mp_loadout_fixed "primary=marksman thrown=none"       # these two are the server's
## mp_loadout_menu 0                                     # nobody chooses: defaults and fixed only
## [/codeblock]

# No log channel: parsed rules and answers. The manager and DotLoadoutCommand, which know whose
# loadout it is and which cvar said so, log.

## The cvars every game with a loadout menu registers, through [DotLoadoutCommand] or by hand.
const CVAR_MENU := "mp_loadout_menu"
const CVAR_ALLOW := "mp_loadout_allow"
const CVAR_FIXED := "mp_loadout_fixed"
## The point budget a loadout may cost; 0 is unlimited (every item free unless the profile prices it).
const CVAR_BUDGET := "mp_loadout_budget"

## Saved loadouts one player may keep (0 is unlimited).
const CVAR_MAX_SAVED := "mp_loadout_max_saved"
const CVAR_STORE_MAX_BYTES := "mp_loadout_store_max_bytes"
const CVAR_STORE_MAX_FILES := "mp_loadout_store_max_files"

## A `fixed` value that keeps a slot empty.
const NONE := "none"

## The `*` slot: patterns every slot also obeys.
const EVERY_SLOT := &"*"

## Whether players choose their own loadout. Off, a publish is refused and everybody spawns with
## the schema's defaults, over which [member fixed] still applies.
var choose: bool = true

## Slot id to patterns ([PackedStringArray]). A slot not here allows everything the schema does.
var allowed: Dictionary = {}

## Slot id to the item the server puts there ([StringName]; `&""` keeps it empty). A fixed slot
## permits that item and nothing else.
var fixed: Dictionary = {}

## Points a loadout may cost; 0 leaves it to the schema, whose own default is unlimited.
var point_budget: int = 0


## No restriction: players choose anything the schema and their entitlements allow.
static func open() -> DotLoadoutRules:
	return DotLoadoutRules.new()


## Rules from the three cvars' values. Fails, naming the entry, on text it cannot read; the
## caller keeps the rules it had (a typo in a cvar must not unlock everything).
static func parse(p_choose: bool, allow_text: String, fixed_text: String, p_budget: int = 0) -> DotResult:
	var allow := parse_entries(allow_text, true)
	if not allow.ok:
		return allow.wrap("%s" % CVAR_ALLOW)
	var fix := parse_entries(fixed_text, false)
	if not fix.ok:
		return fix.wrap("%s" % CVAR_FIXED)

	var rules := DotLoadoutRules.new()
	rules.choose = p_choose
	rules.point_budget = maxi(0, p_budget)
	rules.allowed = allow.value
	for slot_id: StringName in (fix.value as Dictionary).keys():
		if slot_id == EVERY_SLOT:
			return DotResult.fail(DotError.CODE_INVALID, "%s: '*' cannot be fixed; name the slot." % CVAR_FIXED)
		var items: PackedStringArray = fix.value[slot_id]
		if items.size() != 1 or items[0].begins_with("-") or items[0].begins_with("tag:"):
			return DotResult.fail(DotError.CODE_INVALID,
				"%s: '%s' takes exactly one item id (or 'none')." % [CVAR_FIXED, slot_id])
		rules.fixed[slot_id] = &"" if items[0] == NONE else StringName(items[0])
	return DotResult.success(rules)


## `slot=a,b slot2=c` to slot id to [PackedStringArray]. [param lists] false is the fixed form,
## which the caller checks holds one entry per slot.
static func parse_entries(text: String, lists: bool = true) -> DotResult:
	var out: Dictionary = {}
	for raw in text.strip_edges().split(" ", false):
		var entry := raw.strip_edges()
		if entry == "":
			continue
		var eq := entry.find("=")
		if eq <= 0:
			return DotResult.fail(DotError.CODE_INVALID, "'%s' is not slot=item." % entry)
		var slot_id := StringName(entry.substr(0, eq).strip_edges().to_lower())
		var values := PackedStringArray()
		for v in entry.substr(eq + 1).split(",", false):
			var value := v.strip_edges().to_lower()
			if value == "" or value == "-" or value == "tag:" or value == "-tag:":
				continue
			values.append(value)
		if values.is_empty():
			return DotResult.fail(DotError.CODE_INVALID, "'%s' names no item." % entry)
		if out.has(slot_id):
			if not lists:
				return DotResult.fail(DotError.CODE_INVALID, "'%s' is named twice." % slot_id)
			var merged: PackedStringArray = out[slot_id]
			merged.append_array(values)
			out[slot_id] = merged
		else:
			out[slot_id] = values
	return DotResult.success(out)


## Whether these rules change anything at all.
func restricts() -> bool:
	return not choose or not allowed.is_empty() or not fixed.is_empty() or point_budget > 0


## Whether the server fills [param slot_id] itself.
func is_fixed(slot_id: StringName) -> bool:
	return fixed.has(slot_id)


## Whether [param item] may go in [param slot_id] under these rules. Says nothing about the schema
## or entitlements: the validator asks those separately.
func permits(slot_id: StringName, item: DotItem) -> bool:
	if item == null:
		return false
	if fixed.has(slot_id):
		return item.id == fixed[slot_id]
	return _passes(allowed.get(EVERY_SLOT, PackedStringArray()), item) \
		and _passes(allowed.get(slot_id, PackedStringArray()), item)


## One list of patterns: any forbid that matches refuses; with any allow present, one must match.
static func _passes(patterns: PackedStringArray, item: DotItem) -> bool:
	if patterns.is_empty():
		return true
	var has_allow := false
	var allowed_hit := false
	for p in patterns:
		var forbid := p.begins_with("-")
		var body := p.substr(1) if forbid else p
		var hit := _matches(body, item)
		if forbid:
			if hit:
				return false
		else:
			has_allow = true
			allowed_hit = allowed_hit or hit
	return allowed_hit or not has_allow


static func _matches(pattern: String, item: DotItem) -> bool:
	if pattern.begins_with("tag:"):
		return item.has_tag(StringName(pattern.substr(4)))
	return String(item.id).to_lower() == pattern


## Whether a player has anything to choose: choosing is on and some slot is not fixed.
func lets_players_choose(schema: DotLoadoutSchema) -> bool:
	if not choose:
		return false
	if schema == null:
		return true
	for slot in schema.ordered_slots():
		if not fixed.has(slot.id):
			return true
	return false


## Checks these rules against [param schema]: every slot named exists, every fixed item exists and
## fits its slot, and every required slot still has something legal. A failure names the first
## problem; a caller applying a cvar keeps its old rules on one, because a rule that empties a
## required slot is a player spawning with nothing in it.
func check(schema: DotLoadoutSchema) -> DotResult:
	if schema == null or schema.catalogue == null:
		return DotResult.fail(DotError.CODE_STATE, "No schema to check the loadout rules against.")
	for slot_id: StringName in allowed.keys():
		if slot_id != EVERY_SLOT and not schema.has_slot(slot_id):
			return DotResult.fail(DotError.CODE_INVALID,
				"There is no '%s' slot (slots: %s)." % [slot_id, ", ".join(_slot_names(schema))])
	for slot_id: StringName in fixed.keys():
		var slot := schema.slot(slot_id)
		if slot == null:
			return DotResult.fail(DotError.CODE_INVALID,
				"There is no '%s' slot (slots: %s)." % [slot_id, ", ".join(_slot_names(schema))])
		var item_id: StringName = fixed[slot_id]
		if item_id == &"":
			if slot.required:
				return DotResult.fail(DotError.CODE_INVALID, "The '%s' slot is required and cannot be fixed empty." % slot_id)
			continue
		var item := schema.catalogue.find(item_id)
		if item == null:
			return DotResult.fail(DotError.CODE_INVALID, "No item '%s' to fix in '%s'." % [item_id, slot_id])
		if not slot.accepts(item):
			return DotResult.fail(DotError.CODE_INVALID, slot.rejection(item))
	for slot in schema.required_slots():
		if schema.choices_for(slot.id, null, self).is_empty():
			return DotResult.fail(DotError.CODE_INVALID,
				"Nothing is left for the required '%s' slot under these rules." % slot.id)
	return DotResult.success(null)


static func _slot_names(schema: DotLoadoutSchema) -> PackedStringArray:
	var out := PackedStringArray()
	for slot in schema.ordered_slots():
		out.append(String(slot.id))
	return out


## The rules as the cvars would spell them, for a console line and describe().
func allow_text() -> String:
	return _entries_text(allowed, true)


func fixed_text() -> String:
	return _entries_text(fixed, false)


static func _entries_text(entries: Dictionary, lists: bool) -> String:
	var keys: Array = entries.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	var parts := PackedStringArray()
	for k: Variant in keys:
		if lists:
			parts.append("%s=%s" % [k, ",".join(entries[k] as PackedStringArray)])
		else:
			var v := String(entries[k] as StringName)
			parts.append("%s=%s" % [k, v if v != "" else NONE])
	return " ".join(parts)


## The rules as plain data, for a wire or a notice.
func to_dictionary() -> Dictionary:
	return {"choose": choose, "allow": allow_text(), "fixed": fixed_text(), "budget": point_budget}


static func from_dictionary(data: Dictionary) -> DotResult:
	return parse(bool(data.get("choose", true)), str(data.get("allow", "")), str(data.get("fixed", "")),
		int(data.get("budget", 0)))


func describe() -> Dictionary:
	return {"choose": choose, "allow": allow_text(), "fixed": fixed_text(), "budget": point_budget, "restricts": restricts()}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"players choose: %s" % ("yes" if choose else "no"),
		"allowed: %s" % (allow_text() if not allowed.is_empty() else "everything"),
		"fixed: %s" % (fixed_text() if not fixed.is_empty() else "nothing"),
		"point budget: %s" % (str(point_budget) if point_budget > 0 else "unlimited"),
	])


func _to_string() -> String:
	return "DotLoadoutRules(%s)" % ", ".join(describe_lines())
