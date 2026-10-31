# Native player lobby and endpoint resolution

The native library implements these read-only player routes:

```
GET /lobby/ladders/{ladderId}/v2/games
GET /lobby/ladders/{ladderId}/v2/games/{gameId}/resolve
```

Both require the narrow game-session token and this ladder's current launch
ticket. Wrong-ladder and expired credentials fail before HTTP. There is no
launcher-token fallback or automatic retry on refusal. Game IDs are bounded
ASCII path components; they are not assumed to be UUIDs. The administrative
`/servers` route is not used.

`LobbyGameList` reads the `games`/`totalPlayers` root, room/player metadata and
environment summaries. `ResolvedLobbyGame` reads the selected game's `address`,
`port`, `game_number` and environment summary. The port and game number must fit
the original unsigned 16-bit fields. A transport hostname may be longer than
the engine's 23-byte address capacity; `fitsOriginalEngineAddress` reports that
separately, and no hostname is truncated. Resolving does not open a socket,
start the engine or mount/send a character.

The room's environment is **server metadata**, never evidence of the client's
own compatibility. `LobbyEnvironmentSummary` is a partial read-only view of
policy version, coverage, component count, digest, groups and shared plugins.
It does not encode D2EM, evaluate the full fingerprint contract or implement
the required plugins. In particular, unmodeled `shared_patches` and listing
fields are not silently turned into native capability claims.

## Live verification

On 31 October 2026 a signed native macOS probe, identifying its actual native
platform and application version, validated fresh policy against a separately
verified signed revision-5 package and obtained a launch ticket. The public
library's typed methods accepted the real player list (452 rooms, 487 players
at that observation) and a selected room's resolve response. These counts are
a snapshot, not availability guarantees.

The same inspection connected `GameTCPStream` to that advertised endpoint and
received exactly `af 00`, with TCP ready/error zero. It sent **zero bytes** and
closed the connection. No original game code, character data, D2EM manifest or
admission request was sent. This confirms a reachable game endpoint and its
initial reply, not gameplay framing/compression, admission or ladder play.

No character was created, uploaded, deleted, downloaded or mounted; no iPhone
application was installed or started. Offline saves and GTA were untouched.
Token revocation was requested and accepted; that particular token was not
subsequently reused to independently check a 401 response.

The routes and fields were first derived from the current signed bundle's
lobby bridge and then checked against actual authenticated player responses.
No player names, game names, server addresses, account identifiers, secrets,
original executable bytes or game assets are stored in the public fixtures.
`GameLobbyTests` uses synthetic metadata to check scope, expiry, path injection,
credential selection, refusals, endpoint bounds and contradictory metadata.

Remaining: complete native environment/plugin equivalence and admission,
verified stock packet framing/sizing, the real engine packet pump, isolated
server character handling and a confirmed progress/save/reload/reconnect on
iPhone. No Join button is exposed by this read-only library change.

For a physical-device account-screen check, launch `-mode online` with the
explicit environment switch `DM_ONLINE_DIAGNOSTICS=1`. The screen writes
`Documents/online-state.json` (build/native identity, counts and UI state) and
`online-ui.png`. Capture is suppressed while the authorization browser is
presented; credentials, account identifiers and HTTP bodies are excluded.
This opt-in diagnostic does not sign in, join a game or modify saves.

The diagnostic was exercised on a physical iPhone on 31 October 2026, after a
complete development app update. Device-side metadata and the captured account
screen identified build `1793469345` (code commit `c4cef3d`), the actual native
iOS User-Agent and one live ladder. The user was signed out. The same build's
original game character-selection scene also rendered on-device, including the
existing character. A save read independently before and after installation was
byte-identical. Shader libraries matched the existing local renderer chain;
the development package used the repository's free-team packaging variant.
Original game resources, generated libraries, signed apps, private identities
and device captures are not published here. This is a startup/UI verification,
not a world-performance, authenticated-login or playable-ladder result.

Subsequently, the user completed the official authorization flow on that
physical iPhone. A new device-side diagnostic identified the same build with
`signedIn=true`, one ladder and eight regions after ladder selection. An
independent capture showed the signed-in native account screen. After a
separate original-game test and a return to the account screen, a fresh
diagnostic still reported `signedIn=true`; no Mac session was copied into the
iPhone. This confirms device authorization, authenticated policy/region reads
and local session persistence across app restart. It does not confirm a
device-side launch ticket, player-room list, game admission or server save.
