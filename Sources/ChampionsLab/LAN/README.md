# LAN Battles

Two people, two copies of the app, one network. This folder is the part
that finds the other person, asks them for a battle, and carries the game
between the two machines. The model of how a battle is carried is Pokemon
Showdown's, which has solved this for a long time and in public:

- **One machine owns the battle.** Showdown's server runs the simulator;
  the players run clients that only ever see what the server sends them.
  Here the player who asked is the host and runs `TurnModel` with real
  dice; the other player's app sends choices and renders what comes back.
  Neither app trusts the other for anything but its own choices.

- **Two streams, not one.** Showdown's `BattleStream` splits its output
  into an `update` every player sees and a `sideupdate` for one player,
  and a line that differs by who is looking -- exact health for the owner,
  a percentage for everyone else -- is written twice behind a `|split|`
  marker and routed by `extractChannelMessages`. The host here sends the
  same two things after every turn: the public steps of the turn (what
  moved, what it did, health as the game shows it to the other side) and,
  to each player, their own side in full -- the stages, status, held item,
  moves and PP of their own Pokemon, and what they may choose next. That is
  the shape of Showdown's `|request|`: `active` says what your Pokemon can
  do, `side` says what your team is. The other side's held items, moves
  and spreads are never on the wire until the game itself reveals them,
  and then only as the revealing line.

- **Choices are requests answered.** A turn does not resolve until both
  players have answered the host's request for one; a replacement after a
  faint, or a pivot's choice of who comes in, is a request too, sent only
  to the side that has the decision. Showdown's `rqid` ties an answer to
  the request it was for, so an undo cannot answer the wrong turn; the host
  here numbers its requests the same way.

The engine's advice is the player's to switch on or off in a LAN game. On,
it reads the same view the player has -- its beliefs about the other side
come from usage, as they do against the app's own opponent -- so nothing
it says can rest on information the player could not have.

## Files

| File | Owns |
| --- | --- |
| `Wire.swift` | Every message the two apps exchange, and how a stream is framed: a four-byte length, then JSON. `Six` is a team as Team Preview shows it. |
| `LANService.swift` | Bonjour advertising and browsing (`_championslab._tcp`), one connection at a time, the invitation, and the room both players share before a battle. |

The screen is `Screens/LANView.swift`; a request to battle reaches the
player anywhere in the app as `InviteBanner`, put up by `RootView`.

## What is built, and what is next

Built: finding each other, the request and its answer, and the room --
the host's format, each side's team as the other may see it, each side
ready.

Next, in order: Team Preview over the connection (each side's four and
their order, sent to the host); the opening and each turn as a public
step stream plus a per-side request; replacements and pivots as requests
to the side that decides; the engine toggle; the result into both
players' histories.
