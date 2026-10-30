class_name DotLoadoutCommand
extends RefCounted

## The server half of a loadout menu: the `loadout` command a client's B key sends, the
## `loadout_menu` notice it answers with, and the three `mp_loadout_*` cvars a server owner sets.
##
## [codeblock]
## # In a game's server module, after its DotLoadoutManager exists:
## var loadout_cmd := DotLoadoutCommand.new()
## loadout_cmd.manager = game.loadouts
## loadout_cmd.key_fn = func(ctx: Object) -> String: return "mygame-%d" % ctx.session.userid
## loadout_cmd.applied_fn = func(ctx: Object, key: String) -> bool: return game.rearm_if_allowed(key)
## loadout_cmd.bind(self)         # a DotModule: add_command, add_cvar
## [/codeblock]
##
## [b]Why a command and a notice, as the map menu does.[/b] A client opens the screen by sending
## `/loadout` through its chat (a prefixed line is a command and is never shown to anybody); the
## server answers with a notice on [constant TOPIC] carrying [method DotLoadoutManager.offer_for]:
## what this player may put in each slot under tonight's rules. Choosing sends
## `/loadout primary=rifle secondary=pistol ...`, which goes through
## [method DotLoadoutManager.publish] (the trust boundary: a hostile client typing the line gets
## exactly what the screen would have let it pick), and the result comes back as a notice too.
## No game needs a message type of its own, and every game on a dot-server has the same wire.
##
## [b]Nothing here names dot-server.[/b] The host is any object with `add_command(name, handler,
## description, permission)` and `add_cvar(name, default, description, flags)`; a command context
## is read for `args`, `session`, `reply` and `reply_lines`; the notice script is loaded by path and
## the server found as `dot_server` in [DotRegistry], as dot-vote's map menu does.

const CHANNEL := "loadout.command"

## The notice topic the answer travels on, and the command it answers.
const TOPIC := &"loadout_menu"
const COMMAND := "loadout"

const NOTICE_SCRIPT := "res://addons/dot_server/net/dot_notice.gd"

## dot-server's `DotConVar.FLAG_ARCHIVE | FLAG_NOTIFY`, by value: an owner's choice is saved, and a
## change is said in chat.
## The first words of the saved-loadout subcommands.
const SAVED_WORDS: Array[String] = ["save", "use", "rename", "delete"]

const CVAR_FLAGS := (1 << 0) | (1 << 3)

## The manager whose rules these are and that every choice is published to.
var manager: DotLoadoutManager = null

## `func(ctx: Object) -> String`: the loadout key of the player a command came from, or "" for
## the console (which gets the offer as lines and cannot choose).
var key_fn: Callable = Callable()

## `func(ctx: Object, key: String) -> bool` (may await), called after a choice is saved: true
## when the game put the new loadout in the player's hands now (warmup, spawn protection), false
## when it waits for the next spawn. Unset is always the next spawn.
var applied_fn: Callable = Callable()

## `func(key: String) -> String`: why choosing is closed right now for a reason that is the
## game's rather than the owner's (a mode that hands out the weapons), or "" when it is open. The
## offer then says so and lets nothing be picked, and a choice is refused with the same words.
var closed_fn: Callable = Callable()

## `func(ctx: Object, data: Dictionary) -> bool`: send [param data] to the player as a
## [constant TOPIC] notice. Unset uses dot-server's, found by path; a suite sets its own.
var notice_fn: Callable = Callable()

## The instant-swap rule ([DotLoadoutInstantSwap]); off until a game enables it.
var instant: DotLoadoutInstantSwap = DotLoadoutInstantSwap.new()

## `func(key: String) -> Dictionary` with `now`, `since_spawn`, `since_fire` (seconds, -1 for
## never) and `enemy_dist` (metres, -1 for none): the facts [member instant] judges. Unset: no
## instant swap.
var instant_facts_fn: Callable = Callable()

## `func(ctx: Object, key: String) -> bool` (may await): hands the saved loadout over now.
var instant_apply_fn: Callable = Callable()
## `func(item: StringName) -> StringName`: today's id for one a client remembered (a renamed or retired item); unset keeps ids as sent.
var item_alias_fn: Callable = Callable()

## The command's name: [constant COMMAND] unless a game already has one called that.
var command_name: String = COMMAND

## The three cvars, once [method bind] made them (or found them made).
var cvar_menu: Object = null
var cvar_allow: Object = null
var cvar_fixed: Object = null
## `mp_loadout_budget`: the point budget over the game's own, 0 keeping the game's (free by default).
var cvar_budget: Object = null

## `mp_loadout_max_saved`: saved loadouts per player, 0 unlimited.
var cvar_max_saved: Object = null

## `mp_loadout_store_max_bytes` / `_max_files`: the persistent store's caps.
var cvar_store_bytes: Object = null
var cvar_store_files: Object = null

## The Random entry's settings, read from the `mp_loadout_random*` cvars; a game sets the three
## callbacks below to tie it to its money and classes.
var random: DotLoadoutRandom = DotLoadoutRandom.new()
## `func(key: String) -> StringName`: the player's class id, or unset for none.
var class_fn: Callable = Callable()
## `func(class_id: StringName) -> DotLoadoutRules`: what that class may carry, or null.
var class_rules_fn: Callable = Callable()
## `func(key: String) -> int`: the player's money, -1 for no limit. Unset: no limit.
var money_fn: Callable = Callable()
## `func(key: String, amount: int) -> bool`: takes money (a negative amount refunds). Unset: nothing is taken.
var charge_fn: Callable = Callable()
var random_cvars: Dictionary = {}

## The last answers, for a suite and describe().
var last_offer: Dictionary = {}
var last_result: Dictionary = {}
## The last rules refusal: a cvar the manager did not take, and why.
var last_refusal: String = ""


## Registers the command (typable in chat) and the three cvars on [param host], reusing cvars
## already registered (a second module on the same server reads the same owner settings).
func bind(host: Object, command_adder: String = "add_command", cvar_adder: String = "add_cvar") -> void:
	if host == null:
		return
	if host.has_method(command_adder):
		var made: Variant = host.call(command_adder, command_name, _cmd,
			"Your loadout: with no arguments the menu; slot=item ... to choose", "")
		if made is Object and (made as Object).has_method("with_chat"):
			(made as Object).call("with_chat")
	cvar_menu = _cvar(host, cvar_adder, DotLoadoutRules.CVAR_MENU, "1",
		"Players choose their loadout on B (1), or everybody spawns with the defaults and the fixed slots (0)")
	cvar_allow = _cvar(host, cvar_adder, DotLoadoutRules.CVAR_ALLOW, "",
		"What each loadout slot may hold: slot=item,tag:x,-item ... ('*' is every slot). Empty: anything")
	cvar_fixed = _cvar(host, cvar_adder, DotLoadoutRules.CVAR_FIXED, "",
		"Slots the server fills for everybody: slot=item ... ('none' keeps one empty)")
	cvar_budget = _cvar(host, cvar_adder, DotLoadoutRules.CVAR_BUDGET, "0",
		"Loadout point budget; items cost their loadout_cost in the weapon profile. 0 is the game's own (free by default)")
	cvar_max_saved = _cvar(host, cvar_adder, DotLoadoutRules.CVAR_MAX_SAVED, "0",
		"Loadouts a player may save under their name; 0 is unlimited")
	if cvar_max_saved != null and cvar_max_saved.has_signal(&"changed") \
			and not cvar_max_saved.is_connected(&"changed", _on_max_saved_changed):
		cvar_max_saved.connect(&"changed", _on_max_saved_changed)
	_on_max_saved_changed("", "")
	cvar_store_bytes = _cvar(host, cvar_adder, DotLoadoutRules.CVAR_STORE_MAX_BYTES, "65536",
		"Largest saved-loadout file for one player, in bytes; 0 is unlimited")
	cvar_store_files = _cvar(host, cvar_adder, DotLoadoutRules.CVAR_STORE_MAX_FILES, "20000",
		"Most players whose saved loadouts are kept on disk; 0 is unlimited")
	for c: Object in [cvar_store_bytes, cvar_store_files]:
		if c != null and c.has_signal(&"changed") and not c.is_connected(&"changed", _on_store_caps_changed):
			c.connect(&"changed", _on_store_caps_changed)
	_on_store_caps_changed("", "")
	var _instant_cvars := instant.bind_cvars(
		func(n: String, d: String, h: String, f: int) -> Object: return _cvar(host, cvar_adder, n, d, h), CVAR_FLAGS)
	_bind_random(host, cvar_adder)
	for c: Object in [cvar_menu, cvar_allow, cvar_fixed, cvar_budget]:
		if c != null and c.has_signal(&"changed") and not c.is_connected(&"changed", _on_cvar_changed):
			c.connect(&"changed", _on_cvar_changed)
	# A value the rules cannot take is refused AT THE CONSOLE, so it never sits in the cvar: one
	# left there would make every later change to the other two fail the same check.
	# Methods, never lambdas: a lambda captures this object and the cvar would keep it alive.
	if cvar_allow != null and "validator" in cvar_allow:
		cvar_allow.set(&"validator", _vet_allow)
	if cvar_fixed != null and "validator" in cvar_fixed:
		cvar_fixed.set(&"validator", _vet_fixed)
	var _applied := refresh_rules()


func _cvar(host: Object, adder: String, cvar_name: String, default: String, help: String) -> Object:
	var console: Variant = host if host.has_method("find_cvar") else host.get("console")
	if console is Object and (console as Object).has_method("find_cvar"):
		var existing: Variant = (console as Object).call("find_cvar", cvar_name)
		if existing is Object:
			return existing
	if not host.has_method(adder):
		return null
	var made: Variant = host.call(adder, cvar_name, default, help, CVAR_FLAGS)
	return made if made is Object else null


func _bind_random(host: Object, adder: String) -> void:
	var defs := [
		[DotLoadoutRandom.CVAR_ENABLED, "1", "The loadout menu offers a Random entry that rolls new items every time (1), or not (0)"],
		[DotLoadoutRandom.CVAR_COUNT, "0", "Slots Random re-rolls per use; 0 is every slot you may change"],
		[DotLoadoutRandom.CVAR_SLOTS, "", "Slots Random may draw for: primary,secondary ... Empty: all"],
		[DotLoadoutRandom.CVAR_PRICE, "free", "What Random costs: free, sum (the items' prices) or flat:N"],
		[DotLoadoutRandom.CVAR_DUPES, "0", "Random may put the same item in two slots (1) or not (0)"],
		[DotLoadoutRandom.CVAR_SEED, "0", "Seed for Random's rolls: 0 is unseeded, anything else repeats (tests)"],
		[DotLoadoutRandom.CVAR_SPAWN, "1", "Random loadout at every spawn: 0 off, 1 each player's toggle, 2 forced for everybody"],
		[DotLoadoutRandom.CVAR_CLASS, "", "Per class: class.count=2 class.slots=primary+secondary class.price=flat:50"],
	]
	for d: Array in defs:
		var c := _cvar(host, adder, d[0], d[1], d[2])
		random_cvars[d[0]] = c
		if c != null and c.has_signal(&"changed") and not c.is_connected(&"changed", _on_random_cvar_changed):
			c.connect(&"changed", _on_random_cvar_changed)
	var _r := refresh_random()


func _on_random_cvar_changed(_old: String, _new: String) -> void:
	var _r := refresh_random()


## Reads the `mp_loadout_random*` cvars into [member random]; an unreadable value keeps the old settings.
func refresh_random() -> DotResult:
	var c := func(n: String) -> Object: return random_cvars.get(n)
	var seed_text := _cvar_string(c.call(DotLoadoutRandom.CVAR_SEED)).strip_edges()
	var res := random.configure(
		_cvar_bool(c.call(DotLoadoutRandom.CVAR_ENABLED), true),
		int(_cvar_string(c.call(DotLoadoutRandom.CVAR_COUNT)).to_int()),
		_cvar_string(c.call(DotLoadoutRandom.CVAR_SLOTS)),
		_cvar_string(c.call(DotLoadoutRandom.CVAR_PRICE)),
		_cvar_bool(c.call(DotLoadoutRandom.CVAR_DUPES), false),
		seed_text.to_int(),
		_cvar_string(c.call(DotLoadoutRandom.CVAR_CLASS)),
		_cvar_string(c.call(DotLoadoutRandom.CVAR_SPAWN)).to_int() if c.call(DotLoadoutRandom.CVAR_SPAWN) != null \
		else DotLoadoutRandom.SPAWN_ALLOWED)
	if not res.ok:
		DotLog.warn(CHANNEL, "random loadout settings refused; keeping the old ones", {"why": res.error.message})
	return res


func _on_max_saved_changed(_old: String, _new: String) -> void:
	if manager != null and manager.config != null:
		manager.config.max_per_player = maxi(0, _cvar_string(cvar_max_saved).to_int())


func _on_store_caps_changed(_old: String, _new: String) -> void:
	if manager == null or manager.store == null:
		return
	var target: Object = manager.store.get(&"durable") if "durable" in manager.store else manager.store
	if target != null and "max_file_bytes" in target:
		target.set(&"max_file_bytes", maxi(0, _cvar_string(cvar_store_bytes).to_int()))
		target.set(&"max_files", maxi(0, _cvar_string(cvar_store_files).to_int()))


func _on_cvar_changed(_old: String, _new: String) -> void:
	var _r := refresh_rules()


## Reads the cvars and puts the rules on the manager. A failure (an unreadable value, a slot that
## does not exist, a required slot left with nothing) keeps the rules the manager had and logs a
## WARN naming the cvar: a typo must not unlock everything, or lock everybody out.
func refresh_rules() -> DotResult:
	return apply_strings(_cvar_bool(cvar_menu, true), _cvar_string(cvar_allow), _cvar_string(cvar_fixed),
		_cvar_string(cvar_budget).to_int())


func _vet_allow(v: String) -> DotResult:
	return _would_take(_cvar_bool(cvar_menu, true), v, _cvar_string(cvar_fixed), _cvar_string(cvar_budget).to_int())


func _vet_fixed(v: String) -> DotResult:
	return _would_take(_cvar_bool(cvar_menu, true), _cvar_string(cvar_allow), v, _cvar_string(cvar_budget).to_int())


## Whether the manager would take these three values: parsed and checked against its schema.
func _would_take(menu_on: bool, allow_text: String, fixed_text: String, budget: int = 0) -> DotResult:
	var parsed := DotLoadoutRules.parse(menu_on, allow_text, fixed_text, budget)
	if not parsed.ok or manager == null:
		return parsed
	return (parsed.value as DotLoadoutRules).check(manager.schema)


## The rules from the three values, without cvars (solo, a suite).
func apply_strings(menu_on: bool, allow_text: String, fixed_text: String, budget: int = 0) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "No loadout manager.")
	var parsed := DotLoadoutRules.parse(menu_on, allow_text, fixed_text, budget)
	if parsed.ok:
		var checked := (parsed.value as DotLoadoutRules).check(manager.schema)
		if not checked.ok:
			parsed = checked
	if not parsed.ok:
		last_refusal = parsed.error.message
		DotLog.warn(CHANNEL, "loadout rules refused; keeping the old ones", {
			"why": parsed.error.message, "allow": allow_text, "fixed": fixed_text,
		})
		return parsed
	last_refusal = ""
	var rules: DotLoadoutRules = parsed.value
	manager.set_rules(rules if rules.restricts() else null)
	return DotResult.success(rules)


static func _cvar_string(c: Object) -> String:
	return str(c.call("get_string")) if c != null and c.has_method("get_string") else ""


static func _cvar_bool(c: Object, fallback: bool) -> bool:
	if c == null or not c.has_method("get_string"):
		return fallback
	var v := str(c.call("get_string")).strip_edges().to_lower()
	return not (v == "0" or v == "false" or v == "off" or v == "no")


## What [param key] may choose: [method DotLoadoutManager.offer_for]'s dictionary; with
## [param include_locked] also the items it does not own (`/loadout locked` on the wire).
func offer(key: String, include_locked: bool = false) -> Dictionary:
	if manager == null:
		return {}
	var res: DotResult = await manager.offer_for(key, include_locked)
	last_offer = res.value if res.ok else {}
	var why := closed_reason(key)
	if why != "" and not last_offer.is_empty():
		last_offer["choose"] = false
		last_offer["note"] = why
	if not last_offer.is_empty():
		last_offer["saved"] = manager.saved_list(key)
		last_offer["max_saved"] = manager.config.max_per_player
		var cls := _class_of(key)
		last_offer["random"] = {"enabled": random.enabled and bool(last_offer.get("choose", false)),
			"price": random.price_text(cls), "count": int(random.effective(cls)["count"]),
			"spawn": random.spawn_rule(cls), "spawn_on": manager.random_spawn_for(key)}
	return last_offer


## [member closed_fn]'s answer for [param key], or "".
func closed_reason(key: String) -> String:
	return str(closed_fn.call(key)) if closed_fn.is_valid() else ""


## Publishes the choice [param picks] (slot id to item id; slots left out keep what the player
## has) for [param key]. Returns `{ok, text, now}`; `now` is whether the game handed it over at
## once ([member applied_fn]).
func choose(ctx: Object, key: String, picks: Dictionary) -> Dictionary:
	if manager == null:
		return _result(false, "This game has no loadouts.", false)
	if key == "":
		return _result(false, "Only a player has a loadout.", false)
	if not manager.players_choose():
		return _result(false, "The server sets every loadout here.", false)
	var why := closed_reason(key)
	if why != "":
		return _result(false, why, false)
	var active: DotResult = await manager.active_for(key)
	var loadout: DotLoadout = (active.value as DotLoadout).duplicate_loadout() if active.ok \
		else manager.schema.default_loadout()
	for slot_id: Variant in picks.keys():
		var item := StringName(str(picks[slot_id]))
		if item_alias_fn.is_valid() and item != &"":
			item = StringName(str(item_alias_fn.call(item)))
		if item == &"" or str(item) == DotLoadoutRules.NONE:
			loadout.clear_slot(StringName(str(slot_id)))
		else:
			loadout.set_item(StringName(str(slot_id)), item)
	return await _commit(ctx, key, loadout)


## Rolls a random loadout for [param key] ([member random]); refused when the server turned it off,
## so a modified client gains nothing from sending it. Charges per the price setting.
func choose_random(ctx: Object, key: String) -> Dictionary:
	if manager == null:
		return _result(false, "This game has no loadouts.", false)
	if key == "":
		return _result(false, "Only a player has a loadout.", false)
	if not random.enabled:
		return _result(false, "Random loadouts are off on this server.", false)
	if not manager.players_choose():
		return _result(false, "The server sets every loadout here.", false)
	var why := closed_reason(key)
	if why != "":
		return _result(false, why, false)
	var active: DotResult = await manager.active_for(key)
	var current: DotLoadout = active.value if active.ok else manager.schema.default_loadout()
	var cls := _class_of(key)
	var rules: DotLoadoutRules = null
	if class_rules_fn.is_valid():
		rules = class_rules_fn.call(cls)
	var money := int(money_fn.call(key)) if money_fn.is_valid() else -1
	var rolled := random.roll(manager, key, current, cls, rules, money)
	if not rolled.ok:
		return _result(false, rolled.error.message, false)
	var spent := int(rolled.value["spent"])
	var charged := spent > 0 and charge_fn.is_valid()
	if charged and not bool(charge_fn.call(key, spent)):
		return _result(false, "You cannot afford that.", false)
	var out := await _commit(ctx, key, rolled.value["loadout"])
	out["random"] = true
	if charged and not bool(out["ok"]):
		var _refund: Variant = charge_fn.call(key, -spent)
	return out


## `randomspawn on|off`: the player's "random every spawn" toggle, saved with their loadouts.
func set_random_spawn(key: String, on: bool) -> Dictionary:
	if manager == null or key == "":
		return _result(false, "Only a player has a loadout.", false)
	if random.spawn_rule(_class_of(key)) == DotLoadoutRandom.SPAWN_OFF:
		return _result(false, "Random at every spawn is off on this server (%s)." % DotLoadoutRandom.CVAR_SPAWN, false)
	var res: DotResult = await manager.set_random_spawn(key, on)
	if not res.ok:
		return _result(false, str(res.error.message), false)
	return _result(true, "Random loadout at every spawn: %s." % ("on" if on else "off"), false)


## The loadout [param key] gets at this spawn when random-at-spawn applies, else null. It is rolled
## per spawn and never saved, so switching the toggle off brings the player's own loadout back; a
## roll that fails (nothing legal) also returns null. Bots have no key here and keep theirs.
func roll_for_spawn(key: String) -> DotLoadout:
	if manager == null or key == "" or not manager.players_choose() or closed_reason(key) != "":
		return null
	var cls := _class_of(key)
	await manager.load_for(key)
	if not random.rolls_on_spawn(cls, manager.random_spawn_for(key)):
		return null
	var active: DotResult = await manager.active_for(key)
	var current: DotLoadout = active.value if active.ok else manager.schema.default_loadout()
	var rules: DotLoadoutRules = class_rules_fn.call(cls) if class_rules_fn.is_valid() else null
	var rolled := random.roll(manager, key, current, cls, rules, -1)
	if not rolled.ok:
		DotLog.debug(CHANNEL, "spawn roll refused", {"key": key, "why": rolled.error.message})
		return null
	return rolled.value["loadout"]


## The toast for a spawn roll: "Random loadout: Rifle, Pistol, Knife".
func spawn_text(loadout: DotLoadout) -> String:
	var names := PackedStringArray()
	for slot_id in loadout.filled_slots():
		var id := loadout.item_in(slot_id)
		var item: DotItem = manager.schema.catalogue.find(id) if manager.schema.catalogue != null else null
		names.append(item.display_name if item != null and item.display_name != "" else str(id).capitalize())
	return "Random loadout: " + ", ".join(names)


## `save NAME [slot=item ...]`, `use N`, `rename N NAME`, `delete N` (N counts from 1) on a player's
## saved loadouts. A choice still goes through [method choose]'s checks (rules, closed, the cap).
func manage(ctx: Object, key: String, args: PackedStringArray) -> Dictionary:
	if manager == null or key == "":
		return _result(false, "Only a player has loadouts.", false)
	if not manager.players_choose():
		return _result(false, "The server sets every loadout here.", false)
	var verb := args[0].to_lower()
	var words := args.slice(1)
	var at := -1
	if verb != "save":
		at = (words[0].to_int() - 1) if not words.is_empty() and words[0].is_valid_int() else -1
		words = words.slice(1)
	var res: DotResult
	var text := ""
	await manager.load_for(key)
	if verb == "save":
		var picks := PackedStringArray()
		var label := PackedStringArray()
		for w in words:
			(picks if "=" in w else label).append(w)
		var made := parse_choice(picks)
		if not made.ok:
			return _result(false, made.error.message, false)
		var active: DotResult = await manager.active_for(key)
		var base: DotLoadout = (active.value as DotLoadout).duplicate_loadout() if active.ok else manager.schema.default_loadout()
		for slot_id: Variant in (made.value as Dictionary).keys():
			base.set_item(StringName(str(slot_id)), StringName(str((made.value as Dictionary)[slot_id])))
		res = await manager.save_as(key, base, " ".join(label))
		text = "Loadout saved."
	elif verb == "use":
		res = await manager.select(key, at)
		text = "Loadout selected: you get it when you next spawn."
		if res.ok and applied_fn.is_valid():
			text = "Loadout equipped." if bool(await applied_fn.call(ctx, key)) else text
	elif verb == "rename":
		res = await manager.rename(key, at, " ".join(words))
		text = "Loadout renamed."
	else:
		res = await manager.remove(key, at)
		text = "Loadout deleted."
	return _result(res.ok, text if res.ok else str(res.error.message), false)


func _class_of(key: String) -> StringName:
	return StringName(str(class_fn.call(key))) if class_fn.is_valid() else &""


func _commit(ctx: Object, key: String, loadout: DotLoadout) -> Dictionary:
	var published: DotResult = await manager.publish_selected(key, loadout)
	if not published.ok:
		return _result(false, published.error.message, false)
	var now := false
	if applied_fn.is_valid():
		var got: Variant = await applied_fn.call(ctx, key)
		now = bool(got)
	var note := ""
	if not now and instant_facts_fn.is_valid() and instant_apply_fn.is_valid():
		var f: Dictionary = instant_facts_fn.call(key)
		var t := float(f.get("now", 0.0))
		note = instant.decide(key, t, float(f.get("since_spawn", -1.0)), float(f.get("since_fire", -1.0)),
			float(f.get("enemy_dist", -1.0)))
		if note == "":
			now = bool(await instant_apply_fn.call(ctx, key))
			if now:
				instant.mark(key, t)
	DotLog.debug(CHANNEL, "loadout chosen", {"key": key, "loadout": loadout.to_json(), "now": now, "why": note})
	if now:
		return _result(true, "Loadout equipped.", now)
	var text := "Loadout saved: you get it when you next spawn."
	return _result(true, text + (" " + note if note != "" and instant.enabled else ""), now)


## `slot=item slot=item` (args or one line) to slot id to item id. Fails on a word that is not
## `slot=item`, so a typo is an answer rather than a silent nothing.
static func parse_choice(words: Variant) -> DotResult:
	var text := " ".join(words as PackedStringArray) if words is PackedStringArray else str(words)
	var out: Dictionary = {}
	for raw in text.strip_edges().split(" ", false):
		var eq := raw.find("=")
		if eq <= 0:
			return DotResult.fail(DotError.CODE_INVALID, "'%s' is not slot=item." % raw)
		out[raw.substr(0, eq).strip_edges().to_lower()] = raw.substr(eq + 1).strip_edges().to_lower()
	return DotResult.success(out)


## The line a client sends for [param picks] (slot id to item id), slots in text order.
static func choice_text(picks: Dictionary) -> String:
	var keys: Array = picks.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	var parts := PackedStringArray()
	for k: Variant in keys:
		var v := str(picks[k])
		parts.append("%s=%s" % [k, v if v != "" else DotLoadoutRules.NONE])
	return " ".join(parts)


func _result(ok: bool, text: String, now: bool) -> Dictionary:
	last_result = {"ok": ok, "text": text, "now": now}
	return last_result


func _key(ctx: Object) -> String:
	if not key_fn.is_valid() or ctx == null:
		return ""
	return str(key_fn.call(ctx))


func _cmd(ctx: Object) -> void:
	var args_v: Variant = ctx.get("args")
	var args: PackedStringArray = args_v if args_v is PackedStringArray else PackedStringArray()
	var key := _key(ctx)
	var want_locked := args.size() == 1 and args[0].to_lower() == "locked"
	if args.is_empty() or want_locked:
		var data: Dictionary = await offer(key, want_locked)
		if key == "" or not _send(ctx, data):
			# A console, or a client with no notices: the rules and the slots as lines.
			var lines := PackedStringArray()
			if manager != null and manager.rules != null:
				lines.append_array(manager.rules.describe_lines())
			for s: Variant in data.get("slots", []):
				var slot := s as Dictionary
				var ids := PackedStringArray()
				for c: Variant in slot.get("choices", []):
					ids.append(str((c as Dictionary).get("id", "")))
				lines.append("%s%s: %s" % [slot.get("id", ""), " (fixed)" if bool(slot.get("fixed", false)) else "", ", ".join(ids)])
			if ctx.has_method("reply_lines"):
				ctx.call("reply_lines", lines)
		return
	var parsed := parse_choice(args)
	var result: Dictionary
	if args[0].to_lower() in SAVED_WORDS:
		result = await manage(ctx, key, args)
	elif args.size() == 1 and args[0].to_lower() == "random":
		result = await choose_random(ctx, key)
	elif args.size() == 2 and args[0].to_lower() == "randomspawn":
		result = await set_random_spawn(key, args[1].to_lower() in ["on", "1", "true"])
	elif not parsed.ok:
		result = _result(false, parsed.error.message, false)
	else:
		result = await choose(ctx, key, parsed.value)
	if not _send(ctx, {"result": result}) and ctx.has_method("reply"):
		ctx.call("reply", str(result["text"]))


func _send(ctx: Object, data: Dictionary) -> bool:
	if notice_fn.is_valid():
		return bool(notice_fn.call(ctx, data))
	var session: Variant = ctx.get("session") if ctx != null else null
	if not (session is Object) or not ResourceLoader.exists(NOTICE_SCRIPT):
		return false
	var server: Object = DotRegistry.get_service(&"dot_server")
	if server == null or not server.has_method("send_notice"):
		return false
	var notice: Object = (load(NOTICE_SCRIPT) as GDScript).call("make", &"", "", -1.0, TOPIC, data)
	return bool(server.call("send_notice", session, notice))


func describe() -> Dictionary:
	return {
		"command": command_name, "cvars": cvar_menu != null,
		"rules": manager.rules.describe() if manager != null and manager.rules != null else {"restricts": false},
		"random": random.describe(), "last_result": last_result.get("text", ""), "last_refusal": last_refusal,
	}
