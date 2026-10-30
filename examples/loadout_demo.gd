extends "loadout_demo_g.gd"

## Entry point of the offline suite; the checks live in loadout_demo_base.gd and the parts that extend it.


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-loadout self-test")
	print("")

	DotPaths.remove_tree(LOADOUT_DIR)

	_catalogue = _build_catalogue()
	_schema = _build_schema()

	_test_items()
	_test_catalogue()
	_test_slots()
	_test_schema()
	_test_document()
	_test_entitlements()
	_test_text_order()
	_test_validation()
	_test_conform()
	_test_budgets()
	_test_wire()
	await _test_store_contract(DotLoadoutStoreMemory.new(), "memory")
	await _test_store_contract(DotLoadoutStoreLocal.at(LOADOUT_DIR), "local")
	await _test_manager()
	await _test_manager_entitlements()
	_test_pickups()
	_test_rules()
	await _test_manager_rules()
	await _test_command()
	await _test_instant_swap()
	_test_random()
	await _test_random_command()
	await _test_saved()
	await _test_persistence()
	await _test_random_spawn()
	await _test_free_by_default()
	await _test_site_source()

	DotPaths.remove_tree(LOADOUT_DIR)

	print("")
	# The two guards, as the last two checks. See docs/testing.md.
	_check(
		_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d)" % [_completed, SECTIONS]
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS]
	)
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _test_site_source() -> void:
	_section("site store entitlements")
	var site := FakeSite.new()
	site.body = {"ok": true, "items": [
		{"key": "skin.gold", "grant": null},
		{"key": "pack.heavy", "grant": {"unlock": ["rifle_x", "smg_y"]}},
		{"key": ""},
	]}
	var src := DotLoadoutSiteSource.with_client(site)
	src.source("p1")
	_check(site.calls == 1, "the first lookup of a player starts a read")
	var res: DotResult = await src.refresh("p1")
	_check(res.ok and (res.value as Array).size() == 4, "refresh yields item keys and grant.unlock ids", str(res.value))
	var ent: DotLoadoutEntitlements = src.source("p1")
	_check(ent.allows(_item_for("skin.gold")) and ent.allows(_item_for("rifle_x")), "an owned key and a granted unlock are allowed")
	_check(not ent.allows(_item_for("other")), "an unowned id is refused")
	var calls := site.calls
	src.source("p1")
	_check(site.calls == calls, "a fresh cache entry starts no read")
	_check(DotLoadoutSiteSource.ids_from({"items": "x"}).is_empty(), "a malformed body grants nothing")
	_check(src.client.call("get_integration", "x", {}).ok, "the fake client answers")
	_check((await DotLoadoutSiteSource.new().refresh("p")).ok == false, "no client is a failure, not a grant")
	_done()


func _item_for(id: String) -> DotItem:
	return DotItem.make(StringName(id), DotItem.KIND_WEAPON, false)


class FakeSite:
	extends RefCounted
	var calls: int = 0
	var body: Dictionary = {}

	func get_integration(_path: String, _query: Dictionary = {}) -> DotResult:
		calls += 1
		return DotResult.success(body)
