extends "loadout_demo_d.gd"

## Try-outs must not use up saved-loadout slots; named loadouts and their cap.


func _test_saved() -> void:
	_section("saved loadouts")

	var manager := _make_manager()
	var cmd := DotLoadoutCommand.new()
	cmd.manager = manager
	cmd.key_fn = func(_ctx: Object) -> String: return "player-saved-01"
	cmd.notice_fn = func(_ctx: Object, _data: Dictionary) -> bool: return true
	var host := FakeHost.new()
	cmd.bind(host)
	var key := "player-saved-01"
	var ctx := FakeCtx.new()
	var handler: Callable = host.commands["loadout"]

	var refused := 0
	for i in 50:
		ctx.args = PackedStringArray(["utility=%s" % ("medkit" if i % 2 == 0 else "grenade")])
		await handler.call(ctx)
		if not bool(cmd.last_result.get("ok", false)):
			refused += 1
	var held: DotResult = await manager.load_for(key)
	_check(refused == 0 and (held.value as Array).size() == 1, "50 try-outs never hit a cap and keep one loadout", "refused %d, holds %d" % [refused, (held.value as Array).size()])

	ctx.args = PackedStringArray(["save", "Sniper", "utility=medkit"])
	await handler.call(ctx)
	_check(bool(cmd.last_result["ok"]) and manager.saved_list(key).size() == 2, "saving by name adds a loadout beside the one in use", str(cmd.last_result))
	ctx.args = PackedStringArray(["save", "Close", "range"])
	await handler.call(ctx)
	_check(manager.saved_list(key).size() == 3 and manager.selected_index(key) == 2, "a second name is a second loadout and is selected")
	ctx.args = PackedStringArray(["utility=grenade"])
	await handler.call(ctx)
	var list := manager.saved_list(key)
	_check(list.size() == 3 and list[2]["name"] == "Close range", "a try-out edits the selected loadout and keeps its name")

	ctx.args = PackedStringArray(["use", "1"])
	await handler.call(ctx)
	manager.forget(key)
	var back: DotResult = await manager.load_for(key)
	_check(back.ok and manager.selected_index(key) == 0, "the selected loadout survives a reload")
	ctx.args = PackedStringArray(["rename", "1", "  Long\tgun "])
	await handler.call(ctx)
	_check(manager.saved_list(key)[0]["name"] == "Longgun", "rename trims and drops control characters")
	ctx.args = PackedStringArray(["rename", "1", "   "])
	await handler.call(ctx)
	_check(not bool(cmd.last_result["ok"]), "an empty name is refused")
	ctx.args = PackedStringArray(["delete", "1"])
	await handler.call(ctx)
	_check(bool(cmd.last_result["ok"]) and manager.saved_list(key).size() == 2, "delete removes one")
	ctx.args = PackedStringArray(["delete", "1"])
	await handler.call(ctx)
	ctx.args = PackedStringArray(["delete", "1"])
	await handler.call(ctx)
	_check(not bool(cmd.last_result["ok"]) and manager.saved_list(key).size() == 1, "the last loadout cannot be deleted")

	(host.cvars[DotLoadoutRules.CVAR_MAX_SAVED] as FakeCvar).set_to("2")
	ctx.args = PackedStringArray(["save", "Two"])
	await handler.call(ctx)
	ctx.args = PackedStringArray(["save", "Three"])
	await handler.call(ctx)
	var text := str(cmd.last_result["text"])
	_check(not bool(cmd.last_result["ok"]) and manager.saved_list(key).size() == 2, "the cap cvar set to 2 still enforces", text)
	_check(DotLoadoutRules.CVAR_MAX_SAVED in text and "2" in text, "and the message names the cvar", text)
	(host.cvars[DotLoadoutRules.CVAR_MAX_SAVED] as FakeCvar).set_to("0")
	ctx.args = PackedStringArray(["save", "Three"])
	await handler.call(ctx)
	_check(bool(cmd.last_result["ok"]), "0 lifts the cap")
	_check(manager.config.max_per_player == 0 and DotLoadoutConfig.new().max_per_player == 0, "unlimited is the default")

	manager.queue_free()
	remove_child(manager)
	_done()
