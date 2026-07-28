"""
    Polyhymnia

Live-codeable music for Pluto notebooks: a cycle-based pattern language in the
spirit of TidalCycles and Strudel, rendered by a synthesiser built on Euterpe.jl.

Patterns are functions of time rather than lists of notes, so they are infinite,
composable, and cheap to swap while sound is playing — which is what lets a
Pluto cell edit the music without stopping it.

```julia
using Polyhymnia

engine = live(cps = 0.5)
engine(\"bd*2 [~ sd] hh*4\" |> gain(0.9))
```
"""
module Polyhymnia

using Random: MersenneTwister
import Euterpe
import PortAudio

# Order matters: each layer builds on the one above.
include("pattern.jl")        # the pattern algebra
include("mininotation.jl")   # "bd sd [hh hh]" -> Pattern
include("controls.jl")       # named synth parameters
include("voices.jl")         # Pattern values -> samples (via Euterpe)
include("engine.jl")         # cycles -> stereo buffers
include("sinks.jl")          # buffers -> speakers or browser
include("pluto.jl")          # the notebook front end

# pattern algebra
export Pattern, Span, Time
export silence, pure, signal, slowcat, fastcat, timecat, overlay, seq, slowseq
export fast, slow, rev, rotl, rotr, every, when_cycle, zoom, compress
export degrade, degrade_by, euclid, bjorklund, map_values, filter_values
export query, query_cycle, has_onset, limit!
# Two names are deliberately *not* exported, because Base exports them too and
# an ambiguous name errors at the point of use:
#
#   `stack`  — `overlay` is the same operation; use that, or `Polyhymnia.stack`.
#   `Event`  — you rarely need to name the type: `query_cycle` hands you events
#              and field access (`ev.value`, `ev.extent`) needs no import. To
#              annotate one, write `Polyhymnia.Event`.

# mini-notation
export mini, @m_str

# controls
export Control, CurriedControl, Controls, to_pattern
export controls_of, event_label, onset_events
export sound, s, note, n, gain, pan, attack, decay, sustain, release
export cutoff, hcutoff, shape, speed, legato, range_
export sine_lfo, cosine_lfo, saw_lfo, isaw_lfo, tri_lfo, square_lfo, rand_lfo

# synthesis
export to_freq, render_voice, voice_stages, voice_freq, sound_name, oscillator
export SAMPLERATE

# engine and sinks
export Engine, set_pattern!, set_cps!, set_bpm!, is_playing, render_cycles, render_stems
export AudioSink, PortAudioSink, WebAudioSink, default_sink, describe
export start!, stop!, refresh!, ensure_alsa_config!, device_count

# notebook front end
export live, play!, hush, wav, wav_bytes, webaudio, pattern_plot, transport
export signal_chain, scope, peaks

"""
    m"bd sd [hh hh]"

Mini-notation string literal — equivalent to `mini("bd sd [hh hh]")`.
"""
macro m_str(str)
    :(mini($str))
end

end # module
