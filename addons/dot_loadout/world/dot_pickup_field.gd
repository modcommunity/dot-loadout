@tool
class_name DotPickupField
extends Node

## Every [DotPickup] in a level, ticked together.
##
## Collecting them here rather than having each one run its own `_physics_process` is
## not a micro-optimisation: a pickup that ticks itself ticks on whatever schedule the
## engine gives it, and a level with sixty of them then has sixty independent
## timelines that a replay cannot reproduce. One caller, one tick number, one order.
##
## The proximity sweep is the same argument. `Area3D` overlaps arrive on the physics
## server's schedule and are a frame stale after anything moves; comparing simulated
## positions is exact and gives the same answer on a predicting client and an
## authoritative server.

const CHANNEL := "loadout.pickups"

## Someone took something. Carries the pickup so a handler can read what it held.
signal collected(pickup: DotPickup, taker: int, tick: int)

@export_group("Wiring")

## Where the pickups live. Empty collects from this node's own children.
@export var container_ref: DotNodeRef = null

@export_group("Simulation")

## Must match whatever drives [method tick].
@export_range(1, 240, 1) var tick_rate: int = 60

## Whether taking is decided here at all.
##
## Off on a client: the sweep still runs so a HUD can show what is nearby, but nothing
## is taken. A client that took its own pickups would be a client that decides what it
## has.
@export var is_authority: bool = true

var _pickups: Array[DotPickup] = []

## `func(taker: int, pickup: DotPickup) -> bool`. Whether the taker has room.
##
## Left unset every pickup is wanted, which makes [member DotPickup.allow_wasteful_pickup]
## irrelevant — so a game with health packs should wire it.
var wants_fn: Callable = Callable()

## `func(taker: int) -> Array[StringName]`. The taker's tags, for
## [member DotPickup.require_tags]. Left unset, tag requirements are ignored.
var tags_fn: Callable = Callable()

var _collected: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	refresh()


## Re-collects the pickups. Call after building a level at runtime.
func refresh() -> void:
	_pickups.clear()

	var root: Node = self

	if container_ref != null:
		var resolved := container_ref.resolve_or_null(self, CHANNEL)
		if resolved != null:
			root = resolved

	_collect(root)

	for pickup in _pickups:
		pickup.set_tick_rate(tick_rate)

	DotLog.debug(CHANNEL, "pickups collected", {"count": _pickups.size()})


func _collect(node: Node) -> void:
	for child in node.get_children():
		if child is DotPickup:
			_pickups.append(child)
		_collect(child)


func pickups() -> Array[DotPickup]:
	return _pickups


func available_count() -> int:
	var count := 0
	for pickup in _pickups:
		if pickup.available:
			count += 1
	return count


## Advances every respawn timer.
func tick(current_tick: int) -> int:
	var respawned := 0

	for pickup in _pickups:
		if pickup.tick(current_tick):
			respawned += 1

	return respawned


## Offers every available pickup within reach of [param position] to [param taker].
##
## Returns what was actually taken. Order is declaration order, which is stable across
## machines — sorting by distance would be nicer and is not worth a per-call sort on
## something that runs once per player per tick.
func sweep(taker: int, position: Vector3, current_tick: int) -> Array[DotPickup]:
	var out: Array[DotPickup] = []

	for pickup in _pickups:
		if not pickup.available:
			continue

		if not pickup.in_range(position):
			continue

		if not _tags_allow(taker, pickup):
			continue

		if not is_authority:
			# The client still reports what it is standing on, so a HUD can prompt.
			out.append(pickup)
			continue

		var wanted := true

		if wants_fn.is_valid():
			wanted = bool(wants_fn.call(taker, pickup))

		var res := pickup.take(taker, current_tick, wanted)

		if not res.ok:
			continue

		_collected += 1
		out.append(pickup)
		collected.emit(pickup, taker, current_tick)

	return out


func _tags_allow(taker: int, pickup: DotPickup) -> bool:
	if pickup.require_tags.is_empty():
		return true

	if not tags_fn.is_valid():
		return true

	var value: Variant = tags_fn.call(taker)

	if typeof(value) != TYPE_ARRAY:
		return true

	for tag in pickup.require_tags:
		if (value as Array).has(tag):
			return true

	return false


## Puts everything back. What a round reset does.
func reset(current_tick: int = 0) -> void:
	for pickup in _pickups:
		pickup.reset(current_tick)


func describe() -> Dictionary:
	return {
		"pickups": _pickups.size(),
		"available": available_count(),
		"collected": _collected,
		"authority": is_authority,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("pickups  %d, %d available" % [_pickups.size(), available_count()])
	for pickup in _pickups:
		out.append("  %-16s %s" % [
			pickup.ammo_pool if pickup.is_ammo() else pickup.item_id,
			"available" if pickup.available else "respawns at %d" % pickup.respawn_tick,
		])
	return out
