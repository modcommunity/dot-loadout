# dot-loadout

What a player takes into a match: a schema of slots, a catalogue of items, saved loadouts per player, entitlements, and deterministic world pickups. A loadout is a document of ids, so a dedicated server with no content can still decide whether one is legal.

Read the family [CLAUDE.md](../../CLAUDE.md) first.

**The distributable is `addons/dot_loadout/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). It names no class outside dot-core in code; dot-weapon's `DotWeaponLoadoutBridge` consumes `DotLoadoutManager.resolve`'s output by duck typing.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | changing the validator, the manager, the store, entitlements or pickups: ids not assets, validate vs conform, the trust boundary, the synthesised default, why nothing is imported, what is deliberately not here |

## Layout

| Path | What |
| --- | --- |
| `core/dot_loadout.gd` | `DotLoadout`: slot id to item id, dictionary and wire (`write`/`read`) forms |
| `core/dot_loadout_schema.gd`, `dot_loadout_slot.gd` | `DotLoadoutSchema` (slots, `default_loadout`, `choices_for`), `DotLoadoutSlot` (`arsenal_slot`) |
| `core/dot_item.gd`, `dot_item_catalogue.gd` | `DotItem` (`free`, `entitlement_id`, `retired`), `DotItemCatalogue` (optional client-side `resolver`) |
| `core/dot_loadout_validator.gd` | `DotLoadoutValidator.validate` (refuses) and `conform` (never fails) |
| `core/dot_loadout_entitlements.gd`, `dot_loadout_key.gd` | `DotLoadoutEntitlements` (`none()` default), `DotLoadoutKey.is_usable` |
| `dot_loadout_manager.gd` | `DotLoadoutManager`: cache, `publish` (the trust boundary), `resolve` |
| `dot_loadout_config.gd` | `DotLoadoutConfig`: store backend, policy (`conform_on_load`, `enforce_entitlements`, `allow_default_loadout`), `publishes_per_minute`, `max_per_player`, cache size and TTL |
| `store/` | `DotLoadoutStore` (interface), `DotLoadoutStoreLocal`, `DotLoadoutStoreMemory` |
| `world/` | `DotPickup` (tick-counted respawn, distance reach), `DotPickupField` (ticks them all) |
| `examples/loadout_demo.tscn` | the suite, offline |

Paths except `examples/` are in `addons/dot_loadout/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/loadout_demo.tscn`; it exits non-zero on any failure. Run it after any change to the validator or the manager: several checks exist because the obvious implementation is wrong (the synthesised-default replacement, the store handing back copies rather than its own objects, the failed write that must not update the cache, and `from_dictionary` refusing a non-string item rather than coercing it).

## Rules that bite

- Validation never needs content; `DotItemCatalogue.resolve` without a resolver returns `CODE_STATE`, not null. [design](docs/design.md#a-loadout-is-a-document-of-ids)
- `conform` on the way out of a store, `validate` on the way in from a client; `publish` never conforms. [design](docs/design.md#validate-on-the-way-in-conform-on-the-way-out)
- `DotLoadoutSchema.validate` refuses a schema whose own defaults are illegal, because `conform` must never fail. [design](docs/design.md#validate-on-the-way-in-conform-on-the-way-out)
- A refused publish still spends a rate-limit token; a failed store write never updates the cache. [design](docs/design.md#the-trust-boundary-is-dotloadoutmanagerpublish)
- The first publish with no index replaces the synthesised default (`_synthesised`), it does not append. [design](docs/design.md#the-synthesised-default-is-an-edit-target-not-a-saved-loadout)
- Entitlements default to nothing: an unwired server permits only `DotItem.free`. [design](docs/design.md#entitlements-default-to-nothing)
- Retire an item (`DotItem.retired`), never delete it from the catalogue. [design](docs/design.md#retired-is-not-deleted)
- Pickups count ticks to a target tick, reach is horizontal distance under a height gate, and only `DotPickupField` ticks them. [design](docs/design.md#pickups-are-deterministic)
- `DotLoadoutKey` duplicates `DotAvatarKey` on purpose; do not deduplicate. [design](docs/design.md#dotloadoutkey-is-a-copy-deliberately)
- Lists of ids (`filled_slots`, `to_list`, `ids`) sort **by text** with `sort_custom`, never `sort()`: StringNames sort by interning, which differs per process, and `digest()` depends on it. [gdscript-hazards](../../docs/gdscript-hazards.md)
- Name no class outside dot-core; `write`/`read` take `Variant` and type their locals explicitly. Ids go on the wire as strings, never schema indices. [design](docs/design.md#coupling-nothing-is-imported)

## Open

- **No backbone store, by decision (2026-10-11).** No client exists, every game uses the memory store, and games key loadouts by session id, which no backbone can resolve; so there is no website-city loadout route either. What would have to change first, and the shape to build: [design](docs/design.md#no-backbone-store-yet-and-why).

Deliberately not here: a loadout screen, buying or a shop, attachments, per-team schemas, dropping a carried weapon. [design](docs/design.md#deliberately-not-here)
