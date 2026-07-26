# Control patterns. An event's value is a bag of named parameters (`:s`, `:note`,
# `:gain`, ...) that the synth reads; controls compose by merging those bags,
# with the *timing* taken from the left-hand pattern, so applying a control can
# never change how many notes play.
#
# The parameter names are Tidal's on purpose — see "Prior art" in README.md.

const Controls = Dict{Symbol,Any}

"""
    to_pattern(x) -> Pattern

Coerce the usual suspects into patterns: strings go through mini-notation,
numbers become `pure`, vectors become a one-cycle sequence.
"""
to_pattern(p::Pattern) = p
to_pattern(str::AbstractString) = mini(str)
to_pattern(x::Number) = pure(x)
to_pattern(v::AbstractVector) = fastcat([to_pattern(x) for x in v])
to_pattern(x) = pure(x)

"""
Merge two control bags, with the right-hand side winning on conflict.
"""
merge_controls(a::Controls, b::Controls) = merge(a, b)
merge_controls(::Any, b::Controls) = b
merge_controls(a::Controls, ::Any) = a
merge_controls(::Any, b) = b

"""
Wrap a bare value into a single-key control bag.
"""
as_controls(name::Symbol, v) = v isa Controls ? v : Controls(name => v)

"""
Promote a pattern of bare values into control bags, so that applying a control
adds to the event rather than replacing it. Bare mini-notation words name a
*sound* — `m"bd"` means `sound("bd")` — so that is the key they take.
Use `note("c3 e3")` when you mean pitch.
"""
ensure_controls(p::Pattern) = map_values(v -> v isa Controls ? v : as_controls(:s, v), p)

"""
A control that has been given its value but not yet a pattern to apply it to.
It doubles as a `Pattern` (so `gain(0.8)` can stand alone) and as a function
(so `pat |> gain(0.8)` works through Julia's ordinary `|>`).
"""
struct CurriedControl
    pat::Pattern
    name::Symbol
end

(c::CurriedControl)(p::Pattern) =
    combine(merge_controls, ensure_controls(p), c.pat; timing = :left)
(c::CurriedControl)(c2::CurriedControl) = c(c2.pat)
to_pattern(c::CurriedControl) = c.pat

"""
A named synth parameter, e.g. `gain` or `cutoff`.
"""
struct Control
    name::Symbol
end

(c::Control)(x) =
    CurriedControl(map_values(v -> as_controls(c.name, v), to_pattern(x)), c.name)
(c::Control)(x, p) = c(x)(to_pattern(p))

# The parameters the synth understands. The short names are the ones Tidal and
# Strudel users already know, kept for portability; the longer aliases exist
# because `s` and `n` collide easily with notebook variables.
const sound = Control(:s)
const s = sound
const note = Control(:note)
const n = Control(:n)
const gain = Control(:gain)
const pan = Control(:pan)
const attack = Control(:attack)
const decay = Control(:decay)
const sustain = Control(:sustain)
const release = Control(:release)
const cutoff = Control(:cutoff)
const hcutoff = Control(:hcutoff)
const shape = Control(:shape)
const speed = Control(:speed)
const legato = Control(:legato)

# ------------------------------------------------------------- combinators

"""
Layer patterns on top of one another.
"""
overlay(ps...) = stack([to_pattern(p) for p in ps])

"""
Play one pattern per cycle, in turn.
"""
slowseq(ps...) = slowcat([to_pattern(p) for p in ps])

"""
Fit all the patterns into a single cycle.
"""
seq(ps...) = fastcat([to_pattern(p) for p in ps])

# ------------------------------------------------------------------ signals

# Continuous LFOs, all in `[0, 1]` with one period per cycle. Useful as control
# inputs: `pan(sine_lfo)`, `cutoff(saw_lfo * 2000 + 200)`.
const sine_lfo = signal(t -> (sin(2π * Float64(t)) + 1) / 2)
const cosine_lfo = signal(t -> (cos(2π * Float64(t)) + 1) / 2)
const saw_lfo = signal(t -> Float64(cycle_phase(t)))
const isaw_lfo = signal(t -> 1 - Float64(cycle_phase(t)))
const tri_lfo = signal(t -> (x = Float64(cycle_phase(t)); x < 0.5 ? 2x : 2 - 2x))
const square_lfo = signal(t -> Float64(cycle_phase(t)) < 0.5 ? 0.0 : 1.0)
const rand_lfo = rand_sig

# Arithmetic on patterns, so `saw_lfo * 2000 + 200` reads naturally.
for op in (:+, :-, :*, :/)
    @eval Base.$op(a::Pattern, b::Number) = map_values(v -> $op(v, b), a)
    @eval Base.$op(a::Number, b::Pattern) = map_values(v -> $op(a, v), b)
    @eval Base.$op(a::Pattern, b::Pattern) = combine($op, a, b; timing = :both)
end

"""
Scale a unipolar signal into `[lo, hi]`.
"""
range_(lo, hi, p::Pattern) = map_values(v -> lo + v * (hi - lo), p)
