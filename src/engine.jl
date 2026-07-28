# Turning patterns into audio: query a stretch of cycles, render each event that
# begins there, and mix the results into a stereo buffer.

"""
    render_cycles(pat, from, to; cps, sr, tail, wrap) -> Matrix{Float64}

Render cycles `[from, to)` to an `n x 2` stereo buffer.

`tail` is extra seconds of room so notes ringing past the end are not clipped.
When `wrap` is true that tail is folded back onto the start of the buffer, which
is what makes a rendered chunk loop seamlessly in the browser; when false the
tail is left exposed so a streaming sink can carry it into the next block.
"""
function render_cycles(
    pat::Pattern,
    from::Real,
    to::Real;
    cps::Real = 0.5,
    sr::Int = SAMPLERATE,
    tail::Real = 2.0,
    wrap::Bool = true,
)
    cycles = Time(to) - Time(from)
    cycles <= 0 && return zeros(Float64, 0, 2)

    nmain = round(Int, Float64(cycles) / cps * sr)
    ntail = round(Int, tail * sr)
    buf = zeros(Float64, nmain + ntail, 2)

    events = pat.query(Span(Time(from), Time(to)))
    for ev in events
        has_onset(ev) || continue          # only trigger on a note's true start
        ctl = ev.value isa Controls ? ev.value : as_controls(:s, ev.value)
        ext = ev.extent::Span

        offset = round(Int, Float64(ext.b - Time(from)) / cps * sr)
        dur = Float64(duration(ext)) / cps
        (offset < 0 || dur <= 0) && continue

        voice = render_voice(ctl, dur, sr)
        isempty(voice) && continue

        l, r = pan_gains(get(ctl, :pan, 0.5))
        @inbounds for i in eachindex(voice)
            j = offset + i
            j > size(buf, 1) && break
            buf[j, 1] += voice[i] * l
            buf[j, 2] += voice[i] * r
        end
    end

    if wrap
        @inbounds for i in (nmain + 1):size(buf, 1)
            j = i - nmain
            j > nmain && break
            buf[j, 1] += buf[i, 1]
            buf[j, 2] += buf[i, 2]
        end
        return buf[1:nmain, :]
    end
    buf
end

"""
    render_stems(tracks, from, to; cps, sr, ...) -> Vector{Pair{String,Matrix}}

Render each track to its own buffer instead of mixing them. `tracks` is either a
vector of patterns or of `"name" => pattern` pairs.

The stems are scaled by a *single* factor derived from their sum, so playing
them together reproduces `render_cycles` over the overlay: limiting each stem on
its own would quietly rebalance the mix.

Voices built on noise (`hh`, `sd`, `noise`) draw from one global RNG, so they
differ between any two renders — mixed or split alike — and the sum only matches
the overlay exactly for deterministic voices.
"""
function render_stems(tracks, from::Real = 0, to::Real = 4; ceiling::Real = 0.95, kw...)
    named = _named_tracks(tracks)
    stems = [name => render_cycles(pat, from, to; kw...) for (name, pat) in named]
    isempty(stems) && return stems

    n = maximum(size(buf, 1) for (_, buf) in stems)
    mix = zeros(Float64, n, 2)
    for (_, buf) in stems
        mix[1:size(buf, 1), :] .+= buf
    end
    peak = isempty(mix) ? 0.0 : maximum(abs, mix)
    if peak > ceiling
        for (_, buf) in stems
            buf .*= ceiling / peak
        end
    end
    stems
end

_named_tracks(tracks) = [_named_track(i, t) for (i, t) in enumerate(tracks)]
_named_track(i::Int, t::Pair) = string(first(t)) => to_pattern(last(t))
_named_track(i::Int, t) = "track $i" => to_pattern(t)

"""
Scale down only if the buffer would clip, so relative dynamics survive.
"""
function limit!(buf::AbstractMatrix{Float64}; ceiling::Real = 0.95)
    isempty(buf) && return buf
    peak = maximum(abs, buf)
    peak > ceiling && (buf .*= ceiling / peak)
    buf
end

# --------------------------------------------------------------------- clock

"""
The live state a running pattern needs. The pattern and tempo sit behind `Ref`s
so a Pluto cell can swap them mid-flight without restarting audio.
"""
mutable struct Engine
    pattern::Ref{Pattern}
    cps::Ref{Float64}
    playing::Ref{Bool}
    cycle::Ref{Int}
    sink::Any
    task::Union{Task,Nothing}
end

function Engine(pat = silence; cps::Real = 0.5, sink = nothing)
    Engine(
        Ref{Pattern}(to_pattern(pat)),
        Ref(Float64(cps)),
        Ref(false),
        Ref(0),
        sink,
        nothing,
    )
end

"""
Swap in a new pattern. Takes effect at the next cycle boundary.
"""
function set_pattern!(e::Engine, pat)
    e.pattern[] = to_pattern(pat)
    e
end

"""
Change tempo in cycles per second (`cps`); `0.5` is Strudel's default.
"""
set_cps!(e::Engine, cps::Real) = (e.cps[] = Float64(cps); e)

"""
Set tempo in beats per minute, assuming four beats to the cycle.
"""
set_bpm!(e::Engine, bpm::Real; beats_per_cycle::Real = 4) =
    set_cps!(e, bpm / 60 / beats_per_cycle)

is_playing(e::Engine) = e.playing[]
