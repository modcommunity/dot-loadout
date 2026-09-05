class_name DotLoadout
extends RefCounted

## What a player is taking into a match, as a bounded document.
##
## A mapping from slot ids to item ids and counts, and nothing else. No scenes, no
## meshes, no weapon resources. A dedicated server can receive one from an untrusted
## client, validate it against a schema and a set of entitlements, and hand it to the
## game — **without loading any content at all**, which is the same trade
## dot-user-avatar makes for the same reason.
##
## Bounded on purpose: [constant MAX_SLOTS] entries, and every id is length-limited on
## the wire. A document a client can make arbitrarily large is a document a client can
## use to exhaust a server.

const CHANNEL := "loadout"

## Most entries one document may hold. Above any real schema; this is a bound against
## a hostile client, not a design limit.
const MAX_SLOTS := 32

## Longest slot or item id accepted from the wire, in bytes.
const MAX_ID_BYTES := 48

## Which schema this was built against. A mismatch is repaired, not refused.
var schema_id: StringName = &""

## The catalogue version at the time it was saved.
var catalogue_version: int = 0

## Optional name a player gave this loadout. Never interpreted.
var display_name: String = ""

## slot id -> item id.
var entries: Dictionary = {}

## slot id -> count, for items a player carries more than one of. Absent means the
## item's own default.
var counts: Dictionary = {}


static func empty(p_schema_id: StringName = &"") -> DotLoadout:
	var loadout := DotLoadout.new()
	loadout.schema_id = p_schema_id
	return loadout


func set_item(slot_id: StringName, item_id: StringName, count: int = 0) -> void:
	if item_id == &"":
		clear_slot(slot_id)
		return

	entries[slot_id] = item_id

	if count > 0:
		counts[slot_id] = count
	else:
		counts.erase(slot_id)


func clear_slot(slot_id: StringName) -> void:
	entries.erase(slot_id)
	counts.erase(slot_id)


func item_in(slot_id: StringName) -> StringName:
	return entries.get(slot_id, &"")


func count_in(slot_id: StringName, fallback: int = 1) -> int:
	return int(counts.get(slot_id, fallback))


func has_slot(slot_id: StringName) -> bool:
	return entries.has(slot_id)


func filled_slots() -> Array[StringName]:
	var out: Array[StringName] = []
	for key in entries.keys():
		out.append(key)
	out.sort()
	return out


func size() -> int:
	return entries.size()


func is_empty() -> bool:
	return entries.is_empty()


func duplicate_loadout() -> DotLoadout:
	var copy := DotLoadout.new()
	copy.schema_id = schema_id
	copy.catalogue_version = catalogue_version
	copy.display_name = display_name
	copy.entries = entries.duplicate()
	copy.counts = counts.duplicate()
	return copy


func equals(other: DotLoadout) -> bool:
	if other == null:
		return false

	if schema_id != other.schema_id or entries.size() != other.entries.size():
		return false

	for key in entries.keys():
		if other.entries.get(key) != entries[key]:
			return false
		if count_in(key, -1) != other.count_in(key, -1):
			return false

	return true


# --- Serialisation ---------------------------------------------------------

func to_dictionary() -> Dictionary:
	var plain := {}
	var plain_counts := {}

	for key in entries.keys():
		plain[String(key)] = String(entries[key])

	for key in counts.keys():
		plain_counts[String(key)] = int(counts[key])

	var out := {
		"schema": String(schema_id),
		"version": catalogue_version,
		"entries": plain,
	}

	if display_name != "":
		out["name"] = display_name

	if not plain_counts.is_empty():
		out["counts"] = plain_counts

	return out


## Rebuilds a loadout from a dictionary that may have come from anywhere.
##
## Every failure here is reachable from a file on disk or from the network, so nothing
## is trusted: the entry count is bounded, ids are length-checked, and a non-string
## value is a refusal rather than a coercion. Coercing is how a client sends
## `{"primary": {"$ne": null}}` and finds out what the server does with it.
static func from_dictionary(data: Dictionary) -> DotResult:
	var loadout := DotLoadout.new()

	loadout.schema_id = StringName(str(data.get("schema", "")))
	loadout.catalogue_version = int(data.get("version", 0))

	var name_value: Variant = data.get("name", "")
	if typeof(name_value) == TYPE_STRING:
		loadout.display_name = str(name_value).substr(0, 64)

	var raw: Variant = data.get("entries", {})

	if typeof(raw) != TYPE_DICTIONARY:
		return DotResult.fail(
			DotError.CODE_PARSE, "A loadout's entries must be a dictionary."
		)

	var entries_dict: Dictionary = raw

	if entries_dict.size() > MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A loadout may hold at most %d entries; this one has %d."
				% [MAX_SLOTS, entries_dict.size()]
		)

	for key in entries_dict.keys():
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			return DotResult.fail(
				DotError.CODE_PARSE, "A loadout slot key must be a string."
			)

		var value: Variant = entries_dict[key]

		if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
			return DotResult.fail(
				DotError.CODE_PARSE,
				"The item in slot '%s' must be a string." % str(key)
			)

		var slot_id := str(key)
		var item_id := str(value)

		if slot_id.length() > MAX_ID_BYTES or item_id.length() > MAX_ID_BYTES:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"An id in a loadout is longer than %d characters." % MAX_ID_BYTES
			)

		loadout.entries[StringName(slot_id)] = StringName(item_id)

	var counts_raw: Variant = data.get("counts", {})

	if typeof(counts_raw) == TYPE_DICTIONARY:
		var counts_dict: Dictionary = counts_raw
		for key in counts_dict.keys():
			var slot := StringName(str(key))
			if not loadout.entries.has(slot):
				continue
			loadout.counts[slot] = clampi(int(counts_dict[key]), 1, 999)

	return DotResult.success(loadout)


static func from_json(text: String) -> DotResult:
	var parsed: Variant = JSON.parse_string(text)

	if typeof(parsed) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_PARSE, "A loadout must be a JSON object.")

	return from_dictionary(parsed)


func to_json() -> String:
	return JSON.stringify(to_dictionary())


# --- Wire ------------------------------------------------------------------

## Writes to a [code]DotNetWriter[/code].
##
## [param writer] is [Variant] so this file never mentions a dot-net class name — a
## script that does fails to parse in a project without dot-net installed, and takes
## every script that references it down with it.
##
## Slot and item ids go on the wire as strings rather than as indices into the schema.
## Indices are smaller and they are also a version coupling: a schema that gains a slot
## renumbers every one after it, and two peers on different builds then decode each
## other's loadouts into the wrong slots without anything failing. A loadout is sent
## once per player per life; the bytes are not worth that.
func write(writer: Variant) -> void:
	var slots := filled_slots()
	var count := mini(slots.size(), MAX_SLOTS)

	writer.write_string(String(schema_id), MAX_ID_BYTES)
	writer.write_uint(clampi(catalogue_version, 0, 65535), 16)
	writer.write_uint(count, 6)

	for index in range(count):
		var slot: StringName = slots[index]
		writer.write_string(String(slot), MAX_ID_BYTES)
		writer.write_string(String(entries[slot]), MAX_ID_BYTES)
		writer.write_uint(clampi(count_in(slot, 0), 0, 1023), 10)


## Reads from a [code]DotNetReader[/code]. Returns a failure on a malformed stream.
static func read(reader: Variant) -> DotResult:
	var loadout := DotLoadout.new()

	loadout.schema_id = StringName(reader.read_string(MAX_ID_BYTES))
	loadout.catalogue_version = reader.read_uint(16)

	var count: int = reader.read_uint(6)

	if not reader.ok():
		return DotResult.fail(DotError.CODE_PARSE, "Truncated loadout header.")

	if count > MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_INVALID, "A loadout claiming %d entries." % count
		)

	for _index in range(count):
		# Typed, not inferred: `reader` is Variant so this file never names a dot-net
		# class, and `var x := f()` where f returns Variant is a parse error under
		# these projects' warning settings.
		var slot: String = reader.read_string(MAX_ID_BYTES)
		var item: String = reader.read_string(MAX_ID_BYTES)
		var amount: int = reader.read_uint(10)

		if not reader.ok():
			return DotResult.fail(DotError.CODE_PARSE, "Truncated loadout entry.")

		if slot == "" or item == "":
			continue

		loadout.entries[StringName(slot)] = StringName(item)

		if amount > 0:
			loadout.counts[StringName(slot)] = amount

	return DotResult.success(loadout)


## A stable fingerprint of the contents.
##
## Two loadouts with the same entries produce the same digest regardless of insertion
## order, because [method filled_slots] sorts. A dictionary's own key order does not,
## which is the trap: hashing `to_json()` directly gives two different digests for the
## same loadout depending on the order the slots happened to be filled in.
func digest() -> String:
	var parts := PackedStringArray()

	parts.append(String(schema_id))

	for slot in filled_slots():
		parts.append("%s=%s:%d" % [slot, entries[slot], count_in(slot, 0)])

	return DotHash.sha256_text("\n".join(parts))


func describe() -> Dictionary:
	return {
		"schema": String(schema_id),
		"version": catalogue_version,
		"name": display_name,
		"slots": size(),
		"entries": to_dictionary()["entries"],
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if entries.is_empty():
		out.append("  (empty)")
		return out

	for slot in filled_slots():
		out.append("  %-14s %s%s" % [
			slot,
			entries[slot],
			"" if not counts.has(slot) else " x%d" % int(counts[slot]),
		])

	return out


func _to_string() -> String:
	return "DotLoadout(%s, %d slots)" % [schema_id, size()]
