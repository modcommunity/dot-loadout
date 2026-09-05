class_name DotLoadoutStoreLocal
extends DotLoadoutStore

## Loadouts as JSON files under a directory. The default, and it works unconfigured.
##
## One file per player, for the reason dot-user's profile store gives: a single file
## is rewritten in full on every change and loses everything rather than one record
## when a write is interrupted.

const LOCAL_CHANNEL := "loadout.store.local"

var directory: String = "user://loadouts"

## Write through a temporary file and rename over the target. [method DotPaths.write_json]
## already does the temporary file, the rename and the browser's IndexedDB flush.
var atomic_writes: bool = true


static func at(path: String) -> DotLoadoutStoreLocal:
	var s := DotLoadoutStoreLocal.new()
	s.directory = path
	return s


func _store_name() -> String:
	return "DotLoadoutStoreLocal"


func _open() -> DotResult:
	var made := DotPaths.ensure_dir(directory)

	if not made.ok:
		return made.wrap("Could not open the loadout directory.")

	DotLog.debug(LOCAL_CHANNEL, "loadout store open", {"directory": directory})
	return DotResult.success(true)


func _path_for(user_key: String) -> DotResult:
	var relative := DotPaths.safe_relative("%s.json" % user_key)

	if not relative.ok:
		return relative.wrap("That key is not a usable filename.")

	return DotResult.success("%s/%s" % [directory, relative.value])


func _fetch(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(null)

	var read := DotPaths.read_json(path.value)

	if not read.ok:
		# A file that exists and will not parse is a failure, never an absence.
		# Reporting it as "no loadouts" would make the manager write defaults over
		# whatever could still have been recovered by hand.
		return read.wrap("Stored loadouts could not be read.")

	if not (read.value is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE, "A stored loadout file is not an object.", path.value
		)

	var data: Dictionary = read.value
	var raw: Variant = data.get("loadouts", [])

	if typeof(raw) != TYPE_ARRAY:
		return DotResult.fail(
			DotError.CODE_PARSE, "A stored loadout file has no loadout array."
		)

	var out: Array[DotLoadout] = []

	for entry in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue

		var parsed := DotLoadout.from_dictionary(entry as Dictionary)

		if not parsed.ok:
			return parsed.wrap("A stored loadout is malformed.")

		out.append(parsed.value)

	return DotResult.success(null if out.is_empty() else out)


func _store(user_key: String, loadouts: Array[DotLoadout]) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	var plain := []

	for loadout in loadouts:
		plain.append(loadout.to_dictionary())

	var written := DotPaths.write_json(
		path.value, {"loadouts": plain}, true, atomic_writes
	)

	if not written.ok:
		return written.wrap("Could not write the loadouts.")

	return DotResult.success(true)


func _remove(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(true)

	var dir := DirAccess.open(directory)

	if dir == null:
		return DotResult.fail(
			DotError.CODE_IO, "Could not open the loadout directory.", directory
		)

	var removed := dir.remove(String(path.value).get_file())

	if removed != OK:
		return DotResult.failure(
			DotError.from_engine(removed, "Removing the loadouts")
		)

	# DotPaths flushes on write; a deletion goes through DirAccess directly, so on a
	# web build it has to be flushed here or the file returns on the next load.
	DotWeb.sync_filesystem()
	return DotResult.success(true)


func describe() -> Dictionary:
	var out := super.describe()
	out["directory"] = directory
	return out
