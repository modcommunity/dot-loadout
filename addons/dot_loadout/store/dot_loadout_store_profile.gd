class_name DotLoadoutStoreProfile
extends DotLoadoutStore

## Stub for a member's loadouts kept in their profile document (the backbone's
## `user/{key}/loadouts`). Not implemented: that route does not exist yet, so every call
## refuses with CODE_UNSUPPORTED and [DotLoadoutStoreTiered] is the place to fall back.
##
## A real backend fills [member fetcher] and [member saver] (or subclasses `_fetch` and
## `_store`); the contract is the same as every store here: structure only, never trust.

## func(user_key) -> DotResult of Array[DotLoadout] or null.
var fetcher: Callable = Callable()

## func(user_key, loadouts: Array[DotLoadout]) -> DotResult.
var saver: Callable = Callable()


func _store_name() -> String:
	return "DotLoadoutStoreProfile"


func _writable() -> bool:
	return saver.is_valid()


func _fetch(user_key: String) -> DotResult:
	if not fetcher.is_valid():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "No profile-document loadout backend is wired.")
	return await fetcher.call(user_key)


func _store(user_key: String, loadouts: Array[DotLoadout]) -> DotResult:
	if not saver.is_valid():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "No profile-document loadout backend is wired.")
	return await saver.call(user_key, loadouts)


func _remove(_user_key: String) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "No profile-document loadout backend is wired.")
