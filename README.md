# Unnamed Ball Fighter

A platform fighter where every character shares one mechanic: a **boomerang
ball**. Throw it at (or past) your opponent and it hooks them and drags them
back to you, so stray hits turn into long combos. Combos need variety:
repeating moves sends the enemy flying farther and gives less hitstun. The
defender gets real escape options: **Burst**, DI, teching, parrying and baits.

Built with Godot 4.3 (GDScript). The fight runs as a deterministic integer
simulation (`scripts/sim/`), which is what online rollback will use.

## Playing

Download `UnnamedBallFighter.exe` from the latest release and run it. No install.

- No second player? P2 is a **CPU opponent**. Pause to switch it to a training dummy.
- A second player joins by pressing any button on a controller (or the arrow
  keys + numpad on the same keyboard).
- Controllers are detected automatically and can be plugged in at any time.

| Action | Controller | Keyboard |
|---|---|---|
| Move | Left stick / D-pad | WASD |
| Attack | A | J |
| Special | B | K |
| Jump | X / Y | Space |
| Smash attack | Right stick, or flick + A | H + direction + J |
| Throw / recall ball | RB | L |
| Shield (tap = parry) | RT | Shift or ; |
| Grab | LT | U |
| Burst (meter full) | LB | O |
| Pause | Start | Esc |

F11 toggles fullscreen, F5 restarts the match, and F2 cycles the CPU mode.

## Development

```
godot --headless --script res://tests/test_sim.gd       # sim unit tests
godot --headless --script res://tests/combo_search.gd   # longest combo a perfect player finds
godot --headless --script res://tests/cpu_stats.gd      # CPU vs CPU soak test
godot --headless --export-release "Windows" build/UnnamedBallFighter.exe
```

Fonts: Inter (SIL Open Font License, see `assets/fonts/LICENSE-Inter.txt`).
All art and sound are generated in code.
