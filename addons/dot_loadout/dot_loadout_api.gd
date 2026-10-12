extends RefCounted

## dot-loadout's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: everything before this file existed (an absent file reads as 1).
# 2: a server owner's rules and the loadout menu's server half: DotLoadoutRules (parse, check,
#    permits, CVAR_MENU/CVAR_ALLOW/CVAR_FIXED); DotLoadoutManager.rules, set_rules(),
#    rules_changed, players_choose(), choices_for(), offer_for(); the optional `rules` argument
#    of DotLoadoutValidator.validate/conform and DotLoadoutSchema.choices_for,
#    DotLoadoutValidator.apply_fixed(); DotLoadoutCommand (the `loadout` command, the
#    `loadout_menu` notice, the mp_loadout_* cvars, closed_fn for a game's own reason).
const LEVEL := 2
const OLDEST := 1
