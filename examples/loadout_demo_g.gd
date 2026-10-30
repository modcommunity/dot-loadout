extends "loadout_demo_f.gd"

## Suite part: random loadout at every spawn, and loadouts that are free unless a server prices them.

const SPAWN_KEY := "player-spawn-0001"


func _spawn_command(manager: DotLoadoutManager) -> Array:
	var cmd := DotLoadoutCommand.new()
	cmd.manager = manager
	cmd.key_fn = func(_ctx: Object) -> String: return SPAWN_KEY
	var host := FakeHost.new()
	cmd.bind(host)
	return [cmd, host]


func _test_random_spawn() -> void:
	_section("random loadout at every spawn")

	var manager := _make_manager()
	manager.entitlement_source = func(_k: String) -> DotLoadoutEntitlements:
		return DotLoadoutEntitlements.everything()
	var pair := _spawn_command(manager)
	var cmd: DotLoadoutCommand = pair[0]
	var host: FakeHost = pair[1]
	var ctx := FakeCtx.new()

	_check((host.cvars[DotLoadoutRandom.CVAR_SPAWN] as FakeCvar).value == "1", "the spawn rule is on for players who choose it by default")
	_check(await cmd.roll_for_spawn(SPAWN_KEY) == null, "toggle off: a spawn keeps the player's own loadout")

	var set: Dictionary = await cmd.set_random_spawn(SPAWN_KEY, true)
	_check(bool(set["ok"]) and manager.random_spawn_for(SPAWN_KEY), "turning the toggle on is accepted and kept", str(set))

	var valid := 0
	var digests := {}
	for i in 50:
		var rolled: DotLoadout = await cmd.roll_for_spawn(SPAWN_KEY)
		if rolled != null and DotLoadoutValidator.validate(rolled, manager.schema, manager.entitlements_for(SPAWN_KEY), manager.rules).ok:
			valid += 1
			digests[rolled.digest()] = true
	_check(valid == 50, "50 respawns each get a valid random loadout", str(valid))
	_check(digests.size() >= 5, "and they differ from spawn to spawn", str(digests.size()))

	var own: DotResult = await manager.active_for(SPAWN_KEY)
	var before: String = (own.value as DotLoadout).digest()
	var _r: DotLoadout = await cmd.roll_for_spawn(SPAWN_KEY)
	var after: DotResult = await manager.active_for(SPAWN_KEY)
	_check((after.value as DotLoadout).digest() == before, "a spawn roll is never saved over the player's own loadout")

	# Persistence: a second manager over the same store.
	var again := _make_manager()
	again.store = manager.store
	await again.load_for(SPAWN_KEY)
	_check(again.random_spawn_for(SPAWN_KEY), "the toggle survives a restart (new manager, same store)")
	var off: DotResult = await again.set_random_spawn(SPAWN_KEY, false)
	var third := _make_manager()
	third.store = manager.store
	await third.load_for(SPAWN_KEY)
	_check(off.ok and not third.random_spawn_for(SPAWN_KEY), "and turning it off survives too")
	again.queue_free()
	third.queue_free()

	# Server rule: forced and off.
	var cvar := host.cvars[DotLoadoutRandom.CVAR_SPAWN] as FakeCvar
	cvar.set_to("2")
	var _o: Dictionary = await cmd.set_random_spawn(SPAWN_KEY, false)
	_check(await cmd.roll_for_spawn(SPAWN_KEY) != null, "forced by the server: rolls whatever the toggle says")
	cvar.set_to("0")
	var refused: Dictionary = await cmd.set_random_spawn(SPAWN_KEY, true)
	_check(not bool(refused["ok"]) and str(refused["text"]).contains(DotLoadoutRandom.CVAR_SPAWN), "off: the toggle is refused and the message names the cvar", str(refused))
	_check(await cmd.roll_for_spawn(SPAWN_KEY) == null, "and a spawn rolls nothing")
	cvar.set_to("1")
	var _on: Dictionary = await cmd.set_random_spawn(SPAWN_KEY, true)
	(host.cvars[DotLoadoutRandom.CVAR_ENABLED] as FakeCvar).set_to("0")
	_check(await cmd.roll_for_spawn(SPAWN_KEY) == null, "Random switched off entirely: no spawn roll")
	(host.cvars[DotLoadoutRandom.CVAR_ENABLED] as FakeCvar).set_to("1")
	(host.cvars[DotLoadoutRules.CVAR_MENU] as FakeCvar).set_to("0")
	_check(await cmd.roll_for_spawn(SPAWN_KEY) == null, "the loadout menu off (the server sets loadouts): no spawn roll")
	(host.cvars[DotLoadoutRules.CVAR_MENU] as FakeCvar).set_to("1")

	var per := DotLoadoutRandom.new()
	_check(per.configure(true, 0, "", "free", false, 0, "sniper.spawn=2 medic.spawn=0", 1).ok, "a per-class spawn rule parses")
	_check(per.spawn_rule(&"sniper") == 2 and per.spawn_rule(&"medic") == 0 and per.spawn_rule(&"scout") == 1, "and applies to that class only")
	_check(not DotLoadoutRandom.parse_classes("sniper.spawn=7").ok, "an out-of-range spawn rule is refused")

	manager.queue_free()
	_done()


func _test_free_by_default() -> void:
	_section("loadouts are free unless priced")

	var costly := DotLoadout.empty(&"deathmatch")
	costly.set_item(&"primary", &"rocket")
	costly.set_item(&"secondary", &"pistol")
	costly.set_item(&"gear", &"armour")
	costly.set_item(&"utility", &"grenade", 2)
	var rich := DotLoadoutEntitlements.everything()

	var free := _build_schema()
	free.point_budget = 0
	_check(DotLoadoutValidator.validate(costly, free, rich).ok, "no budget: the costliest loadout is accepted")
	_check(free.effective_budget(null) == 0 and free.points_used(costly) >= 10, "costs exist but block nothing")

	var rules: DotLoadoutRules = DotLoadoutRules.parse(true, "", "", 6).value
	var limited := DotLoadoutValidator.validate(costly, free, rich, rules)
	_check(not limited.ok and str(limited.error.message).contains("mp_loadout_budget"), "mp_loadout_budget caps it and the refusal names the cvar", str(limited.error))
	_check(str(limited.error.message).contains("loadout_cost"), "and names the weapon profile's loadout_cost", str(limited.error))
	_check(free.effective_budget(rules) == 6, "the cvar budget overrides the schema's")
	var roomy: DotLoadoutRules = DotLoadoutRules.parse(true, "", "", 40).value
	_check(DotLoadoutValidator.validate(costly, free, rich, roomy).ok, "a larger budget lets it through")

	var tight := _build_schema()
	tight.point_budget = 4
	var unlimited: DotLoadoutRules = DotLoadoutRules.parse(true, "", "", 0).value
	_check(not DotLoadoutValidator.validate(costly, tight, rich, unlimited).ok, "budget 0 in the rules leaves the game's own budget alone")

	# The cvar through the command: rolls respect it, and the offer says whether anything is priced.
	var manager := _make_manager()
	manager.schema.point_budget = 0
	manager.entitlement_source = func(_k: String) -> DotLoadoutEntitlements:
		return DotLoadoutEntitlements.everything()
	var pair := _spawn_command(manager)
	var host: FakeHost = pair[1]
	_check((host.cvars[DotLoadoutRules.CVAR_BUDGET] as FakeCvar).value == "0", "mp_loadout_budget defaults to 0, unlimited")
	(host.cvars[DotLoadoutRules.CVAR_BUDGET] as FakeCvar).set_to("3")
	_check(manager.rules != null and manager.rules.point_budget == 3, "setting the cvar reaches the manager's rules")
	var rnd := DotLoadoutRandom.new()
	var within := true
	for i in 30:
		var res := _rolled(rnd, manager, &"", manager.rules)
		within = within and (not res.ok or manager.schema.points_used(res.value["loadout"]) <= 3)
	_check(within, "random rolls stay inside the cvar budget")
	(host.cvars[DotLoadoutRules.CVAR_BUDGET] as FakeCvar).set_to("0")
	_check(manager.rules == null or manager.rules.point_budget == 0, "and 0 lifts it again")

	manager.queue_free()
	_done()
