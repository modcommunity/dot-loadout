class_name DotLoadoutNames
extends RefCounted

## What a player may call a saved loadout: shown to them, never interpreted.

const MAX_LENGTH := 32


## The trimmed name with control characters dropped, or a refusal when nothing is left.
static func clean(raw: String) -> DotResult:
	var out := ""
	for ch in raw.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			out += ch
	out = out.strip_edges().substr(0, MAX_LENGTH)
	if out == "":
		return DotResult.fail(DotError.CODE_INVALID, "a loadout needs a name")
	return DotResult.success(out)
