class_name DotLoadoutStoreProfile
extends DotLoadoutStore

## Stub for loadouts kept in the profile document (route not implemented): every call refuses
## with CODE_UNSUPPORTED, so fall back to [DotLoadoutStoreTiered]. A real backend fills
## [member fetcher] and [member saver] (or subclasses `_fetch` and `_store`).

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
