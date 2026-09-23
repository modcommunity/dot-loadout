class_name DotLoadoutStore
extends RefCounted

## Where saved loadouts live, keyed by the player's scoped id.
##
## The same shape and the same two rules as dot-user's profile store and
## dot-user-avatar's, because it is the same problem: a per-player record a community
## running several servers wants to share. Loads may be slow and lookups on the join
## path may not; a failed read keeps whatever is in force rather than replacing it
## with a blank.
##
## A store validates [i]structure[/i] and nothing else. Whether a player is entitled
## to what is in their loadout is a schema-and-entitlements question and the store
## holds neither — [DotLoadoutManager.publish] is where both happen together. A store
## that pretended to do the second would be a checkpoint people trusted and should
## not.

const CHANNEL := "loadout.store"

var _opened: bool = false

var fetch_count: int = 0
var store_count: int = 0
var failure_count: int = 0


# --- Subclass interface ----------------------------------------------------

## Reads one player's loadouts. A successful null means "this player has none".
func _fetch(_user_key: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _fetch()." % _store_name()
	)


func _store(_user_key: String, _loadouts: Array[DotLoadout]) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _store()." % _store_name()
	)


func _remove(_user_key: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _remove()." % _store_name()
	)


func _open() -> DotResult:
	return DotResult.success(true)


func _close() -> void:
	pass


func _writable() -> bool:
	return true


func _store_name() -> String:
	return "DotLoadoutStore"


# --- Public API ------------------------------------------------------------

func open() -> DotResult:
	if _opened:
		return DotResult.success(true)

	var res: DotResult = await _open()

	if res.ok:
		_opened = true
	else:
		failure_count += 1
		_report("the loadout store did not open", "", res)

	return res


func close() -> void:
	if _opened:
		_close()
		_opened = false


func is_open() -> bool:
	return _opened


func is_writable() -> bool:
	return _writable()


## Reads a player's loadouts, or null when they have none.
##
## The key is checked before any implementation sees it, so a malformed one can never
## reach a filesystem path or a URL.
func fetch(user_key: String) -> DotResult:
	if not DotLoadoutKey.is_usable(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That is not a usable player key.",
			user_key.substr(0, 64)
		)

	if not _opened:
		var opened: DotResult = await open()
		if not opened.ok:
			return opened.wrap("The loadout store is not available.")

	fetch_count += 1

	var res: DotResult = await _fetch(user_key)

	if not res.ok:
		failure_count += 1
		_report("a player's loadouts could not be read", user_key, res)

	return res


func store(user_key: String, loadouts: Array[DotLoadout]) -> DotResult:
	if not DotLoadoutKey.is_usable(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a usable player key."
		)

	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This loadout store is read-only.", _store_name()
		)

	if loadouts.size() > DotLoadout.MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Refusing to store %d loadouts for one player." % loadouts.size()
		)

	if not _opened:
		var opened: DotResult = await open()
		if not opened.ok:
			return opened

	var res: DotResult = await _store(user_key, loadouts)

	if res.ok:
		store_count += 1
	else:
		failure_count += 1
		_report("a player's loadouts were not saved", user_key, res)

	return res


func remove(user_key: String) -> DotResult:
	if not DotLoadoutKey.is_usable(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a usable player key."
		)

	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This loadout store is read-only."
		)

	if not _opened:
		var opened: DotResult = await open()
		if not opened.ok:
			return opened

	var res: DotResult = await _remove(user_key)

	if not res.ok:
		failure_count += 1
		_report("a player's loadouts were not removed", user_key, res)

	return res


## Logged in the base because every backend's calls pass through it, so a store a game
## subclasses gets the line without remembering to write it -- and because
## DotLoadoutManager hands every one of these back to its caller without a word.
##
## ERROR, and only for the backend's own calls. A refusal before one (a malformed key,
## a read-only store, too many slots) is this class enforcing a rule and is the
## caller's to report; a failure from [method _open], [method _fetch], [method _store]
## or [method _remove] is the store failing against a disk or a service, and the
## player on the other end of it has lost a save or cannot spawn with their own gun.
func _report(what: String, user_key: String, res: DotResult) -> void:
	DotLog.error(CHANNEL, what, {
		"store": _store_name(),
		"key": user_key,
		"code": res.code(),
		"error": res.error.message if res.error != null else "",
	})


func describe() -> Dictionary:
	return {
		"store": _store_name(),
		"open": _opened,
		"writable": _writable(),
		"fetches": fetch_count,
		"stores": store_count,
		"failures": failure_count,
	}


func _to_string() -> String:
	return "%s(%s)" % [_store_name(), "open" if _opened else "closed"]
