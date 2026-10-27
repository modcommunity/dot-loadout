class_name DotLoadoutInstantSwap
extends RefCounted

## The rule for handing a menu choice over at once instead of at the next spawn: shortly after
## spawning, with no enemy near, not having fired lately, and not more often than a cooldown.
## Pure decision plus the per-player cooldown; the game supplies the facts and does the handing.

const CHANNEL := "loadout.instant"

const CVAR_ENABLE := "sv_loadout_instant_after_spawn"
const CVAR_WINDOW := "sv_loadout_instant_window"
const CVAR_RADIUS := "sv_loadout_instant_radius"
const CVAR_QUIET := "sv_loadout_instant_quiet"
const CVAR_COOLDOWN := "sv_loadout_instant_cooldown"

## Off by default in the addon; a game that wants it sets true before [method bind_cvars].
var enabled: bool = false
## Seconds after spawning in which a swap is instant.
var window: float = 8.0
## An enemy closer than this (metres) refuses it.
var radius: float = 25.0
## Seconds since the player last fired that must have passed.
var quiet: float = 3.0
## Seconds between two instant swaps by one player.
var cooldown: float = 10.0

var _last_swap: Dictionary = {}
var _cvars: Dictionary = {}


## Why a swap is refused now, or "" when it may go. [param since_spawn] and [param since_fire] are
## seconds (negative since_fire: never fired), [param enemy_dist] metres to the nearest enemy
## (negative: none).
func decide(key: String, now: float, since_spawn: float, since_fire: float, enemy_dist: float) -> String:
	var why := ""
	if not enabled:
		why = "Instant weapon changes are off."
	elif since_spawn < 0.0 or since_spawn > window:
		why = "Too long after spawning for an instant change."
	elif enemy_dist >= 0.0 and enemy_dist < radius:
		why = "An enemy is near."
	elif since_fire >= 0.0 and since_fire < quiet:
		why = "You fired a moment ago."
	elif _last_swap.has(key) and now - float(_last_swap[key]) < cooldown:
		why = "Instant change on cooldown (%ds)." % int(ceil(cooldown - (now - float(_last_swap[key]))))
	DotLog.debug(CHANNEL, "instant swap decision", {"key": key, "why": why, "since_spawn": since_spawn,
		"since_fire": since_fire, "enemy": enemy_dist})
	return why


## Records a swap so the cooldown runs.
func mark(key: String, now: float) -> void:
	_last_swap[key] = now


func forget(key: String) -> void:
	_last_swap.erase(key)


## Registers the cvars with [param adder] `(name, default, help, flags)` and follows them.
## Returns the cvars made.
func bind_cvars(adder: Callable, flags: int) -> Array:
	var made: Array = []
	var defs := [
		[CVAR_ENABLE, "1" if enabled else "0", "Menu weapon changes right after spawning apply at once (1) or at the next spawn (0)"],
		[CVAR_WINDOW, str(window), "Seconds after spawning in which a menu change is instant"],
		[CVAR_RADIUS, str(radius), "An enemy within this many metres refuses an instant change"],
		[CVAR_QUIET, str(quiet), "Seconds since firing before an instant change is allowed"],
		[CVAR_COOLDOWN, str(cooldown), "Seconds between two instant changes by one player"],
	]
	for d: Array in defs:
		var cv: Variant = adder.call(d[0], d[1], d[2], flags)
		if cv is Object:
			_cvars[d[0]] = cv
			made.append(cv)
			if (cv as Object).has_signal(&"changed"):
				(cv as Object).connect(&"changed", _on_changed)
	refresh()
	return made


func _on_changed(_old: String, _new: String) -> void:
	refresh()


## Reads the cvars into the fields.
func refresh() -> void:
	if _cvars.has(CVAR_ENABLE):
		var v := _text(CVAR_ENABLE).to_lower()
		enabled = not (v == "0" or v == "false" or v == "off" or v == "no" or v == "")
	window = _num(CVAR_WINDOW, window)
	radius = _num(CVAR_RADIUS, radius)
	quiet = _num(CVAR_QUIET, quiet)
	cooldown = _num(CVAR_COOLDOWN, cooldown)


func _text(name: String) -> String:
	var c: Object = _cvars.get(name)
	return str(c.call("get_string")).strip_edges() if c != null and c.has_method("get_string") else ""


func _num(name: String, fallback: float) -> float:
	var t := _text(name)
	return maxf(t.to_float(), 0.0) if t.is_valid_float() else fallback


func describe() -> Dictionary:
	return {"enabled": enabled, "window": window, "radius": radius, "quiet": quiet, "cooldown": cooldown}
