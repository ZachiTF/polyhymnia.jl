# Voice rendering. Euterpe supplies the oscillators; envelopes, filters and the
# drum synthesis are ours, because Euterpe's versions are not usable here:
# its ADSR is expressed as fractions of a note that must sum to 1, and its
# `lowpass`/`highpass` read from the *input* history rather than the output
# (`sound[i-1]`, not `filtered[i-1]`), making them 2-tap FIRs rather than filters.

using Euterpe: sine, square, sawtooth, note_to_freq

const SAMPLERATE = 44100

# ------------------------------------------------------------------- pitch

const NOTE_SEMITONE =
    Dict('c' => 0, 'd' => 2, 'e' => 4, 'f' => 5, 'g' => 7, 'a' => 9, 'b' => 11)

# Euterpe's table is keyed by flat names ("Db"), so sharps are normalised onto it.
const SHARP_TO_FLAT = Dict(
    "C#" => "Db",
    "D#" => "Eb",
    "F#" => "Gb",
    "G#" => "Ab",
    "A#" => "Bb",
    "E#" => "F",
    "B#" => "C",
)

"""
    to_freq(x) -> Float64

Accept a frequency, a MIDI note number, or a note name (`"c4"`, `"F#3"`, `"eb2"`).
Numbers below 128 are read as MIDI notes (60 is middle C, 69 is A440); anything
larger is already a frequency in Hz.
"""
to_freq(x::Real) = x >= 128 ? Float64(x) : 440.0 * 2.0^((Float64(x) - 69) / 12)

function to_freq(str::AbstractString)
    isempty(str) && return 0.0
    m = match(r"^([a-gA-G])([#sb]*)(-?\d+)?$", strip(str))
    m === nothing && return 0.0
    letter = uppercase(m.captures[1])
    accs = something(m.captures[2], "")
    octave = m.captures[3] === nothing ? 4 : parse(Int, m.captures[3])

    # Fold accidentals into a single sharp/flat where Euterpe's table can take it.
    semis = sum(c == 'b' ? -1 : 1 for c in accs; init = 0)
    name = letter
    if semis == 1
        name = get(SHARP_TO_FLAT, letter * "#", letter * "#")
    elseif semis == -1
        name = letter * "b"
        name == "Cb" && (name = "B"; octave -= 1)
        name == "Fb" && (name = "E")
    elseif semis != 0
        # Unusual double accidentals: compute directly rather than via the table.
        base = NOTE_SEMITONE[lowercase(letter)[1]] + semis
        return 261.625565 * 2.0^((base + 12 * (octave - 4)) / 12)
    end
    haskey(Euterpe.freq, name) || return 0.0
    Float64(note_to_freq(name, octave))
end

to_freq(::Nothing) = 0.0

# ---------------------------------------------------------------- envelope

"""
Linear ADSR in seconds, rendered over `n` samples at `sr`.
"""
function adsr_envelope(
    n::Int,
    sr::Int;
    attack = 0.01,
    decay = 0.1,
    sustain = 0.7,
    release = 0.1,
)
    env = Vector{Float64}(undef, n)
    a = max(round(Int, attack * sr), 1)
    d = max(round(Int, decay * sr), 1)
    r = max(round(Int, release * sr), 1)
    rel_start = max(n - r, 1)
    @inbounds for i in 1:n
        v = if i <= a
            i / a
        elseif i <= a + d
            1.0 - (1.0 - sustain) * (i - a) / d
        else
            sustain
        end
        if i > rel_start
            v *= max(0.0, 1.0 - (i - rel_start) / r)
        end
        env[i] = v
    end
    env
end

# ------------------------------------------------------------------ filters

"""
One-pole lowpass. Unlike Euterpe's, this is recursive, so it actually rolls off.
"""
function lowpass!(x::Vector{Float64}, cutoff::Real, sr::Int)
    cutoff <= 0 && return x
    cutoff >= sr / 2 && return x
    a = 1 - exp(-2π * cutoff / sr)
    y = 0.0
    @inbounds for i in eachindex(x)
        y += a * (x[i] - y)
        x[i] = y
    end
    x
end

"""
One-pole highpass, as the complement of the lowpass above.
"""
function highpass!(x::Vector{Float64}, cutoff::Real, sr::Int)
    cutoff <= 0 && return x
    a = 1 - exp(-2π * cutoff / sr)
    y = 0.0
    @inbounds for i in eachindex(x)
        y += a * (x[i] - y)
        x[i] -= y
    end
    x
end

"""
Soft saturation; `amount` of 0 leaves the signal untouched.
"""
function saturate!(x::Vector{Float64}, amount::Real)
    amount <= 0 && return x
    k = 1 + 20 * amount
    @inbounds for i in eachindex(x)
        x[i] = tanh(k * x[i]) / tanh(k)
    end
    x
end

# -------------------------------------------------------------- oscillators

const NOISE_RNG = Ref(MersenneTwister(0x5eed))

"""
Render `dur` seconds of a named waveform, delegating to Euterpe where it has one.
"""
function oscillator(name::AbstractString, freq::Real, dur::Real, sr::Int)
    n = max(round(Int, dur * sr), 1)
    freq <= 0 && return zeros(Float64, n)
    buf = if name == "sine" || name == "sin"
        sine(freq, dur, sr)
    elseif name == "square" || name == "sqr"
        square(freq, dur, sr)
    elseif name == "saw" || name == "sawtooth"
        sawtooth(freq, dur, sr)
    elseif name == "tri" || name == "triangle"
        t = (1:n) ./ sr
        @. 2 * abs(2 * (t * freq - floor(t * freq + 0.5))) - 1
    elseif name == "noise" || name == "white"
        rand(NOISE_RNG[], n) .* 2 .- 1
    else
        sine(freq, dur, sr)
    end
    buf = collect(Float64, buf)
    # Euterpe sizes its buffers from `1:dur*sr`, which can be off by one.
    length(buf) == n ? buf :
    (length(buf) > n ? buf[1:n] : vcat(buf, zeros(Float64, n - length(buf))))
end

# ------------------------------------------------------------ drum synthesis

# Strudel's "bd sd hh" are samples; being a synthesiser, we approximate them so
# the familiar mini-notation still sounds like a drum kit.
const DRUMS = Set(["bd", "sd", "sn", "hh", "oh", "cp", "rim", "lt", "mt", "ht"])

is_drum(name::AbstractString) = name in DRUMS

function render_drum(name::AbstractString, dur::Real, sr::Int)
    n = max(round(Int, dur * sr), 1)
    t = (0:(n - 1)) ./ sr
    rng = NOISE_RNG[]

    if name == "bd"
        f = @. 55 + 110 * exp(-t * 45)          # pitch drop gives the thump
        ph = cumsum(2π .* f ./ sr)
        return @. sin(ph) * exp(-t * 9)
    elseif name == "sd" || name == "sn"
        noise = (rand(rng, n) .* 2 .- 1) .* exp.(-t .* 22)
        highpass!(noise, 1200, sr)
        tone = @. sin(2π * 190 * t) * exp(-t * 30) * 0.6
        return noise .+ tone
    elseif name == "hh"
        noise = (rand(rng, n) .* 2 .- 1) .* exp.(-t .* 90)
        return highpass!(noise, 7000, sr)
    elseif name == "oh"
        noise = (rand(rng, n) .* 2 .- 1) .* exp.(-t .* 11)
        return highpass!(noise, 6000, sr)
    elseif name == "cp"
        noise = (rand(rng, n) .* 2 .- 1) .* exp.(-t .* 30)
        bandpass = highpass!(lowpass!(noise, 2500, sr), 900, sr)
        return bandpass
    elseif name == "rim"
        return @. sin(2π * 1700 * t) * exp(-t * 150) * 0.8
    else  # toms: lt / mt / ht
        base = name == "lt" ? 100.0 : name == "mt" ? 150.0 : 220.0
        f = @. base + base * 0.6 * exp(-t * 30)
        ph = cumsum(2π .* f ./ sr)
        return @. sin(ph) * exp(-t * 14)
    end
end

# ----------------------------------------------------------- voice assembly

"""
    render_voice(ctl, dur, sr) -> Vector{Float64}

Turn one event's control bag into mono samples. `dur` is the event's length in
seconds; the returned buffer may be shorter (percussion) or longer (release tail).
"""
function render_voice(ctl::Controls, dur::Real, sr::Int = SAMPLERATE)
    dur = max(Float64(dur), 1 / sr)
    name = string(get(ctl, :s, "sine"))
    # "bd:3"-style suffixes select a sample in Strudel; we only need the name.
    name = split(name, ':')[1]

    gain = Float64(get(ctl, :gain, 0.8))
    legato = Float64(get(ctl, :legato, 1.0))
    sounding = dur * legato

    buf = if is_drum(name)
        render_drum(name, min(sounding * 2, max(sounding, 0.35)), sr)
    else
        freq = if haskey(ctl, :note)
            to_freq(ctl[:note])
        elseif haskey(ctl, :n)
            to_freq(ctl[:n])
        else
            to_freq("c4")
        end
        freq <= 0 && return Float64[]

        speed = Float64(get(ctl, :speed, 1.0))
        rel = Float64(get(ctl, :release, 0.1))
        total = sounding + rel
        osc = oscillator(name, freq * speed, total, sr)
        env = adsr_envelope(
            length(osc),
            sr;
            attack = Float64(get(ctl, :attack, 0.01)),
            decay = Float64(get(ctl, :decay, 0.1)),
            sustain = Float64(get(ctl, :sustain, 0.7)),
            release = rel,
        )
        osc .* env
    end

    isempty(buf) && return buf
    haskey(ctl, :cutoff) && lowpass!(buf, Float64(ctl[:cutoff]), sr)
    haskey(ctl, :hcutoff) && highpass!(buf, Float64(ctl[:hcutoff]), sr)
    haskey(ctl, :shape) && saturate!(buf, Float64(ctl[:shape]))
    buf .*= gain
    buf
end

"""
Equal-power pan; `p` runs 0 (left) to 1 (right).
"""
function pan_gains(p::Real)
    p = clamp(Float64(p), 0.0, 1.0)
    θ = p * π / 2
    (cos(θ), sin(θ))
end
