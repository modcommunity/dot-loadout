extends "loadout_demo_f.gd"

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
