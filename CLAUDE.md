# dot-loadout

What a player takes into a match. Read `../../CLAUDE.md` first for the family-wide
rules; this file is only what is specific to loadouts.

## The one idea

**A loadout is a document of ids, and validating it must not require any content.**

A dedicated server has no meshes, often no scenes, and possibly no downloaded content
at all. It still has to decide whether the thing a client just sent is legal. So a
`DotLoadout` is a mapping from slot ids to item ids, a `DotItem` is a description
rather than an asset, and `DotItemCatalogue.resolver` — the only thing that turns an
id into a real asset — is optional and only a client sets it.

`DotItemCatalogue.resolve()` on a server returns `CODE_STATE` saying so, rather than
null. "Not downloaded yet" and "no such item" are different problems and only one of
them is a bug.

## `validate` on the way in, `conform` on the way out

This is the distinction that matters and it is easy to collapse.

**`conform` on the way out of a store.** Retiring an item, adding a required slot or
tightening a budget makes every saved loadout containing the old thing invalid.
Refusing those is a player who has not logged in for a month loading into an error
rather than into a slightly different gun. `conform` never fails, which is why
`DotLoadoutSchema.validate` refuses a schema whose own defaults are not legal — a
conform that could fail would leave a player unable to spawn.

**`validate` on the way in from a client.** `DotLoadoutManager.publish` validates and
refuses. It does *not* conform. A client that can make the server repair its way to a
legal loadout can put anything in any slot and have the server pick the nearest legal
thing for it, which is a different feature from the one being offered.

## The trust boundary is `DotLoadoutManager.publish`

Everything else in the manager is convenience. That one method is where a document a
client controls becomes one the game acts on, and every check it makes is there for a
specific thing a hostile or buggy client does:

| Check | Without it |
| --- | --- |
| Rate limit | A loadout screen publishing on every click is a store write per frame |
| Per-player cap | A client that can add loadouts without bound can fill a disk |
| Schema membership | A slot the schema does not have is not a slot |
| Entitlements | That is what an unlock *is* |
| Key usability | A malformed key reaching a filesystem path |

A refused publish still spends a rate-limit token. Spamming invalid loadouts is the
abuse; exempting failures from the limit would exempt exactly the traffic worth
limiting.

**The cache is not updated on a failed write.** A cache that disagrees with the store
is worse than a refused publish: the player sees their change, plays with it, and
loses it at the next load with no explanation.

## The synthesised default is an edit target, not a saved loadout

A player with nothing stored is handed `schema.default_loadout()` so they can spawn.
Their first `publish` with no index **replaces** it rather than appending, and the
manager tracks that in `_synthesised`.

Appending was the first implementation and it was found by the self-test: a player who
had saved exactly once was holding two loadouts, and on a schema with a cap of one the
only publish they would ever make was refused.

## Entitlements default to nothing

`DotLoadoutEntitlements.none()` is the default and `entitlement_source` starts unset,
so an unwired server permits only items marked `DotItem.free`.

The other default is worse in a way that is hard to notice. A server that granted
everything by default would work perfectly in every test, ship, and quietly be a game
where every unlock is free — and nobody files that bug. A server that grants nothing is
wrong within thirty seconds of the first player pressing play.

`DotItem.entitlement_id` is the indirection that makes a bundle possible: several items
naming one unlock are granted together.

## Retired is not deleted

`DotItem.retired` keeps an item valid in a saved loadout while removing it from
`choices_for`. Deleting the item instead makes every loadout containing it invalid at
once, and `conform` then silently changes what a large number of players are carrying
on the same day.

## Pickups are deterministic, and that shapes both classes

`DotPickup` counts respawn in **ticks** and stores a target tick rather than a
countdown. Ticked twice on the same tick it respawns once — a countdown decremented per
call brings things back early on a replayed tick.

Reach is a **distance test**, not an `Area3D` overlap, and it is a horizontal distance
under a height gate rather than a sphere. A sphere makes a pickup at foot level
unreachable by a player whose position is their feet on one machine and their centre on
another; the height gate is what stops a pickup on the floor being taken from the
walkway above it.

`DotPickupField` ticks all of them, from one caller, with one tick number, in one
order. Sixty pickups each running their own `_physics_process` is sixty independent
timelines a replay cannot reproduce.

## `DotLoadoutKey` is a copy, deliberately

It duplicates dot-user-avatar's `DotAvatarKey.is_usable`. **Do not deduplicate it.**
Only dot-core is a hard dependency in this family, and a game that wants loadouts
without avatars must not have to install one to get the other — the same reason
dot-user-avatar carries its own rather than reusing dot-user's.

## Coupling: nothing is imported

dot-loadout names no class outside dot-core. Not dot-combat, not dot-net, not
dot-server.

- `DotLoadout.write` / `read` take `Variant`, so this project parses without dot-net
  installed. Inside `read`, the locals are **typed rather than inferred** —
  `var x := reader.read_string(...)` is a parse error under these projects' warning
  settings because a `Variant` return cannot be inferred.
- Ids go on the wire as **strings, not indices into the schema**. Indices are smaller
  and they are a version coupling: a schema that gains a slot renumbers every one after
  it, and two peers on different builds then decode each other's loadouts into the
  wrong slots without anything failing. A loadout is sent once per player per life.
- `DotLoadoutSlot.arsenal_slot` is a plain integer a game hands to `DotArsenal.give()`.
  dot-loadout has never heard of `DotArsenal`.
- `DotLoadoutManager.resolve` returns `[slot, arsenal_slot, item, count]` dictionaries
  rather than doing anything with them.

## Validating changes

```bash
cd godot/dot-loadout
ln -s ../../dot-core/addons/dot_core addons/dot_core   # gitignored
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/loadout_demo.tscn
```

145 checks, all offline. Exits non-zero on any failure.

**Run it after any change to the validator or the manager.** Several checks exist
because the obvious implementation is wrong: the synthesised-default replacement, the
store handing back copies rather than its own objects, the failed write that must not
update the cache, and a `from_dictionary` that must refuse a non-string item rather
than coercing it.

## Things deliberately not here

- **A loadout screen.** `DotLoadoutSchema.choices_for` is what one would be built on,
  and it deliberately returns what a player can *actually take* rather than everything
  a slot accepts — a screen that shows the second and refuses on submit is a screen
  that lies. The screen itself is a game's own design and belongs in dot-ui.
- **Item → weapon mapping.** `DotLoadoutSlot.arsenal_slot` is the hint; the table that
  turns `&"rifle"` into a `DotWeapon` is a game's, because importing dot-combat here
  would make loadouts unavailable to a game that does not use it.
- **Buying, currency, a shop.** Entitlements arrive from somewhere; where is the
  backbone's problem. `entitlement_source` is the whole seam.
- **Attachments and modifications.** A scope, a barrel and a stock on one weapon is a
  nested document with its own budget, and it is a genuinely different shape from a
  flat slot map. Doing it badly now would be harder to undo than adding it later.
- **Per-team or per-class schemas.** One manager holds one schema. A game with two
  runs two managers, or swaps `schema` between rounds. Making the manager hold a set
  keyed by something would guess at what that something is.
- **Dropping and picking up a carried weapon.** `DotPickup` grants an item; nothing
  spawns one from a player's current arsenal on death. That needs an item's runtime
  state (its remaining ammunition), which is dot-combat's `DotWeaponState`.
- **A backbone store backend.** `DotLoadoutStore` has the seam and there is a local
  and a memory implementation. The HTTP one waits on the backend protocol document —
  the same thing dot-user and dot-user-avatar are waiting on.
