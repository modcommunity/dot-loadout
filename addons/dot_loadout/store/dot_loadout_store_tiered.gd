class_name DotLoadoutStoreTiered
extends DotLoadoutStore

## Durable storage for players with a stable key, memory for the rest.
##
## A guest, a bot or a seat with no identity is keyed by something that changes every
## session; writing those to disk only fills it. [member is_durable] says which is which.

var durable: DotLoadoutStore = null
var volatile: DotLoadoutStore = DotLoadoutStoreMemory.new()

## func(user_key: String) -> bool. Unset, every key is durable.
var is_durable: Callable = Callable()


static func of(p_durable: DotLoadoutStore, p_is_durable: Callable = Callable()) -> DotLoadoutStoreTiered:
	var s := new()
	s.durable = p_durable
	s.is_durable = p_is_durable
	return s


func _store_name() -> String:
	return "DotLoadoutStoreTiered"


func _pick(user_key: String) -> DotLoadoutStore:
	return durable if not is_durable.is_valid() or bool(is_durable.call(user_key)) else volatile


func _fetch(user_key: String) -> DotResult:
	return await _pick(user_key).fetch(user_key)


func _store(user_key: String, loadouts: Array[DotLoadout]) -> DotResult:
	return await _pick(user_key).store(user_key, loadouts)


func _remove(user_key: String) -> DotResult:
	return await _pick(user_key).remove(user_key)


func _writable() -> bool:
	return durable.is_writable()


func describe() -> Dictionary:
	var out := super.describe()
	out["durable"] = durable.describe()
	out["volatile"] = volatile.describe()
	return out
