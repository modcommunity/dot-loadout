@tool
class_name DotPickup
extends Node3D

## Something on the floor that a player can walk over and take.
##
## [b]Deterministic and tick-driven.[/b] Respawn timers are counted in ticks, not
## seconds, and taking is decided by distance rather than by an `Area3D` overlap. Both
## for the same reason: a client predicts picking something up, the server re-runs it,
## and an area callback fires on whichever frame the physics server got to it — which
## is not the same frame on two machines.
##
## The item itself is not resolved. A pickup holds an item [i]id[/i]; what that looks
## like is a game's business, and a dedicated server with no content still has to run
## the pickup logic.

const CHANNEL := "loadout.pickup"

## Someone took it. [param taker] is the game's own id space.
signal taken(taker: int, tick: int)

## It came back.
signal respawned(tick: int)

@export_group("Contents")

## What is being given. Looked up in the catalogue by whoever handles [signal taken].
@export var item_id: StringName = &""

## How many. Zero uses the item's own default.
@export_range(0, 999, 1) var count: int = 0

## Ammunition pool this tops up instead of granting an item, for an ammo box.
## When set, [member item_id] is ignored.
@export var ammo_pool: StringName = &""

@export_range(0, 9999, 1) var ammo_amount: int = 0

@export_group("Respawn")

## Seconds before it comes back. Zero never respawns.
@export_range(0.0, 600.0, 0.5) var respawn_sec: float = 30.0

## Available from the start of the match. Off makes it respawn in first.
@export var starts_available: bool = true

@export_group("Taking")

## Metres. A player whose position is within this is close enough.
##
## Generous on purpose: this is compared against a simulated position that differs by
## up to a tick of movement between client and server, and a tight radius makes a
## predicted pickup mispredict constantly.
@export_range(0.1, 10.0, 0.05) var radius: float = 1.2

## Vertical tolerance. Separate from [member radius] because a pickup on the floor
## should not be reachable from a walkway directly above it.
@export_range(0.1, 20.0, 0.1) var height: float = 2.0

## Only these may take it. Empty means anyone. A game mode's own tags.
@export var require_tags: Array[StringName] = []

## Whether taking it while already full is allowed. Off leaves a health pack on the
## floor for someone who needs it, which is what almost every arena shooter does.
@export var allow_wasteful_pickup: bool = false

## Whether it is there right now.
var available: bool = true

## Tick it becomes available again. -1 when it is available or never respawns.
var respawn_tick: int = -1

## Who took it last, for a kill feed and for tests.
var last_taker: int = 0

var _tick_rate: int = 60


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	available = starts_available


func set_tick_rate(rate: int) -> void:
	_tick_rate = maxi(1, rate)


func respawn_ticks() -> int:
	return maxi(1, int(round(respawn_sec * float(_tick_rate))))


## Whether [param position] is close enough to take this.
func in_range(position: Vector3) -> bool:
	var offset := position - global_position

	if absf(offset.y) > height:
		return false

	# Horizontal distance only, once the height gate has passed. A spherical test
	# makes a pickup at foot level unreachable by a standing player whose position is
	# their feet on one machine and their centre on another.
	return Vector2(offset.x, offset.z).length() <= radius


## Takes it, if it can be taken.
##
## [param wanted] is whether the taker actually has room — a caller passes false for a
## health pack at full health. With [member allow_wasteful_pickup] off that is a
## refusal, which leaves the pack on the floor for someone who needs it.
func take(taker: int, tick: int, wanted: bool = true) -> DotResult:
	if not available:
		return DotResult.fail(DotError.CODE_STATE, "This pickup is not available.")

	if not wanted and not allow_wasteful_pickup:
		return DotResult.fail(
			DotError.CODE_STATE, "The taker has no room for this."
		)

	available = false
	last_taker = taker
	respawn_tick = tick + respawn_ticks() if respawn_sec > 0.0 else -1

	taken.emit(taker, tick)
	return DotResult.success(true)


## Advances the respawn timer.
##
## Idempotent in a specific way: called twice on the same tick it respawns once,
## because the timer is a target tick rather than a countdown. A countdown decremented
## per call is how a replayed tick respawns something early.
func tick(current_tick: int) -> bool:
	if available or respawn_tick < 0 or current_tick < respawn_tick:
		return false

	available = true
	respawn_tick = -1
	respawned.emit(current_tick)
	return true


## Puts it back immediately. What a round reset does.
func reset(tick: int = 0) -> void:
	available = starts_available
	respawn_tick = (
		-1 if starts_available or respawn_sec <= 0.0 else tick + respawn_ticks()
	)
	last_taker = 0


## Seconds until it returns, for a HUD timer. Negative when it is available.
func seconds_remaining(current_tick: int) -> float:
	if available or respawn_tick < 0:
		return -1.0
	return float(respawn_tick - current_tick) / float(_tick_rate)


func is_ammo() -> bool:
	return ammo_pool != &""


func describe() -> Dictionary:
	return {
		"node": name,
		"item": String(item_id),
		"ammo": String(ammo_pool),
		"available": available,
		"respawn_tick": respawn_tick,
		"last_taker": last_taker,
	}


func _to_string() -> String:
	return "DotPickup(%s, %s)" % [
		ammo_pool if is_ammo() else item_id,
		"available" if available else "taken",
	]
