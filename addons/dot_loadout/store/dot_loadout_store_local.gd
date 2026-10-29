class_name DotLoadoutStoreLocal
extends DotLoadoutStore

## Loadouts as JSON files under a directory. The default, and it works unconfigured.
##
## One file per player, for the reason dot-user's profile store gives: a single file
## is rewritten in full on every change and loses everything rather than one record
## when a write is interrupted. The file carries a schema [constant VERSION]; a file this
## build cannot read is set aside as `.corrupt` (never deleted), so one bad file costs that
## player their saves and nothing else.

const LOCAL_CHANNEL := "loadout.store.local"

const VERSION := 1

## Largest file read or written, in bytes; 0 is unlimited. The `mp_loadout_store_max_bytes` cvar.
var max_file_bytes: int = 65536

## Most player files in the directory; 0 is unlimited. The `mp_loadout_store_max_files` cvar.
var max_files: int = 20000

var directory: String = "user://loadouts"

## Write through a temporary file and rename over the target. [method DotPaths.write_json]
## already does the temporary file, the rename and the browser's IndexedDB flush.
var atomic_writes: bool = true


static func at(path: String) -> DotLoadoutStoreLocal:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var s := new()
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
	# ':' is legal in a key but not in a filename on every platform; '~' is in neither's alphabet.
	var relative := DotPaths.safe_relative("%s.json" % user_key.replace(":", "~"))

	if not relative.ok:
		return relative.wrap("That key is not a usable filename.")

	return DotResult.success("%s/%s" % [directory, relative.value])


func _fetch(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(null)

	var size := _size_of(path.value)

	if max_file_bytes > 0 and size > max_file_bytes:
		return _set_aside(path.value, "the file is %d bytes, over the %d cap" % [size, max_file_bytes])

	var read := DotPaths.read_json(path.value)

	if not read.ok or not (read.value is Dictionary):
		return _set_aside(path.value, "the file does not parse")

	var data: Dictionary = read.value
	var version: Variant = data.get("version", 1)

	if typeof(version) != TYPE_INT and typeof(version) != TYPE_FLOAT:
		return _set_aside(path.value, "the version is not a number")

	if int(version) > VERSION:
		# Written by a newer build: keep it where it is, so rolling back loses nothing.
		return DotResult.fail(
			DotError.CODE_VERSION, "Stored loadouts are version %d, this build reads %d." % [int(version), VERSION]
		)

	var raw: Variant = data.get("loadouts", [])

	if typeof(raw) != TYPE_ARRAY:
		return _set_aside(path.value, "there is no loadout array")

	var out: Array[DotLoadout] = []

	for entry in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue

		var parsed := DotLoadout.from_dictionary(entry as Dictionary)

		if not parsed.ok:
			return _set_aside(path.value, "a loadout in it is malformed")

		out.append(parsed.value)

	return DotResult.success(null if out.is_empty() else out)


func _size_of(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file != null else 0


## Renames an unreadable file to `.corrupt` and reports "no loadouts": the player can save
## again, and the old bytes stay on disk for a person to recover.
func _set_aside(path: String, why: String) -> DotResult:
	var err := DirAccess.rename_absolute(path, path + ".corrupt")
	DotLog.warn(LOCAL_CHANNEL, "a loadout file was set aside", {"path": path, "why": why, "rename": err})
	DotWeb.sync_filesystem()
	return DotResult.success(null)


func _file_count() -> int:
	var count := 0

	for name in DirAccess.get_files_at(directory):
		if name.ends_with(".json"):
			count += 1

	return count


func _store(user_key: String, loadouts: Array[DotLoadout]) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	var plain := []

	for loadout in loadouts:
		plain.append(loadout.to_dictionary())

	var text := JSON.stringify({"version": VERSION, "loadouts": plain}, "\t")

	if max_file_bytes > 0 and text.to_utf8_buffer().size() > max_file_bytes:
		return DotResult.fail(
			DotError.CODE_QUOTA, "Your saved loadouts are too large (mp_loadout_store_max_bytes %d)." % max_file_bytes
		)

	if max_files > 0 and not FileAccess.file_exists(path.value) and _file_count() >= max_files:
		return DotResult.fail(
			DotError.CODE_QUOTA, "This server keeps no more players' loadouts (mp_loadout_store_max_files %d)." % max_files
		)

	var written := DotPaths.write_text(path.value, text, atomic_writes)

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
	out["max_file_bytes"] = max_file_bytes
	out["max_files"] = max_files
	return out
