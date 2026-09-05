class_name DotLoadoutKey
extends RefCounted

## What a loadout may be keyed by, and how that string is checked.
##
## Loadouts are stored per player under the [b]scoped[/b] id dot-user derives, never
## an account id — the same rule dot-user-avatar follows, for the same reason: a file
## named after an account id lets two operators correlate their players by comparing
## directory listings.
##
## [b]This is a copy of dot-user-avatar's check, not a reuse of it.[/b] Only dot-core
## is a hard dependency in this family, and a game that wants loadouts without avatars
## must not have to install one to get the other. Do not "deduplicate" it.
##
## The check is structural. It says nothing about whether the key exists, and it is
## not authentication — it exists so a malformed key can never reach a filesystem path
## or a URL.

const MIN_LENGTH := 8
const MAX_LENGTH := 128


## Whether a key is safe to use as a storage key.
##
## Hex, base64url and a colon-separated scope prefix all pass; a path separator, a
## traversal, a NUL and anything non-printable do not.
static func is_usable(key: String) -> bool:
	if key.length() < MIN_LENGTH or key.length() > MAX_LENGTH:
		return false

	for index in range(key.length()):
		var c := key.unicode_at(index)

		var alnum := (
			(c >= 48 and c <= 57)
			or (c >= 65 and c <= 90)
			or (c >= 97 and c <= 122)
		)

		# '-', '_', '.' and ':' cover base64url, hex-with-scope and a dotted prefix.
		# '.' is permitted as a character but "." and ".." are refused below, because
		# the danger is the whole segment, not the character.
		if not alnum and c != 45 and c != 95 and c != 46 and c != 58:
			return false

	if key == "." or key == ".." or key.contains(".."):
		return false

	return true


## A key with an explicit scope, for a store shared between games.
static func scoped(scope: String, key: String) -> String:
	return "%s:%s" % [scope, key] if scope != "" else key
