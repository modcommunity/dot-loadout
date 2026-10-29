extends "loadout_demo_e.gd"

## Saved loadouts persist: a new store over the same directory gets them back.

const PERSIST_DIR := "user://test_loadouts_persist"


func _persist_manager(store: DotLoadoutStore) -> DotLoadoutManager:
	var manager := _make_manager()
	manager.store = store
	return manager


func _test_persistence() -> void:
	_section("persistent store")
	DotPaths.remove_tree(PERSIST_DIR)
	var key := "guest:abcdef0123456789"

	var first := _persist_manager(DotLoadoutStoreLocal.at(PERSIST_DIR))
	var a := first.schema.default_loadout()
	a.set_item(&"utility", &"medkit")
	var saved: DotResult = await first.save_as(key, a, "Medic")
	var b := first.schema.default_loadout()
	b.set_item(&"utility", &"grenade")
	var second: DotResult = await first.save_as(key, b, "Bomber")
	_check(saved.ok and second.ok, "two named loadouts save to disk", str(saved.error) + str(second.error))
	first.queue_free()
	remove_child(first)

	var again := _persist_manager(DotLoadoutStoreLocal.at(PERSIST_DIR))
	await again.load_for(key)
	var list := again.saved_list(key)
	_check(list.size() == 2 and list[0]["name"] == "Medic" and list[1]["name"] == "Bomber", "a new store and manager get the same names back", str(list))
	_check(again.selected_index(key) == 1, "and the same selection", str(again.selected_index(key)))
	var act: DotResult = await again.active_for(key)
	_check(act.ok and (act.value as DotLoadout).item_in(&"utility") == &"grenade", "the selected loadout is the one in use")
	again.queue_free()
	remove_child(again)

	var path := "%s/%s.json" % [PERSIST_DIR, key.replace(":", "~")]
	var text := FileAccess.get_file_as_string(path)
	_check('"version": 1' in text, "the file carries a schema version")

	DotPaths.write_text(path, "{ not json", false)
	var broken := DotLoadoutStoreLocal.at(PERSIST_DIR)
	var got: DotResult = await broken.fetch(key)
	_check(got.ok and got.value == null and FileAccess.file_exists(path + ".corrupt") and not FileAccess.file_exists(path), "a corrupt file is set aside, not fatal", str(got.error))
	var healed := _persist_manager(DotLoadoutStoreLocal.at(PERSIST_DIR))
	var again2: DotResult = await healed.save_as(key, a, "Fresh")
	_check(again2.ok and FileAccess.file_exists(path), "and the player can save again")
	healed.queue_free()
	remove_child(healed)

	DotPaths.write_text(path, '{"version": 99, "loadouts": []}', false)
	var future: DotResult = await DotLoadoutStoreLocal.at(PERSIST_DIR).fetch(key)
	_check(not future.ok and future.code() == DotError.CODE_VERSION and FileAccess.file_exists(path), "a newer version is refused and left in place")

	var capped := DotLoadoutStoreLocal.at(PERSIST_DIR)
	capped.max_file_bytes = 300
	var many: Array[DotLoadout] = []
	for i in 6:
		many.append(a)
	var over: DotResult = await capped.store("guest:capped0123456789", many)
	_check(not over.ok and over.code() == DotError.CODE_QUOTA and not FileAccess.file_exists(PERSIST_DIR + "/guest~capped0123456789.json"), "a file over the byte cap is refused and not written")
	DotPaths.write_text(PERSIST_DIR + "/guest~big0123456789.json", "x".repeat(400), false)
	var big: DotResult = await capped.fetch("guest:big0123456789")
	_check(big.ok and big.value == null and FileAccess.file_exists(PERSIST_DIR + "/guest~big0123456789.json.corrupt"), "an oversized file on disk is set aside unread")

	DotPaths.remove_tree(PERSIST_DIR)
	var few := DotLoadoutStoreLocal.at(PERSIST_DIR)
	few.max_files = 2
	var one_loadout: Array[DotLoadout] = [a]
	var r1: DotResult = await few.store("guest:first00001", one_loadout)
	var r2: DotResult = await few.store("guest:second0002", one_loadout)
	var r3: DotResult = await few.store("guest:third00003", one_loadout)
	var r4: DotResult = await few.store("guest:first00001", one_loadout)
	_check(r1.ok and r2.ok and not r3.ok and r3.code() == DotError.CODE_QUOTA and r4.ok, "the file-count cap refuses a new player and still saves an existing one")

	var tier := DotLoadoutStoreTiered.of(DotLoadoutStoreLocal.at(PERSIST_DIR), func(k: String) -> bool: return not k.begins_with("temp-"))
	var t1: DotResult = await tier.store("temp-00000001", one_loadout)
	var t2: DotResult = await tier.store("guest:tiered0001", one_loadout)
	var t3: DotResult = await tier.fetch("temp-00000001")
	_check(t1.ok and t2.ok and t3.ok and not FileAccess.file_exists(PERSIST_DIR + "/temp-00000001.json") and FileAccess.file_exists(PERSIST_DIR + "/guest~tiered0001.json"), "the tiered store keeps volatile keys off disk and durable ones on it")

	var local := DotLoadoutStoreLocal.at(PERSIST_DIR)
	var capman := _persist_manager(local)
	var cmd := DotLoadoutCommand.new()
	cmd.manager = capman
	var host := FakeHost.new()
	cmd.bind(host)
	(host.cvars[DotLoadoutRules.CVAR_STORE_MAX_BYTES] as FakeCvar).set_to("1234")
	(host.cvars[DotLoadoutRules.CVAR_STORE_MAX_FILES] as FakeCvar).set_to("7")
	_check(local.max_file_bytes == 1234 and local.max_files == 7, "the two store-cap cvars reach the store")
	capman.queue_free()
	remove_child(capman)

	var stub := DotLoadoutStoreProfile.new()
	var s1: DotResult = await stub.fetch("member:abcdef0123")
	_check(not s1.ok and s1.code() == DotError.CODE_UNSUPPORTED, "the profile-document store is a stub that refuses plainly")

	DotPaths.remove_tree(PERSIST_DIR)
	_done()
