extends "loadout_demo_c.gd"

## Suite part: the Random entry.

const KEY := "player-rnd-0001"


func _rolled(rnd: DotLoadoutRandom, manager: DotLoadoutManager, class_id: StringName = &"",
		rules: DotLoadoutRules = null, money: int = -1) -> DotResult:
	return rnd.roll(manager, KEY, manager.schema.default_loadout(), class_id, rules, money)


func _test_random() -> void:
	_section("random loadout")

	var manager := _make_manager()
	manager.entitlement_source = func(_k: String) -> DotLoadoutEntitlements:
		return DotLoadoutEntitlements.of([&"sniper", &"rocket", &"armour"])
	var rnd := DotLoadoutRandom.new()

	# Variety, and a new roll every time.
	var primaries := {}
	var digests := {}
	for i in 60:
		var res := _rolled(rnd, manager)
		if res.ok:
			var l: DotLoadout = res.value["loadout"]
			primaries[l.item_in(&"primary")] = true
			digests[l.digest()] = true
	_check(primaries.size() >= 3, "60 rolls reach at least three different primaries", str(primaries.keys()))
	_check(digests.size() >= 6, "and many different loadouts, none cached", str(digests.size()))

	# Seed determinism.
	var a := DotLoadoutRandom.new()
	var b := DotLoadoutRandom.new()
	var c := DotLoadoutRandom.new()
	a.seed_value = 4242
	b.seed_value = 4242
	c.seed_value = 99
	var same := true
	var differs := false
	for i in 12:
		var da: String = _rolled(a, manager).value["loadout"].digest()
		same = same and da == _rolled(b, manager).value["loadout"].digest()
		differs = differs or da != _rolled(c, manager).value["loadout"].digest()
	_check(same, "the same seed rolls the same sequence")
	_check(differs, "another seed rolls another")

	# Count and slot filter.
	var one := DotLoadoutRandom.new()
	one.count = 1
	one.slots = PackedStringArray(["utility"])
	var narrow := true
	for i in 20:
		var changed: Array = _rolled(one, manager).value["changed"]
		narrow = narrow and changed == [&"utility"]
	_check(narrow, "count and slots limit what is rolled")
	var per := DotLoadoutRandom.new()
	_check(per.configure(true, 0, "", "free", false, 0, "medic.count=1 medic.slots=utility+gear").ok, "class overrides parse")
	_check(per.effective(&"medic")["count"] == 1 and per.effective(&"sniper")["count"] == 0, "and apply to their class only")
	_check(not DotLoadoutRandom.parse_classes("medic.count=x").ok and not DotLoadoutRandom.parse_price("flat:-1").ok \
		and not DotLoadoutRandom.parse_price("cheap").ok, "bad settings are refused")

	# Budget.
	manager.schema.point_budget = 4
	var within := true
	for i in 40:
		var res := _rolled(rnd, manager)
		within = within and (not res.ok or manager.schema.points_used(res.value["loadout"]) <= 4)
	_check(within, "a roll never goes over the point budget")
	manager.schema.point_budget = 10

	# Class restrictions.
	var rules: DotLoadoutRules = DotLoadoutRules.parse(true, "primary=rifle", "").value
	var obeys := true
	for i in 40:
		var res := _rolled(rnd, manager, &"scout", rules)
		obeys = obeys and res.ok and res.value["loadout"].item_in(&"primary") == &"rifle"
	_check(obeys, "a class's allowed items are the only ones rolled")

	_random_money_checks(manager)

	manager.queue_free()
	_done()


func _random_money_checks(manager: DotLoadoutManager) -> void:
	# Money.
	var paid := DotLoadoutRandom.new()
	paid.price_mode = DotLoadoutRandom.PRICE_FLAT
	paid.flat_cost = 5
	_check(not _rolled(paid, manager, &"", null, 3).ok, "a flat price the player cannot pay is refused")
	_check(_rolled(paid, manager, &"", null, 5).value["spent"] == 5, "and charged when they can")
	paid.price_mode = DotLoadoutRandom.PRICE_SUM
	var afford := true
	for i in 30:
		var res := _rolled(paid, manager, &"", null, 3)
		afford = afford and (not res.ok or res.value["spent"] <= 3)
	_check(afford, "a sum price never exceeds the player's money")

	# Duplicates off: no item twice (the schema has none that fits two slots, so rig a slot).
	_check(DotLoadoutRandom._held_elsewhere(_full_loadout(), &"utility", &"rifle") \
		and not DotLoadoutRandom._held_elsewhere(_full_loadout(), &"primary", &"rifle"), "duplicate detection ignores the slot itself")


func _test_random_command() -> void:
	_section("random loadout command")

	var manager := _make_manager()
	var cmd := DotLoadoutCommand.new()
	cmd.manager = manager
	cmd.key_fn = func(_ctx: Object) -> String: return KEY
	var sent: Array = []
	cmd.notice_fn = func(_ctx: Object, data: Dictionary) -> bool:
		sent.append(data)
		return true
	var host := FakeHost.new()
	cmd.bind(host)
	_check(host.cvars.size() == 16 and host.cvars.has(DotLoadoutRandom.CVAR_ENABLED), "bind adds the seven random cvars")

	var ctx := FakeCtx.new()
	var handler: Callable = host.commands["loadout"]
	await handler.call(ctx)
	_check((sent[-1] as Dictionary)["random"]["enabled"] == true, "the offer says Random is on")

	ctx.args = PackedStringArray(["random"])
	await handler.call(ctx)
	_check(bool((sent[-1] as Dictionary)["result"].get("ok", false)), "/loadout random rolls and saves", str(sent[-1]))

	(host.cvars[DotLoadoutRandom.CVAR_ENABLED] as FakeCvar).set_to("0")
	var before: DotResult = await manager.active_for(KEY)
	var before_digest: String = (before.value as DotLoadout).digest()
	await handler.call(ctx)
	var refused: Dictionary = (sent[-1] as Dictionary)["result"]
	var after: DotResult = await manager.active_for(KEY)
	_check(not bool(refused["ok"]) and (after.value as DotLoadout).digest() == before_digest, "turned off, the server refuses a modified client's request", str(refused))
	ctx.args = PackedStringArray()
	await handler.call(ctx)
	_check((sent[-1] as Dictionary)["random"]["enabled"] == false, "and the offer hides the entry")

	(host.cvars[DotLoadoutRandom.CVAR_ENABLED] as FakeCvar).set_to("1")
	(host.cvars[DotLoadoutRandom.CVAR_PRICE] as FakeCvar).set_to("flat:5")
	var wallet := [3]
	cmd.money_fn = func(_k: String) -> int: return wallet[0]
	cmd.charge_fn = func(_k: String, amount: int) -> bool:
		wallet[0] -= amount
		return wallet[0] >= 0
	_check(not bool((await cmd.choose_random(ctx, KEY))["ok"]) and wallet[0] == 3, "too poor: refused and nothing taken")
	wallet[0] = 8
	_check(bool((await cmd.choose_random(ctx, KEY))["ok"]) and wallet[0] == 3, "enough money: rolled and charged")
	(host.cvars[DotLoadoutRandom.CVAR_PRICE] as FakeCvar).set_to("cheap")
	_check(cmd.random.price_mode == DotLoadoutRandom.PRICE_FLAT, "a bad price value keeps the old setting")

	(host.cvars[DotLoadoutRules.CVAR_MENU] as FakeCvar).set_to("0")
	_check(not bool((await cmd.choose_random(ctx, KEY))["ok"]), "with the whole menu off, Random is refused too")

	manager.queue_free()
	_done()
