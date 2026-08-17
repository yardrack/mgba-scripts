# mGBA Gen 3 scripts

Lua tools for the English releases of Pokemon Emerald, Ruby, Sapphire,
FireRed, and LeafGreen. The suite includes RNG capture information, automated
battling, Pickup farming, and shiny encounter hunting.

## Requirements

- mGBA 0.10 or newer with Lua scripting support
- An English Gen 3 ROM matching one of the launcher scripts

## Usage

1. Keep the launcher files and the `lib` directory together.
2. Open **Tools > Scripting**.
3. Load the matching launcher: `Emerald.lua`, `Ruby.lua`, `Sapphire.lua`,
   `FireRed.lua`, or `LeafGreen.lua`.
4. Open the matching ROM if it is not already loaded. The launcher will wait
   safely until mGBA provides the game core.

The suite also detects the loaded game automatically, so choosing a different
Gen 3 launcher by mistake will not prevent it from starting.

Use the controls shown in the scripting panels to switch tools. Tab is left
unbound so it remains available for mGBA fast-forward. The shared frame clock
keeps the panels and automation responsive while fast-forwarding.

In the Capture panel, press `G`, type a target RNG frame, and press Enter. Press
`J` to jump the live RNG state directly to that frame. This changes the game's
RNG state instantly; it does not change mGBA's separate video-frame counter.

Runtime settings and savestates are intentionally excluded from Git.
