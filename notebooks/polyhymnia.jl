### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    #! format: off
    return quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
    #! format: on
end

# ╔═╡ a1000000-0000-4000-8000-000000000002
begin
    import Pkg
    # Use the project's environment rather than Pluto's own package manager.
    Pkg.activate(dirname(@__DIR__))
    using Polyhymnia
    using PlutoUI
end

# ╔═╡ a1000000-0000-4000-8000-000000000001
md"""
# 🎵 Polyhymnia

Live-codeable music, in the spirit of [strudel.cc](https://strudel.cc) — built on
[Euterpe.jl](https://github.com/SquidSinker/Euterpe.jl) for synthesis.

**Edit the pattern cell below and the music updates as you go.** Patterns are
functions of time, so a change swaps in at the next cycle boundary instead of
restarting the sound.
"""

# ╔═╡ a1000000-0000-4000-8000-000000000003
md"## Transport"

# ╔═╡ a1000000-0000-4000-8000-000000000004
engine = live(cps = 0.5, sink = WebAudioSink(cycles = 4))

# ╔═╡ a1000000-0000-4000-8000-000000000005
md"""
Tempo: $(@bind bpm Slider(60:200, default = 120, show_value = true)) bpm
"""

# ╔═╡ a1000000-0000-4000-8000-000000000006
# Returns the engine, now at tempo. Cells below depend on `clock` rather than
# `engine` so that moving the slider actually re-runs them: Pluto reacts to
# names being redefined, not to objects being mutated.
clock = set_bpm!(engine, bpm)

# ╔═╡ a1000000-0000-4000-8000-000000000007
md"""
## ✏️ The pattern

This is the cell to play with. Everything below reacts to it.
"""

# ╔═╡ a1000000-0000-4000-8000-000000000008
pattern = overlay(
    # Bare words are sound names, so drums need no wrapping.
    m"bd*2 [~ bd] bd ~" |> gain(1.0),
    m"~ sd ~ sd" |> gain(0.85),
    m"hh*8" |> gain(0.32) |> pan(sine_lfo),

    # Pitches go through `note`; the waveform is a separate control.
    note("<c2 g2 eb2 f2>") |> sound("saw") |> gain(0.5) |> cutoff(saw_lfo * 1400 + 250) |> release(0.25),

    # note("<c4 eb4> <g4 bb4> ~ <eb5 d5>") |> sound("tri") |> gain(0.3) |> release(0.35),
)

# ╔═╡ a1000000-0000-4000-8000-00000000000a
md"""
## ▶ Player

Press play once. After that, every edit above swaps the loop at the next cycle
boundary — the sound never stops.
"""

# ╔═╡ a1000000-0000-4000-8000-00000000000b
# Naming `pattern` and `clock` here is what makes this cell re-run on every edit.
webaudio(play!(clock, pattern))

# ╔═╡ a1000000-0000-4000-8000-00000000000c
transport(clock)

# ╔═╡ a1000000-0000-4000-8000-00000000000d
md"## 👁 What it looks like"

# ╔═╡ a1000000-0000-4000-8000-00000000000e
pattern_plot(pattern, cycles = 4, width = 700)

# ╔═╡ a1000000-0000-4000-8000-00000000000f
md"""
## 📖 Mini-notation

Written inside `m"..."` (or `mini("...")`).

| syntax | meaning |
|:--|:--|
| `bd sd` | a sequence, one cycle split evenly |
| `[bd sd] hh` | subdivide a step |
| `<bd sd>` | alternate, one per cycle |
| `bd*4` / `bd/2` | faster / slower |
| `bd!3` | repeat three times |
| `bd@3 sd` | weighted steps (3:1) |
| `bd _ _ sd` | elongate — same as `bd@3 sd` |
| `~` | a rest |
| `bd?` / `bd?0.3` | randomly drop (deterministic per cycle) |
| `bd(3,8)` | euclidean rhythm |
| `bd(3,8,2)` | euclidean, rotated |
| `bd, hh*4` | layer two sequences |

### Sounds

Drums: `bd sd sn hh oh cp rim lt mt ht` — synthesised, not sampled.
Waveforms: `sine square saw tri noise`, pitched by `note`/`n`.

A bare word names a **sound**, so drums need no wrapping — but pitches must go
through `note`. (`m"c3 e3" |> sound("saw")` would set the sound twice and lose
the pitch.)

### Controls

`gain pan attack decay sustain release cutoff hcutoff shape speed legato`

Chain them with `|>`:

```julia
note("c3 e3 g3") |> sound("saw") |> cutoff(800) |> gain(0.6)
```

### LFOs

`sine_lfo cosine_lfo saw_lfo isaw_lfo tri_lfo square_lfo rand_lfo` — all run
0→1 once per cycle and take arithmetic:

```julia
cutoff(saw_lfo * 2000 + 200)
```

### Pattern functions

`fast slow rev every zoom degrade degrade_by euclid overlay seq slowseq`

```julia
every(4, rev, m"bd sd hh cp")
```
"""

# ╔═╡ a1000000-0000-4000-8000-000000000010
md"""
## 🔊 Backends

Two ways to make sound, chosen when you build the engine:

- **`WebAudioSink(cycles = n)`** — Julia renders `n` cycles, the browser loops
  them. No sound device needed, works over a network. Variation longer than
  `n` cycles repeats, so widen the window for long-form patterns.
- **`PortAudioSink()`** — Julia streams continuously to the sound card. Endless
  variation, no looping. Needs a working audio device.

`default_sink()` picks PortAudio when a device exists and falls back to WebAudio.

To switch this notebook to the sound card, change the engine cell to
`live(cps = 0.5, sink = PortAudioSink())` — and start Julia with `-t auto`, since
PortAudio needs a spare thread to render while it writes.

On WSL2, PortAudio finds no devices until ALSA is pointed at WSLg's PulseAudio;
`ensure_alsa_config!()` does that automatically, re-initialising PortAudio so the
config takes effect.
"""

# ╔═╡ a1000000-0000-4000-8000-000000000011
md"## 💾 Export"

# ╔═╡ a1000000-0000-4000-8000-000000000012
# Uncomment to write the current pattern to disk.
write(joinpath(@__DIR__, "out.wav"), wav(engine, cycles = 8))

# ╔═╡ Cell order:
# ╟─a1000000-0000-4000-8000-000000000001
# ╠═a1000000-0000-4000-8000-000000000002
# ╟─a1000000-0000-4000-8000-000000000003
# ╠═a1000000-0000-4000-8000-000000000004
# ╟─a1000000-0000-4000-8000-000000000005
# ╠═a1000000-0000-4000-8000-000000000006
# ╟─a1000000-0000-4000-8000-000000000007
# ╠═a1000000-0000-4000-8000-000000000008
# ╟─a1000000-0000-4000-8000-00000000000a
# ╠═a1000000-0000-4000-8000-00000000000b
# ╠═a1000000-0000-4000-8000-00000000000c
# ╟─a1000000-0000-4000-8000-00000000000d
# ╠═a1000000-0000-4000-8000-00000000000e
# ╟─a1000000-0000-4000-8000-00000000000f
# ╟─a1000000-0000-4000-8000-000000000010
# ╟─a1000000-0000-4000-8000-000000000011
# ╠═a1000000-0000-4000-8000-000000000012
