extends "loadout_demo_b.gd"

## Suite part: pickups, rules, command and instant swap.


# Pickups

func _test_pickups() -> void:
	_section("pickups")

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

	_check_pickups_client(field, health, ammo)
	_check_freed_pickup(field)

	field.queue_free()
	remove_child(field)
	_done()


func _check_pickups_client(field: DotPickupField, health: DotPickup, ammo: DotPickup) -> void:
	# A client instance reports what is nearby and takes nothing.
	field.reset(400)
	field.is_authority = false
	field.wants_fn = Callable()
	var previewed := field.sweep(12, Vector3.ZERO, 400)
	_check(previewed.size() == 1, "a client still reports what it is standing on")
	_check(health.available, "but takes nothing")

	field.is_authority = true
	ammo.free()
	_check(field.sweep(13, Vector3.ZERO, 500).size() == 1 and field.pickups().size() == 1, "a pickup freed since the refresh is dropped, not touched")



func _check_freed_pickup(field: DotPickupField) -> void:
	# Every accessor, with a pickup freed after the refresh, must not touch it.
	var doomed := DotPickup.new()
	doomed.item_id = &"doomed"
	field.add_child(doomed)
	field.refresh()
	doomed.free()
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var live := 0
	var held := 0
	for entry: Variant in field.pickups():
		held += 1
		if is_instance_valid(entry):
			live += 1
	var counted: int = field.describe()["pickups"]
	var lines := field.describe_lines()
	field.reset(600)
	OS.remove_logger(catcher)
	_check(live == held, "pickups() holds no freed entry")
	_check(counted == live, "describe() counts only live pickups")
	_check(lines.size() == live + 1, "describe_lines() lists only live pickups")
	_check(catcher.errors.is_empty(), "and none of that raised an engine error", str(catcher.errors))


# A server owner's rules

func _test_rules() -> void:
	_section("server rules")

	var starter: DotResult = DotLoadoutRules.parse(true, "primary=tag:starter secondary=pistol", "")
	_check(starter.ok, "an allow list parses")
	var rules: DotLoadoutRules = starter.value
	_check(rules.permits(&"primary", _catalogue.find(&"rifle")), "an item with the tag is permitted")
	_check(not rules.permits(&"primary", _catalogue.find(&"sniper")), "one without it is not")
	_check(rules.permits(&"utility", _catalogue.find(&"grenade")), "a slot the rules do not name is open")

	var no_boom: DotLoadoutRules = DotLoadoutRules.parse(true, "*=-tag:explosive", "").value
	_check(
		no_boom.permits(&"primary", _catalogue.find(&"sniper"))
			and not no_boom.permits(&"primary", _catalogue.find(&"rocket")),
		"a forbid on every slot takes out only what it names"
	)

	_check(not DotLoadoutRules.parse(true, "primary", "").ok, "a word that is not slot=item is refused")
	_check(not DotLoadoutRules.parse(true, "", "primary=rifle,sniper").ok, "a fixed slot takes one item")
	_check(not DotLoadoutRules.parse(true, "", "*=rifle").ok, "and '*' cannot be fixed")

	var schema := _build_schema()
	_check(
		not DotLoadoutRules.parse(true, "barrel=rifle", "").value.check(schema).ok,
		"a slot the schema does not have is refused by check()"
	)
	_check(
		not DotLoadoutRules.parse(true, "", "primary=none").value.check(schema).ok,
		"a required slot cannot be fixed empty"
	)
	_check(
		not DotLoadoutRules.parse(true, "primary=tag:nothing", "").value.check(schema).ok,
		"rules that leave a required slot nothing are refused"
	)
	_check(
		DotLoadoutRules.parse(true, "", "primary=sniper").value.check(schema).ok,
		"fixing an item nobody has unlocked is the owner's call"
	)

	var only_sniper: DotLoadoutRules = DotLoadoutRules.parse(true, "primary=sniper", "").value
	var everything := DotLoadoutEntitlements.everything()
	var ids := schema.choices_for(&"primary", everything, only_sniper).map(func(i: DotItem) -> StringName: return i.id)
	_check(ids == [&"sniper"], "choices_for honours the rules", str(ids))

	var refused := DotLoadoutValidator.validate(_full_loadout(), schema, everything, only_sniper)
	_check(
		not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN,
		"validate refuses an item the server does not allow"
	)

	var repaired := _full_loadout()
	var _changes := DotLoadoutValidator.conform(repaired, schema, everything, only_sniper)
	_check(repaired.item_in(&"primary") == &"sniper", "conform swaps a disallowed item for an allowed one")

	var fixed_rules: DotLoadoutRules = DotLoadoutRules.parse(true, "", "primary=sniper utility=none").value
	var fixed := _full_loadout()
	var _f := DotLoadoutValidator.conform(fixed, schema, DotLoadoutEntitlements.none(), fixed_rules)
	_check(
		fixed.item_in(&"primary") == &"sniper" and not fixed.has_slot(&"utility"),
		"conform writes the fixed slots, unlocked or not, and empties a 'none'"
	)
	_check(
		DotLoadoutValidator.validate(fixed, schema, DotLoadoutEntitlements.none(), fixed_rules).ok,
		"and the result validates"
	)

	var round: DotResult = DotLoadoutRules.from_dictionary(fixed_rules.to_dictionary())
	_check(
		round.ok and (round.value as DotLoadoutRules).fixed_text() == fixed_rules.fixed_text(),
		"rules survive a dictionary round trip", fixed_rules.fixed_text()
	)
	_done()


func _test_manager_rules() -> void:
	_section("manager under rules")

	var manager := _make_manager()
	var key := "player-rules-0001"
	var wanted := _full_loadout()
	wanted.set_item(&"utility", &"medkit")
	var published: DotResult = await manager.publish(key, wanted)
	_check(published.ok, "a loadout publishes with no rules")

	manager.set_rules(DotLoadoutRules.parse(true, "", "utility=grenade").value)
	var active: DotResult = await manager.active_for(key)
	_check((active.value as DotLoadout).item_in(&"utility") == &"grenade", "a fixed slot overrides the saved choice")
	var saved: DotResult = await manager.load_for(key)
	_check(
		((saved.value as Array)[0] as DotLoadout).item_in(&"utility") == &"medkit",
		"without writing over what the player saved"
	)

	manager.set_rules(null)
	var back: DotResult = await manager.active_for(key)
	_check((back.value as DotLoadout).item_in(&"utility") == &"medkit", "lifting the rule gives the choice back")

	manager.set_rules(DotLoadoutRules.parse(false, "", "").value)
	_check(not manager.players_choose(), "with choosing off nobody chooses")
	var locked: DotResult = await manager.publish(key, wanted)
	_check(not locked.ok, "and a publish is refused")
	var defaults: DotResult = await manager.active_for(key)
	_check(not (defaults.value as DotLoadout).has_slot(&"utility"), "everybody spawns with the defaults")

	manager.set_rules(DotLoadoutRules.parse(true, "utility=grenade", "").value)
	var offer: DotResult = await manager.offer_for(key)
	_check(offer.ok and (offer.value["slots"] as Array).size() == 5, "the offer lists every slot")
	var primary: Dictionary = (offer.value["slots"] as Array)[0]
	var primary_ids: Array = (primary["choices"] as Array).map(func(c: Variant) -> String: return str(c["id"]))
	_check(
		primary["id"] == "primary" and primary_ids.has("rifle") and not primary_ids.has("sniper"),
		"with only what this player may take", str(primary_ids)
	)
	var utility: Dictionary = (offer.value["slots"] as Array)[2]
	_check(
		(utility["choices"] as Array).size() == 1 and offer.value["note"] != "",
		"what the owner allows, and a note saying it is limited"
	)
	var medkit := _full_loadout()
	medkit.set_item(&"utility", &"medkit")
	var refused: DotResult = await manager.publish(key, medkit)
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN, "publish refuses what the owner does not allow")

	manager.queue_free()
	_done()


class FakeCvar extends RefCounted:
	signal changed(old_value: String, new_value: String)
	var value := ""
	var validator: Callable = Callable()

	func get_string() -> String:
		return value

	func set_to(v: String) -> void:
		var was := value
		value = v
		changed.emit(was, v)


class FakeHost extends RefCounted:
	var commands: Dictionary = {}
	var cvars: Dictionary = {}

	func add_command(command_name: String, handler: Callable, _d: String = "", _p: String = "") -> Object:
		commands[command_name] = handler
		return null

	func add_cvar(cvar_name: String, default: String, _d: String = "", _f: int = 0) -> Object:
		var c := FakeCvar.new()
		c.value = default
		cvars[cvar_name] = c
		return c


class FakeCtx extends RefCounted:
	var args := PackedStringArray()
	var session: Object = null
	var replies := PackedStringArray()

	func reply(text: String) -> void:
		replies.append(text)

	func reply_lines(lines: PackedStringArray) -> void:
		replies.append_array(lines)


func _test_command() -> void:
	_section("the loadout command")

	var manager := _make_manager()
	var cmd := DotLoadoutCommand.new()
	cmd.manager = manager
	cmd.key_fn = func(_ctx: Object) -> String: return "player-cmd-0001"
	var sent: Array = []
	cmd.notice_fn = func(_ctx: Object, data: Dictionary) -> bool:
		sent.append(data)
		return true
	var equipped_now := [false]
	cmd.applied_fn = func(_ctx: Object, _key: String) -> bool: return equipped_now[0]

	var host := FakeHost.new()
	cmd.bind(host)
	_check(host.commands.has("loadout") and host.cvars.size() == 20, "bind registers the command, five rule cvars, two store-cap cvars, five instant-swap cvars and eight random cvars")

	(host.cvars[DotLoadoutRules.CVAR_ALLOW] as FakeCvar).set_to("utility=grenade")
	_check(manager.rules != null and manager.rules.allowed.has(&"utility"), "a cvar change puts the rules on the manager")
	var vetted: DotResult = (host.cvars[DotLoadoutRules.CVAR_ALLOW] as FakeCvar).validator.call("barrel=rifle")
	_check(not vetted.ok, "the cvar's validator refuses a value the rules cannot take, before it is set")
	(host.cvars[DotLoadoutRules.CVAR_ALLOW] as FakeCvar).set_to("barrel=rifle")
	_check(
		manager.rules != null and manager.rules.allowed.has(&"utility") and cmd.last_refusal != "",
		"a bad value keeps the old rules and says why", cmd.last_refusal
	)
	(host.cvars[DotLoadoutRules.CVAR_ALLOW] as FakeCvar).set_to("")
	_check(manager.rules == null, "an empty value is no restriction")

	var ctx := FakeCtx.new()
	var handler: Callable = host.commands["loadout"]
	await handler.call(ctx)
	_check(sent.size() == 1 and (sent[0] as Dictionary).has("slots"), "the bare command answers with the offer")

	ctx.args = PackedStringArray(["utility=medkit"])
	await handler.call(ctx)
	var result: Dictionary = (sent[-1] as Dictionary).get("result", {})
	_check(bool(result.get("ok", false)) and not bool(result.get("now", true)), "a choice saves for the next spawn", str(result))
	var active: DotResult = await manager.active_for("player-cmd-0001")
	_check((active.value as DotLoadout).item_in(&"utility") == &"medkit", "and is the player's loadout")

	equipped_now[0] = true
	ctx.args = PackedStringArray(["primary=rifle"])
	await handler.call(ctx)
	_check(bool((sent[-1] as Dictionary)["result"].get("now", false)), "the game may hand it over at once")

	ctx.args = PackedStringArray(["primary=rocket"])
	await handler.call(ctx)
	_check(not bool((sent[-1] as Dictionary)["result"].get("ok", true)), "an item not unlocked is refused through the command")

	cmd.closed_fn = func(_key: String) -> String: return "This mode hands out the weapons."
	var closed_offer: Dictionary = await cmd.offer("player-cmd-0001")
	var closed_choice: Dictionary = await cmd.choose(ctx, "player-cmd-0001", {"utility": "grenade"})
	_check(closed_offer["choose"] == false and closed_offer["note"] == "This mode hands out the weapons." \
		and not bool(closed_choice["ok"]), "a game can close the menu for its own reason, and says it")
	cmd.closed_fn = Callable()

	(host.cvars[DotLoadoutRules.CVAR_MENU] as FakeCvar).set_to("0")
	ctx.args = PackedStringArray(["utility=grenade"])
	await handler.call(ctx)
	_check(not bool((sent[-1] as Dictionary)["result"].get("ok", true)), "with the menu off a choice is refused")

	_check(not DotLoadoutCommand.parse_choice("primary=rifle oops").ok, "a word that is not slot=item is an answer")
	var picks: Dictionary = DotLoadoutCommand.parse_choice(DotLoadoutCommand.choice_text({"secondary": "pistol", "primary": "rifle"})).value
	_check(picks.get("primary") == "rifle" and picks.get("secondary") == "pistol", "choice_text and parse_choice agree")

	manager.queue_free()
	_done()


func _test_instant_swap() -> void:
	_section("instant swap after spawn")
	var r := DotLoadoutInstantSwap.new()
	_check(r.decide("k", 0.0, 1.0, -1.0, -1.0) != "", "off by default in the addon")
	r.enabled = true
	_check(r.decide("k", 0.0, 1.0, -1.0, -1.0) == "", "inside the window, nobody near, not firing: allowed")
	_check(r.decide("k", 0.0, 20.0, -1.0, -1.0) != "", "outside the window: refused")
	_check(r.decide("k", 0.0, 1.0, -1.0, 5.0) != "", "an enemy inside the radius: refused")
	_check(r.decide("k", 0.0, 1.0, -1.0, 80.0) == "", "an enemy beyond the radius: allowed")
	_check(r.decide("k", 0.0, 1.0, 1.0, -1.0) != "", "fired a second ago: refused")
	_check(r.decide("k", 0.0, 1.0, 10.0, -1.0) == "", "fired long ago: allowed")
	r.mark("k", 100.0)
	_check(r.decide("k", 105.0, 1.0, -1.0, -1.0) != "", "inside the cooldown: refused")
	_check(r.decide("other", 105.0, 1.0, -1.0, -1.0) == "", "the cooldown is per player")
	_check(r.decide("k", 111.0, 1.0, -1.0, -1.0) == "", "after the cooldown: allowed")

	var manager := _make_manager()
	var cmd := DotLoadoutCommand.new()
	cmd.manager = manager
	var host := FakeHost.new()
	cmd.bind(host)
	_check(cmd.instant.enabled == false, "cvar default follows the field (off)")
	(host.cvars[DotLoadoutInstantSwap.CVAR_ENABLE] as FakeCvar).set_to("1")
	(host.cvars[DotLoadoutInstantSwap.CVAR_COOLDOWN] as FakeCvar).set_to("30")
	_check(cmd.instant.enabled and cmd.instant.cooldown == 30.0, "cvars reach the rule")
	var facts := {"now": 50.0, "since_spawn": 2.0, "since_fire": -1.0, "enemy_dist": -1.0}
	var applied := [0]
	cmd.instant_facts_fn = func(_k: String) -> Dictionary: return facts
	cmd.instant_apply_fn = func(_c: Object, _k: String) -> bool:
		applied[0] += 1
		return true
	var res: Dictionary = await cmd.choose(null, "player-cmd-0002", {"primary": "rifle"})
	_check(bool(res["now"]) and applied[0] == 1, "the choice is handed over at once", str(res))
	res = await cmd.choose(null, "player-cmd-0002", {"secondary": "pistol"})
	_check(not bool(res["now"]) and applied[0] == 1 and "cooldown" in str(res["text"]), "a second choice hits the cooldown and says so", str(res))
	facts["enemy_dist"] = 3.0
	res = await cmd.choose(null, "player-cmd-0003", {"primary": "rifle"})
	_check(not bool(res["now"]) and "enemy" in str(res["text"]), "an enemy near is refused with the reason", str(res))
	(host.cvars[DotLoadoutInstantSwap.CVAR_ENABLE] as FakeCvar).set_to("0")
	facts["enemy_dist"] = -1.0
	res = await cmd.choose(null, "player-cmd-0004", {"primary": "rifle"})
	_check(not bool(res["now"]) and applied[0] == 1, "cvar off: saved for the next spawn")
	manager.queue_free()
	_done()


## An unguarded call on a freed node can return a plausible value, so only the error shows it.
class ErrorCatcher extends Logger:
	var errors: Array[String] = []

	func _log_error(function: String, _file: String, _line: int, code: String,
			rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array) -> void:
		errors.append("%s %s %s" % [code, rationale, function])
