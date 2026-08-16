# mGBA Gen 3 scripts

Lua tools for the English releases of Pokemon Emerald, Ruby, Sapphire,
FireRed, and LeafGreen. The suite includes RNG capture information, automated
battling, Pickup farming, and shiny encounter hunting.

## Requirements

- mGBA 0.10 or newer with Lua scripting support
- An English Gen 3 ROM matching one of the launcher scripts

## Usage

1. Keep the launcher files and the `lib` directory together.
2. Open the matching ROM in mGBA.
3. Open **Tools > Scripting**.
4. Load the matching launcher: `Emerald.lua`, `Ruby.lua`, `Sapphire.lua`,
   `FireRed.lua`, or `LeafGreen.lua`.

Use the controls shown in the scripting panels to switch tools. Tab is left
unbound so it remains available for mGBA fast-forward. The shared frame clock
keeps the panels and automation responsive while fast-forwarding.

Runtime settings and savestates are intentionally excluded from Git.

## Tests

Pure Lua checks are available under `tests`. On Windows with Lua installed:

```powershell
.\tests\run_all.ps1
```
