# Whole Stone .io 🗿⚔️

> Arthur couldn't pull the sword from the stone… so he lifted the **entire stone**.

### ▶ [Play it in your browser](https://dd-ching.github.io/whole-stone-io/) — no install, Godot 4 WebGL build

A 2D top-down, physics-driven **.io brawler** built in **Godot 4.7**. You are the
chosen one who flunked the test: instead of a sword, you swing a whole boulder on the
end of your arm — a heavy, spring-damped pendulum you *whip* by dragging the mouse.
Smash rival knights, absorb what they shatter into, and **grow**. Bigger hits harder
and reaches further… but drags slower. Weight versus mobility, all the way up the
leaderboard.

Think **Snake.io's** one-more-run addiction, but the "growth" is the mass of the
stone you're heaving around.

<p align="center"><em>Placeholder art is drawn entirely in code — the repo runs straight from a clean checkout, no asset pipeline.</em></p>

## The hook

- **Momentum everything.** Arthur is slow to start and keeps drifting when you let go
  — a juggernaut, not a dancer. The stone follows your aim with *weight and lag* and
  never snaps to the cursor.
- **Whip, don't press.** There is no "click = attack." Damage is read straight off the
  head's real speed at contact: drag the mouse in circles to build angular momentum, and
  a fast sweep launches while a lazy nudge only shoves.
- **Grow or stay nimble.** Absorb gems and KO rivals to gain **mass**. Mass makes you
  bigger, tankier and longer-reaching, but slower to move and laggier to swing — the
  core risk/reward you feel every second.
- **Spill on death.** Get smashed and most of your mass sprays back out as loot for
  everyone to fight over. Then lift the stone again.

## Weapons

Grab a floating crate to swap your head:

| Head | Feel |
| --- | --- |
| **Stone** (default) | Balanced boulder — the sword's still stuck in it. |
| **Hammer (錘)** | Huge damage + knockback, but heavy and laggy to swing. |
| **Sickle (鐮)** | Fast, long reach, low knockback — wins on sustained speed. |

## Battlefield physics

The arena isn't flat. A procedural **contour map** (Gaussian-mutated noise, drawn as
topographic iso-lines) is really a **gravity gradient** — you slide *downhill*, so valleys
gather the crowd and loot while ridges shed you. Scattered across it are **force fields**
(each an Area2D on its own collision layer):

| Field | Effect |
| --- | --- |
| **Gravity well** | pulls everything inward, stronger toward the centre (梯度) |
| **Mana / magnet** | vacuums loose gems into a vortex (魔力/磁力場) |
| **Repulsor** | shoves everything outward (力場彈開) |
| **Current** | a conveyor that *adds* velocity; a cushion *subtracts* it (加減法) |
| **Air cushion** | soft armor: slow bodies settle, moderate bounce elastically, but a **hard/fast** hit **pierces** it and pops it (刺破 / 來不及緩衝) |
| **Reversal** | counter terrain — reflects your momentum back on entry (關鍵逆轉/相剋) |

Weapons have their **own collision layer**, so two fast-swung stones **clash** and bounce
apart. Fast movers leave a speed **afterimage** (影像速度). Loose gems are real RigidBody2Ds,
so every field, slam and clash flings them around.

## Controls

| Input | Action |
| --- | --- |
| **WASD** / arrows | Move (heavy, momentum-based) |
| **Mouse** | Aim — *drag it around yourself to whip the stone* |
| **Left mouse (hold)** | Commit a swing (spends stamina) |
| **Right mouse** | Overhead **slam** — a radial shockwave |
| **Space (hold)** | **Whirl** — a stamina-hungry tornado that launches the crowd |
| **R** / click | Respawn after you get smashed |

## Run it

You need [Godot **4.7+**](https://godotengine.org/download) (Standard / GDScript build).

```bash
# From the repo root:
godot .                       # opens the project, press F5 to play
# or run headless-less directly:
godot --path . scenes/Main.tscn
```

Or open the folder from the Godot Project Manager and hit **Play**.

**Web build:** the live version is a Godot HTML5/WebGL export (single-threaded, so it
runs on GitHub Pages without special headers). To rebuild it:

```bash
godot --headless --path . --export-release "Web" build/web/index.html
```

The exported `build/web/` is published to the `gh-pages` branch.

## How it's built

- **Godot 4.7**, GDScript 2.0, GL Compatibility renderer.
- **Code-first**: every entity builds its own nodes in `_ready()`. The only scene,
  `scenes/Main.tscn`, is a one-line bootstrap. All art is `_draw()` primitives.
- **Real physics**: fighters are `CharacterBody2D` (kinematic momentum), loot is
  `RigidBody2D` that gets batted around by swings and slams, walls are `StaticBody2D`.
- Tuning, run-state and signals live in one autoload, `scripts/Game.gd`.

```
scripts/
  Game.gd         # autoload: tuning constants, score/best/kills, signals, RNG
  Fighter.gd      # base body: momentum move, health, stamina, growth, death/loot
  Weapon.gd       # the pendulum head (stone/hammer/sickle) + hit resolution
  Player.gd       # mouse/keyboard control + camera
  Bot.gd          # hunt-smaller / flee-bigger / wander-to-gems AI
  Pickup.gd       # RigidBody2D gems + weapon crates
  GameCamera.gd   # follow + shake + zoom-out-as-you-grow
  Hud.gd          # score, leaderboard, bars, death overlay
  Main.gd         # arena, spawning, population, leaderboard, respawn
```

## Credits

The **main-character design** — the "lifted the whole stone" pendulum weapon and its
momentum-based feel — is reimagined from an earlier Godot prototype of mine. Everything
else here (the .io growth loop, bots, arena, loot, HUD, weapon variants) is new.

## License

[MIT](LICENSE)
