@tool
class_name DotItemCatalogue
extends Resource

## Every item a game knows about, by id.
##
## The lookup side of the schema, kept separate from it so several schemas — a
## deathmatch loadout, a hardcore one, a gun-game ladder — can share one catalogue.
##
## [b]Turning an item id into an actual asset is not this class's job.[/b] A server
## validating a loadout has no meshes, no scenes and often no content at all, and
## making the catalogue own the mapping would put a `load()` on the join path. That
## mapping is [member resolver], it is optional, and only a client sets it.

const CHANNEL := "loadout.catalogue"

@export var id: StringName = &"items"

## Bumped when items change in a way that invalidates saved loadouts. Carried by a
## [DotLoadout] so a mismatch is visible rather than mysterious.
@export_range(1, 100000, 1) var version: int = 1

@export var items: Array[DotItem] = []

## `func(item: DotItem) -> Variant`. Turns an item into whatever the game needs — a
## `PackedScene`, a `DotWeapon`, a texture. Never called by validation.
var resolver: Callable = Callable()

var _by_id: Dictionary = {}
var _indexed: bool = false


static func of(p_items: Array[DotItem]) -> DotItemCatalogue:
	var catalogue := DotItemCatalogue.new()
	catalogue.items = p_items
	return catalogue


## Rebuilds the id index. Call after mutating [member items] at runtime.
func reindex() -> void:
	_by_id.clear()

	for item in items:
		if item == null or item.id == &"":
			continue

		if _by_id.has(item.id):
			# Silently keeping the first is how a duplicate id turns into "that gun
			# has the wrong stats" three months later.
			DotLog.warn(
				CHANNEL, "duplicate item id, the later one wins",
				{"id": String(item.id)}
			)

		_by_id[item.id] = item

	_indexed = true


func _ensure_indexed() -> void:
	if not _indexed:
		reindex()


func find(item_id: StringName) -> DotItem:
	_ensure_indexed()
	return _by_id.get(item_id)


func has(item_id: StringName) -> bool:
	_ensure_indexed()
	return _by_id.has(item_id)


func size() -> int:
	_ensure_indexed()
	return _by_id.size()


func ids() -> Array[StringName]:
	_ensure_indexed()
	var out: Array[StringName] = []
	for key in _by_id.keys():
		out.append(key)
	out.sort()
	return out


## Every item of a kind, in declaration order.
func of_kind(kind: StringName) -> Array[DotItem]:
	var out: Array[DotItem] = []
	for item in items:
		if item != null and item.kind == kind:
			out.append(item)
	return out


func with_tag(tag: StringName) -> Array[DotItem]:
	var out: Array[DotItem] = []
	for item in items:
		if item != null and item.has_tag(tag):
			out.append(item)
	return out


## Resolves an item to its asset, following [member DotItem.fallback_id] when the
## content is not available.
##
## Returns a failure rather than null so a caller cannot mistake "not downloaded yet"
## for "no such item" — the first is temporary and the second is a bug.
func resolve(item_id: StringName) -> DotResult:
	var item := find(item_id)

	if item == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "No item '%s' in catalogue '%s'." % [item_id, id]
		)

	if not resolver.is_valid():
		return DotResult.fail(
			DotError.CODE_STATE,
			"Catalogue '%s' has no resolver; a server does not need one." % id
		)

	var asset: Variant = resolver.call(item)

	if asset != null:
		return DotResult.success(asset)

	if item.fallback_id != &"" and item.fallback_id != item_id:
		return resolve(item.fallback_id)

	return DotResult.fail(
		DotError.CODE_IO,
		"Item '%s' could not be resolved and has no usable fallback." % item_id
	)


func validate() -> DotResult:
	reindex()

	if items.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "Catalogue '%s' is empty." % id
		)

	for item in items:
		if item == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "Catalogue '%s' holds a null item." % id
			)

		var res := item.validate()

		if not res.ok:
			return res

		if item.fallback_id != &"" and not _by_id.has(item.fallback_id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Item '%s' falls back to '%s', which is not in the catalogue."
					% [item.id, item.fallback_id]
			)

	return DotResult.success(size())


func describe() -> Dictionary:
	_ensure_indexed()
	return {
		"id": String(id),
		"version": version,
		"items": size(),
		"resolver": resolver.is_valid(),
	}


func _to_string() -> String:
	return "DotItemCatalogue(%s, %d items)" % [id, size()]
