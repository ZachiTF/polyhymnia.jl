# Core pattern algebra.
#
# A Pattern is a *function of time*, not a list of notes: querying one over a
# timespan returns the events active during that span. That is what makes
# patterns infinite, composable, and cheap to hot-swap mid-playback.
#
# The idea is TidalCycles', popularised in the browser by Strudel, and this
# implementation deliberately matches the *vocabulary a musician types* — `fast`,
# `slow`, `rev`, `every`, `euclid`, the mini-notation — so that patterns are
# portable between the systems. Everything below the surface is written for
# Julia and does not follow either project's internals. See README.md.

const Time = Rational{Int}

"""
A half-open timespan `[b, e)` measured in cycles.
"""
struct Span
    b::Time
    e::Time
end

Span(b::Real, e::Real) = Span(Time(b), Time(e))

cycle_start(t::Time) = Time(floor(Int, t))
cycle_stop(t::Time) = cycle_start(t) + 1
cycle_phase(t::Time) = t - cycle_start(t)

duration(s::Span) = s.e - s.b

map_span(f, s::Span) = Span(f(s.b), f(s.e))

"""
Split a span at cycle boundaries, so each piece lies within one cycle.
"""
function split_cycles(s::Span)
    out = Span[]
    s.b > s.e && return out
    s.b == s.e && return [s]          # zero-width query still probes a point
    b = s.b
    while b < s.e
        e = min(cycle_stop(b), s.e)
        push!(out, Span(b, e))
        b = e
    end
    out
end

"""
Intersection of two spans, or `nothing` when they do not genuinely overlap.
"""
function overlap(a::Span, b::Span)
    bb, ee = max(a.b, b.b), min(a.e, b.e)
    bb > ee && return nothing
    if bb == ee
        # A zero-width intersection only counts when it comes from a
        # zero-width span, not from two spans merely touching end-to-start.
        (duration(a) > 0 && bb == a.e) && return nothing
        (duration(b) > 0 && bb == b.e) && return nothing
    end
    Span(bb, ee)
end

"""
One sounding thing.

`extent` is the note's full length — `nothing` for a continuous signal, which has
no boundaries of its own. `span` is the slice of that extent the current query
actually asked for, so a note straddling a query boundary comes back in pieces
that share one `extent`. An event with `span.b == extent.b` is the piece that
carries the note's attack; see [`has_onset`](@ref).
"""
struct Event{T}
    extent::Union{Span,Nothing}
    span::Span
    value::T
end

"""Whether this event carries the note's start, rather than a later fragment."""
has_onset(e::Event) = e.extent !== nothing && e.extent.b == e.span.b

extent_or_span(e::Event) = e.extent === nothing ? e.span : e.extent

map_event_spans(f, e::Event) =
    Event(e.extent === nothing ? nothing : f(e.extent), f(e.span), e.value)
map_event_value(f, e::Event) = Event(e.extent, e.span, f(e.value))

"""
A pattern is a query function `Span -> Vector{Event}`.
"""
struct Pattern
    query::Function
end

(p::Pattern)(span::Span) = p.query(span)
query(p::Pattern, b::Real, e::Real) = p.query(Span(Time(b), Time(e)))

"""
Query one whole cycle `n`, keeping only events that begin in it.
"""
function query_cycle(p::Pattern, n::Integer)
    events = p.query(Span(Time(n), Time(n + 1)))
    filter(has_onset, events)
end

# ---------------------------------------------------------------- primitives

const silence = Pattern(_ -> Event[])

"""
`pure(v)` repeats `v` once per cycle.
"""
function pure(v)
    Pattern(
        function (span)
            [
                Event(Span(cycle_start(s.b), cycle_stop(s.b)), s, v) for
                s in split_cycles(span)
            ]
        end,
    )
end

"""
A continuous signal sampled at the midpoint of each query span.
"""
function signal(f)
    Pattern(span -> [Event(nothing, span, f((span.b + span.e) / 2))])
end

# ------------------------------------------------------------ time transforms

map_query_time(f, p::Pattern) = Pattern(span -> p.query(map_span(f, span)))

map_event_time(f, p::Pattern) =
    Pattern(span -> [map_event_spans(s -> map_span(f, s), ev) for ev in p.query(span)])

function fast(r, p::Pattern)
    r = Time(r)
    r == 0 && return silence
    r < 0 && return rev(fast(-r, p))
    map_event_time(t -> t / r, map_query_time(t -> t * r, p))
end

slow(r, p::Pattern) = (r = Time(r); r == 0 ? silence : fast(1 // r, p))

"""
Shift earlier (`rotl`) or later (`rotr`) in time.
"""
rotl(t, p::Pattern) =
    (t = Time(t); map_event_time(x -> x - t, map_query_time(x -> x + t, p)))
rotr(t, p::Pattern) = rotl(-Time(t), p)

"""
Reverse each cycle in place.
"""
function rev(p::Pattern)
    Pattern(function (span)
        out = Event[]
        for cyc in split_cycles(span)
            c = cycle_start(cyc.b)
            nc = c + 1
            reflect(s) = Span(c + (nc - s.e), c + (nc - s.b))
            for ev in p.query(reflect(cyc))
                push!(out, map_event_spans(reflect, ev))
            end
        end
        out
    end)
end

# ------------------------------------------------------------- concatenation

"""
Layer patterns simultaneously.
"""
function stack(ps::Vector{Pattern})
    isempty(ps) && return silence
    Pattern(span -> reduce(vcat, (p.query(span) for p in ps); init = Event[]))
end
stack(ps::Pattern...) = stack(collect(Pattern, ps))

"""
One pattern per cycle, in turn.
"""
function slowcat(ps::Vector{Pattern})
    isempty(ps) && return silence
    n = length(ps)
    Pattern(function (span)
        out = Event[]
        for cyc in split_cycles(span)
            c = floor(Int, cyc.b)
            p = ps[mod(c, n) + 1]
            # Shift so each pattern advances one of *its* cycles per visit.
            offset = c - fld(c, n)
            for ev in p.query(map_span(t -> t - offset, cyc))
                push!(out, map_event_spans(s -> map_span(t -> t + offset, s), ev))
            end
        end
        out
    end)
end
slowcat(ps::Pattern...) = slowcat(collect(Pattern, ps))

"""
All patterns squeezed into a single cycle.
"""
fastcat(ps::Vector{Pattern}) = isempty(ps) ? silence : fast(length(ps), slowcat(ps))
fastcat(ps::Pattern...) = fastcat(collect(Pattern, ps))

"""
Concatenate with relative widths, e.g. `timecat([(3, a), (1, b)])`.
"""
function timecat(pairs::Vector{<:Tuple{<:Real,Pattern}})
    isempty(pairs) && return silence
    total = sum(Time(w) for (w, _) in pairs)
    total == 0 && return silence
    out = Pattern[]
    acc = Time(0)
    for (w, p) in pairs
        w = Time(w)
        push!(out, compress(acc / total, (acc + w) / total, p))
        acc += w
    end
    stack(out)
end

"""
Squeeze a pattern into the window `[b, e)` of each cycle.
"""
function compress(b, e, p::Pattern)
    b, e = Time(b), Time(e)
    (b > e || e > 1 || b < 0 || b == e) && return silence
    rotr(b, _squeeze(1 // (e - b), p))
end

"""
Play `p` at `r` times speed but only once, leaving the rest of the cycle silent.

Unlike `fast`, which repeats to fill the cycle, this crams one pass of `p` into
the leading `1/r` of each cycle. It is the primitive `compress` is built from.
"""
function _squeeze(r, p::Pattern)
    r = Time(r)
    r <= 0 && return silence
    r = max(r, Time(1))

    # Two affine maps between cycle-local coordinates: `into` scales a time in
    # this cycle up into the sped-up pattern's frame, `back` undoes it.
    into(c, t) = min(c + 1, c + (t - c) * r)
    back(c, t) = c + (t - c) / r

    Pattern() do span
        out = Event[]
        for cyc in split_cycles(span)
            c = cycle_start(cyc.b)
            asked = Span(into(c, cyc.b), into(c, cyc.e))
            # The query landed entirely in the silent tail of the cycle.
            asked.b == asked.e == c + 1 && continue

            for e in p.query(asked)
                extent =
                    e.extent === nothing ? nothing :
                    Span(back(c, e.extent.b), back(c, e.extent.e))
                # Clip to the cycle: scaling back can push the tail past it.
                lo, hi = back(c, e.span.b), min(back(c, e.span.e), cyc.e)
                lo > hi && continue
                push!(out, Event(extent, Span(lo, hi), e.value))
            end
        end
        out
    end
end

# ------------------------------------------------------------------ functors

map_values(f, p::Pattern) =
    Pattern(span -> [map_event_value(f, ev) for ev in p.query(span)])
filter_events(f, p::Pattern) = Pattern(span -> filter(f, p.query(span)))
filter_values(f, p::Pattern) = filter_events(ev -> f(ev.value), p)

"""
Combine two patterns value-wise with `op`.

`timing` decides which side dictates the rhythm — that is, how many events come
out and where they start:

  - `:left` keeps the left pattern's events and samples the right for values,
    so `m"bd sd" |> gain("0.2 0.9 0.4")` still plays exactly two notes.
  - `:right` is the mirror image.
  - `:both` emits an event wherever the two genuinely overlap, so the result can
    be busier than either input. Arithmetic on patterns uses this.
"""
function combine(op, left::Pattern, right::Pattern; timing::Symbol = :left)
    timing === :right && return combine((a, b) -> op(b, a), right, left; timing = :left)
    both = timing === :both

    function merged(a::Event, b::Event)
        span = overlap(a.span, b.span)
        span === nothing && return nothing
        # With :left the note keeps its own extent, so a control pattern can
        # never lengthen or shorten it; with :both the extent is the overlap,
        # and an open-ended signal on either side leaves it open.
        extent = if !both
            a.extent
        elseif a.extent === nothing || b.extent === nothing
            nothing
        else
            overlap(a.extent, b.extent)
        end
        Event(extent, span, op(a.value, b.value))
    end

    Pattern() do span
        out = Event[]
        for a in left.query(span), b in right.query(extent_or_span(a))
            e = merged(a, b)
            e === nothing || push!(out, e)
        end
        out
    end
end

# --------------------------------------------------------------- conditionals

"""
Apply `f` to every `n`th cycle (counting from cycle 0).
"""
function every(n::Integer, f, p::Pattern)
    n <= 0 && return p
    when_cycle(c -> mod(c, n) == 0, f, p)
end

"""
Apply `f` on cycles where `test(cyclenumber)` holds.
"""
function when_cycle(test, f, p::Pattern)
    Pattern(function (span)
        out = Event[]
        for cyc in split_cycles(span)
            c = floor(Int, cyc.b)
            src = test(c) ? f(p) : p
            append!(out, src.query(cyc))
        end
        out
    end)
end

"""
Play only the part of each cycle within `[b, e)`, keeping original timing.
"""
function zoom(b, e, p::Pattern)
    b, e = Time(b), Time(e)
    d = e - b
    d <= 0 && return silence
    map_event_time(t -> (t - b) / d, map_query_time(t -> t * d + b, p))
end

# --------------------------------------------------------------- randomness

# A cheap, deterministic hash-based noise source: the same cycle always yields
# the same value, so a pattern sounds identical on every replay.
function _time_rand(t::Time)
    x = Float64(t) * 12.9898
    v = sin(x) * 43758.5453
    v - floor(v)
end

const rand_sig = signal(_time_rand)

"""
Randomly drop events with probability `amount`.
"""
function degrade_by(amount::Real, p::Pattern; seed::Real = 0)
    Pattern(function (span)
        out = Event[]
        for ev in p.query(span)
            r = _time_rand(extent_or_span(ev).b + Time(seed))
            r >= amount && push!(out, ev)
        end
        out
    end)
end

degrade(p::Pattern) = degrade_by(0.5, p)

# ------------------------------------------------------------------- euclid

"""
Bjorklund's algorithm: distribute `k` onsets as evenly as possible over `n`.
"""
function bjorklund(k::Integer, n::Integer)
    (n <= 0 || k <= 0) && return fill(false, max(n, 0))
    k >= n && return fill(true, n)
    a = [[true] for _ in 1:k]
    b = [[false] for _ in 1:(n - k)]
    while length(b) > 1
        m = min(length(a), length(b))
        newa = [vcat(a[i], b[i]) for i in 1:m]
        if length(a) > m
            newb = a[(m + 1):end]
        else
            newb = b[(m + 1):end]
        end
        a, b = newa, newb
        isempty(b) && break
    end
    reduce(vcat, vcat(a, b))
end

"""
Euclidean rhythm: `euclid(3, 8, p)` plays `p` on a 3-in-8 pulse.
"""
function euclid(k::Integer, n::Integer, p::Pattern; rotation::Integer = 0)
    n <= 0 && return silence
    bits = bjorklund(abs(k), n)
    k < 0 && (bits = .!bits)
    rotation != 0 && (bits = circshift(bits, -rotation))
    fastcat([b ? p : silence for b in bits])
end
