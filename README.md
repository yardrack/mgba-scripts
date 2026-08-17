# mgba-scripts

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

Press `J` (or `F5`) to open the standalone Jump tool. Choose Starter or Wild
with `M`, press `G` to enter a known shiny frame (or `F` to search), and stop at
the final Yes button or highlighted Sweet Scent action. Press `R` to arm Jump;
it holds the corrected RNG state until your mapped GBA A button (`X` by
default) is detected. The result is verified automatically. A miss updates the
saved correction and tells you to soft reset, return to the ready action, and
press `R` again.

Stable mGBA Lua cannot pause or fast-forward the Qt frontend. Jump therefore
holds the RNG state until A instead of relying on reaction time or frontend
pause shortcuts. `Ctrl+N` remains mGBA's normal frame-advance shortcut.

Runtime settings and savestates are intentionally excluded from Git.
