class_name DotLoadoutEntitlements
extends RefCounted

## What one player is allowed to take.
##
## [b]Nothing is granted by default, and that is the important half.[/b] An
## entitlement set that starts empty makes an unwired server refuse everything, which
## is loud and gets fixed in a minute. One that starts full makes an unwired server
## accept everything, which is silent and is a game where every unlock is free.
##
## An item marked [member DotItem.free] is available regardless — that is what the
## flag is for, and it is how a starting pistol works without a grant.
##
## The same shape as [code]DotAvatarEntitlements[/code], and deliberately a separate
## class: only dot-core is a hard dependency in this family, and a game that wants
## loadouts without avatars must not have to install one to get the other.

var _held: Dictionary = {}

## Grants everything. **Never on a server.** For a client previewing its own work,
## for a creator sandbox, and for tests.
var unrestricted: bool = false


static func none() -> DotLoadoutEntitlements:
	return DotLoadoutEntitlements.new()


static func of(ids: Array) -> DotLoadoutEntitlements:
	var entitlements := DotLoadoutEntitlements.new()
	for id in ids:
		entitlements.grant(StringName(id))
	return entitlements


## Everything, including items nobody has bought. See [member unrestricted].
static func everything() -> DotLoadoutEntitlements:
	var entitlements := DotLoadoutEntitlements.new()
	entitlements.unrestricted = true
	return entitlements


func grant(unlock_id: StringName) -> void:
	_held[unlock_id] = true


func revoke(unlock_id: StringName) -> void:
	_held.erase(unlock_id)


## Whether this player may take [param item].
##
## Takes the item rather than an id so the [member DotItem.free] flag and the
## [method DotItem.unlock_id] indirection are applied in one place. A caller that
## checked the raw id would miss both.
func allows(item: DotItem) -> bool:
	if item == null:
		return false

	if item.free:
		return true

	if unrestricted:
		return true

	return _held.has(item.unlock_id())


func holds(unlock_id: StringName) -> bool:
	return unrestricted or _held.has(unlock_id)


func count() -> int:
	return _held.size()


func to_list() -> Array[StringName]:
	var out: Array[StringName] = []
	for key in _held.keys():
		out.append(key)
	out.sort()
	return out


func merge(other: DotLoadoutEntitlements) -> void:
	if other == null:
		return

	if other.unrestricted:
		unrestricted = true

	for id in other.to_list():
		grant(id)


func describe() -> Dictionary:
	return {
		"held": count(),
		"unrestricted": unrestricted,
		"ids": Array(to_list()),
	}


func _to_string() -> String:
	if unrestricted:
		return "DotLoadoutEntitlements(unrestricted)"
	return "DotLoadoutEntitlements(%d)" % count()
