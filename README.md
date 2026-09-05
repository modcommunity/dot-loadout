This is the **loadout** asset for TMC's **Dot** collection. It answers what a player is allowed to bring into a match, and it answers it on the server without loading a single asset.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Loadouts a Server Can Validate
What a player takes into a match, as a bounded document a dedicated server can
validate against a schema and a set of entitlements **without loading any content at
all**. Items, slots, budgets, stores, and deterministic world pickups.

Part of the [dot-*](../NOTES.md) family. Needs **dot-core** and nothing else.

## Install

Copy `addons/dot_loadout/` and `addons/dot_core/` into your project and enable both in
*Project → Project Settings → Plugins*.

## Use

```gdscript
# Server: what is this player spawning with?
var res := await loadouts.active_for(user_key)
for entry in loadouts.resolve(res.value):
    arsenal.give(weapon_for(entry["item"]), entry["arsenal_slot"])

# Server: a client sent us a new one.
var published := await loadouts.publish(user_key, submitted)
if not published.ok:
    DotLog.warn("game", "loadout refused: %s" % published.error)
```

## The idea

A loadout is a mapping from slot ids to item ids. Nothing else — no scenes, no meshes,
no weapon resources. A server receives one from an untrusted client, checks it against
a `DotLoadoutSchema` and a `DotLoadoutEntitlements`, and hands it to the game, on a
machine that may have none of the content installed.

The same trade dot-user-avatar makes, for the same reason: **the thing a client sends
must be checkable by a machine that has none of the content.**

## What is in the box

| | |
| --- | --- |
| `DotItem` | One thing a player can take. Kind, slots, tags, cost, weight, entitlement. |
| `DotItemCatalogue` | Every item by id, plus the optional client-side resolver that turns one into an asset. |
| `DotLoadoutSlot` | A position and what fits in it. Kinds, required tags, forbidden tags. |
| `DotLoadoutSchema` | The slots, the catalogue, and the point and weight budgets. A game mode's equipment rules. |
| `DotLoadout` | The document. Bounded, JSON- and wire-serialisable, order-independent digest. |
| `DotLoadoutEntitlements` | What one player may take. Empty by default. |
| `DotLoadoutValidator` | `validate` for the trust boundary, `conform` for the way out of a store. |
| `DotLoadoutStore` | Where they live. Memory and local-JSON backends included. |
| `DotLoadoutManager` | Loading, caching, and the one method a client's submission goes through. |
| `DotPickup` / `DotPickupField` | Things on the floor. Tick-driven, distance-tested, deterministic. |

## Two failure modes it is built around

**Everyone owns everything.** `DotLoadoutEntitlements` starts empty and
`DotLoadoutManager.entitlement_source` starts unset, so an unwired server permits only
items marked `free`. That is loud and gets fixed in a minute. The other default —
granting everything — is silent, and is a game where every unlock is free.

**A schema change locks players out.** Retiring an item or adding a required slot makes
every saved loadout invalid. `conform` repairs on the way *out* of a store so a player
who has not logged in for a month gets a slightly different gun rather than an error.
`validate` refuses on the way *in* from a client, because a client that can make the
server repair its way to a legal loadout can put anything anywhere.

## Pickups are not `Area3D`s

Respawn timers count ticks, not seconds, and reach is a distance test rather than a
physics overlap. Both because a client predicts picking something up and the server
re-runs it: an area callback fires on whichever frame the physics server got to it,
which is not the same frame on two machines.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/loadout_demo.tscn
```

145 checks, all offline. Exits non-zero on any failure.
