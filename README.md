# Polyhymnia.jl

Live-codeable music in a [Pluto](https://plutojl.org) notebook, in the spirit of
[strudel.cc](https://strudel.cc) — a cycle-based pattern language rendered by a
synthesiser built on [Euterpe.jl](https://github.com/SquidSinker/Euterpe.jl).

Edit a cell, and the music updates as you go. Patterns are *functions of time*
rather than lists of notes, so a change swaps in at the next cycle boundary
instead of restarting playback.

```julia
overlay(
    m"bd*2 [~ bd] bd ~"     |> gain(1.0),
    m"~ sd ~ sd",
    m"hh*8"                 |> gain(0.3) |> pan(sine_lfo),
    note("<c2 g2 eb2 f2>")  |> sound("saw") |> cutoff(saw_lfo * 1400 + 250),
)
```

## Getting started

Requires **Julia 1.11 or newer**.

```bash
git clone <this repo> && cd polyhymnia.jl
julia -t auto --project=. run.jl
```

That instantiates the environment and opens `notebooks/polyhymnia.jl` in Pluto.
Press **play** in the player cell, then edit the pattern cell — the loop updates
underneath you.

`run.jl` takes the notebook to open, so `notebooks/` can hold as many examples
as you like:

```bash
julia -t auto --project=. run.jl scales     # opens notebooks/scales.jl
```

`-t auto` matters only for the PortAudio backend, which needs a spare thread to
render while it writes. The default WebAudio backend is unaffected.

First run takes a while: Euterpe depends on `DifferentialEquations` and
`ModelingToolkit`, which are large (see [Notes on Euterpe](#notes-on-euterpe)).

## Mini-notation

Written inside `m"..."` or `mini("...")`.

| syntax | meaning |
|:--|:--|
| `bd sd` | sequence, one cycle split evenly |
| `[bd sd] hh` | subdivide a step |
| `<bd sd>` | alternate, one per cycle |
| `bd*4` / `bd/2` | faster / slower |
| `bd!3` | repeat three times |
| `bd@3 sd` | weighted steps (3:1) |
| `bd _ _ sd` | elongate — same as `bd@3 sd` |
| `~` | rest |
| `bd?` / `bd?0.3` | randomly drop, deterministic per cycle |
| `bd(3,8)` / `bd(3,8,2)` | euclidean rhythm, optionally rotated |
| `bd, hh*4` | layer two sequences |

Nesting works as you'd expect: `<a <b c>>` yields `a b a c` over four cycles.

## Sounds and controls

**Drums** (synthesised, not sampled): `bd sd sn hh oh cp rim lt mt ht`
**Waveforms**: `sine square saw tri noise`, pitched via `note` / `n`.

**Controls**: `gain pan attack decay sustain release cutoff hcutoff shape speed
legato`. Chain with `|>`:

```julia
note("c3 e3 g3") |> sound("saw") |> cutoff(800) |> release(0.3) |> gain(0.6)
```

A bare mini-notation word names a **sound**, so `m"bd sd"` needs no wrapping but
pitches must go through `note` (or `n`). Writing `m"c3 e3" |> sound("saw")` would
set the sound twice and lose the pitch.

**LFOs** run 0→1 once per cycle and support arithmetic:
`sine_lfo cosine_lfo saw_lfo isaw_lfo tri_lfo square_lfo rand_lfo`

```julia
pan(sine_lfo)
cutoff(saw_lfo * 2000 + 200)
```

**Pattern functions**: `fast slow rev every zoom compress degrade degrade_by
euclid overlay seq slowseq timecat`

(`overlay` is the layering operation. `Polyhymnia.stack` is the same thing but is
not exported, because `Base` exports a `stack` of its own.)

```julia
every(4, rev, m"bd sd hh cp")
```

## Backends

Sound leaves Julia one of two ways, chosen when you build the engine:

| | `WebAudioSink(cycles = n)` | `PortAudioSink()` |
|:--|:--|:--|
| plays on | the browser | the machine running Julia |
| needs a sound device | no | yes |
| works over a network | yes | no |
| variation | loops every `n` cycles | endless |
| how it works | Julia renders `n` cycles, ships them as a WAV data URI, WebAudio loops the buffer and swaps it at the next loop boundary | Julia streams cycle-by-cycle to the sound card from a background task, carrying note tails across the seam |

`default_sink()` picks PortAudio when a device exists, else WebAudio.

The two differ musically: WebAudio repeats anything longer than its window, so
widen `cycles` for long-form patterns (`<a b c d>` over 4 cycles needs
`cycles = 4`). PortAudio has no such limit.

### WSL2 audio

PortAudio reports **zero devices** under WSL2 because ALSA has no config pointing
at WSLg's PulseAudio socket. `ensure_alsa_config!()` writes a minimal config and
sets `ALSA_CONFIG_PATH`, after which `pulse` and `default` appear. It runs
automatically from `default_sink()` and `start!`, and leaves `~/.asoundrc` alone
if you already have one.

## API sketch

```julia
engine = live(cps = 0.5, sink = WebAudioSink(cycles = 4))
play!(engine, m"bd*4")     # or: engine(m"bd*4")
set_bpm!(engine, 128)      # four beats to the cycle
webaudio(engine)           # the player widget
pattern_plot(pat, cycles = 4)
transport(engine)
hush(engine)

write("out.wav", wav(engine, cycles = 8))
```

Patterns are ordinary values, so they compose outside the notebook too:

```julia
query_cycle(m"bd sd", 0)              # the events of cycle 0
render_cycles(pat, 0, 4; cps = 0.5)   # an n x 2 stereo buffer
```

## Notes on Euterpe

Euterpe.jl supplies the oscillators (`sine`, `square`, `sawtooth`) and the note
table behind `to_freq`. A few things it does *not* supply, which live here
instead:

- **Envelopes.** Euterpe's `ADSR` expresses stages as fractions of a note that
  must sum to exactly 1, so envelope shape changes with note length. `voices.jl`
  uses absolute seconds instead.
- **Filters.** Euterpe's `lowpass`/`highpass` read from the input history
  (`sound[i-1]`) rather than the output, making them 2-tap FIRs rather than
  filters. `voices.jl` implements recursive one-poles that actually roll off.
- **Scheduling.** Euterpe renders a whole buffer and blocks on `play`. Everything
  in `pattern.jl`, `engine.jl` and `sinks.jl` exists to make sound continuous and
  hot-swappable.

Euterpe also declares `DifferentialEquations`, `ModelingToolkit`, `FFTW` and
`LibSndFile` as dependencies without using them, which is most of the first-run
install time. Nothing here needs them.

## Layout

```
src/
  Polyhymnia.jl     module and exports
  pattern.jl        the pattern algebra (Span, Hap, Pattern, combinators)
  mininotation.jl   "bd sd [hh hh]" parser
  controls.jl       named synth parameters, LFOs, pattern arithmetic
  voices.jl         events -> samples, via Euterpe's oscillators
  engine.jl         cycles -> stereo buffers; tempo and pattern state
  sinks.jl          PortAudio streaming and WebAudio looping
  pluto.jl          player widget, piano roll, WAV export
notebooks/
  polyhymnia.jl     the live-coding page (the default)
test/runtests.jl
run.jl              launches Pluto on a notebook
```

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Euterpe is unregistered, so it is pinned by commit in `Project.toml`'s
`[sources]` rather than by a committed `Manifest.toml` — that is what requires
Julia 1.11+. Branching, commit conventions, the pre-commit hooks, and the rules
for editing Pluto notebooks are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Prior art, and what this is not

The pattern model comes from **[TidalCycles](https://tidalcycles.org)**, which
[Strudel](https://strudel.cc) later brought to the browser: patterns as
functions from timespans to events, each event carrying both its full `extent`
and the `span` a given query asked for, so a note can come back in fragments.
`bjorklund` is Toussaint's euclidean-rhythm algorithm, from the published paper.

**Polyhymnia is not a fork or a port of Strudel, and contains no code from it or
from Tidal.** What it does deliberately share is the *vocabulary you type* —
`fast`, `slow`, `rev`, `every`, `euclid`, the control names, and the
mini-notation. That language is the point: it is what lets a pattern you learned
in one system stay readable in another, and it is Tidal's contribution to live
coding generally. Everything beneath that surface is written for Julia.

The parts with no Strudel counterpart at all are most of the project: Strudel
plays samples through WebAudio, whereas Polyhymnia synthesises every voice
(`voices.jl`), schedules them itself (`engine.jl`, `sinks.jl`), and lives in a
Pluto notebook rather than a browser editor.

If you want the original, use [strudel.cc](https://strudel.cc) — it is far more
capable, and it is the real thing.

## Licence

MIT — see [LICENSE](LICENSE). Euterpe.jl is MIT, © Avik Sengupta and
contributors. TidalCycles (GPL-3.0) and Strudel (AGPL-3.0) are copyleft; no code
from either is included here, only the pattern vocabulary described above.
