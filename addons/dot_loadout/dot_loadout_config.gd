@tool
class_name DotLoadoutConfig
extends DotConfig

## Everything configurable about loadouts. Layered like every [DotConfig]: exported
## defaults, then a JSON file, then [code]DOT_LOADOUT_*[/code] environment variables,
## then [code]--loadout-*[/code] arguments.

@export_group("Storage")

## Where loadouts live: [code]local[/code] or [code]memory[/code].
@export_enum("local", "memory") var backend: String = "local"

## Directory for the [code]local[/code] backend.
@export var directory: String = "user://loadouts"

@export var read_only: bool = false

@export_group("Policy")

## Give a player with no saved loadout the schema's default and let them play.
##
## Off holds them at a loadout screen until they pick one, which is a game with a
## meaningful choice. On is what a deathmatch wants: spawn with the rifle.
@export var allow_default_loadout: bool = true

## Repair a loadout that no longer fits the schema instead of refusing it.
##
## [b]On is strongly recommended.[/b] Retiring an item or adding a required slot makes
## existing loadouts invalid, and refusing them means a player who has not logged in
## for a month loads into an error rather than a slightly different gun.
@export var conform_on_load: bool = true

## Check entitlements when validating. [b]Never turn this off on a server.[/b]
##
## It exists for a client previewing its own work and for a creator sandbox. A server
## with it off accepts any loadout carrying anything.
@export var enforce_entitlements: bool = true

## Let a player change loadout while alive. Off means the change takes effect on their
## next spawn, which is what almost every shooter does and what stops a player
## swapping to a rocket launcher mid-fight.
##
## [b]The game enforces this, not the manager.[/b] A publish is stored either way —
## refusing it would lose the player's choice — and "alive" is something only the
## game knows. Read this when deciding whether to re-equip on publish or wait for
## the next spawn; dot-2d-hungry sets it false and equips on spawn.
@export var allow_live_changes: bool = false

@export_group("Limits")

## Saved loadouts one player may keep.
@export_range(1, 32, 1) var max_per_player: int = 5

## Loadout publishes allowed per player per minute.
##
## A client in a loadout screen can publish on every click. Without a limit that is a
## store write per frame.
@export_range(1, 240, 1) var publishes_per_minute: int = 12

## Players held in memory at once. 0 is unlimited.
@export_range(0, 100000, 64) var max_cached: int = 2048

## Seconds a fetched loadout stays cached after the player leaves.
@export_range(0.0, 3600.0, 5.0) var cache_ttl_sec: float = 300.0


func env_prefix() -> String:
	return "DOT_LOADOUT_"


func cli_prefix() -> String:
	return "--loadout-"


func validate() -> DotResult:
	if backend == "local" and directory.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "The local backend needs a directory."
		)

	if not enforce_entitlements:
		# Loud, because it is the one setting here that turns off a security control
		# and the symptom is players carrying things they have not unlocked, which
		# nobody reports as a bug.
		DotLog.warn(
			"loadout.config",
			"enforce_entitlements is off; any loadout will be accepted"
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "%s%s%s" % [
		backend,
		" read-only" if read_only else "",
		"" if enforce_entitlements else " UNENFORCED",
	]
