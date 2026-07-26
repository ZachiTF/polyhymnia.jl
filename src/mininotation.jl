# Mini-notation: the terse string syntax borrowed from TidalCycles / Strudel.
#
#   "bd sd"          two events, half a cycle each
#   "bd [sd sd]"     nested subdivision
#   "<a b>"          alternate, one per cycle
#   "bd*2"           twice as fast          "bd/2"   half speed
#   "bd!3"           repeat three times     "bd@3"   take three steps' worth
#   "bd _ _"         elongate across steps  "~"      rest
#   "bd?"            drop ~half the time
#   "bd(3,8)"        euclidean rhythm       "bd(3,8,2)" rotated
#   "bd, hh*4"       layer two sequences

struct MiniError <: Exception
    msg::String
    input::String
    pos::Int
end

function Base.showerror(io::IO, e::MiniError)
    print(
        io,
        "invalid mini-notation: ",
        e.msg,
        "\n  ",
        e.input,
        "\n  ",
        ' '^max(e.pos - 1, 0),
        "^",
    )
end

mutable struct MiniParser
    s::String
    i::Int
end

peekc(p::MiniParser) = p.i <= lastindex(p.s) ? p.s[p.i] : '\0'
done(p::MiniParser) = p.i > lastindex(p.s)

function skipws!(p::MiniParser)
    while !done(p) && isspace(peekc(p))
        p.i = nextind(p.s, p.i)
    end
end

advance!(p::MiniParser) = (p.i = nextind(p.s, p.i))

fail(p::MiniParser, msg) = throw(MiniError(msg, p.s, p.i))

const ATOM_CHARS = Set{Char}(['-', '.', '#', '\''])
is_atom_char(c::Char) = isletter(c) || isdigit(c) || c in ATOM_CHARS || c == ':'

"""
Parse a bare word or number into a Julia value.
"""
function atom_value(tok::AbstractString)
    v = tryparse(Int, tok)
    v !== nothing && return v
    f = tryparse(Float64, tok)
    f !== nothing && return f
    String(tok)
end

# A step carries its own weight (`@`) so the enclosing sequence can lay it out.
struct Step
    pat::Pattern
    weight::Time
end

"""
    mini(str) -> Pattern

Parse a mini-notation string into a `Pattern`.
"""
function mini(str::AbstractString)
    p = MiniParser(String(str), firstindex(String(str)))
    pat = parse_stack!(p, '\0')
    skipws!(p)
    done(p) || fail(p, "unexpected '$(peekc(p))'")
    pat
end

"""
Parse comma-separated sequences, layered with `stack`.
"""
function parse_stack!(p::MiniParser, closing::Char)
    layers = Pattern[]
    while true
        push!(layers, parse_sequence!(p, closing))
        skipws!(p)
        if peekc(p) == ','
            advance!(p)
        else
            break
        end
    end
    length(layers) == 1 ? layers[1] : stack(layers)
end

"""
Parse a space-separated run of steps into one cycle.
"""
function parse_sequence!(p::MiniParser, closing::Char)
    steps = Step[]
    while true
        skipws!(p)
        (done(p) || peekc(p) == closing || peekc(p) == ',') && break
        c = peekc(p)
        (c == ']' || c == '>' || c == ')') && break
        if c == '_'
            # Elongation: stretch the previous step over another slot.
            advance!(p)
            isempty(steps) && fail(p, "'_' must follow a step")
            steps[end] = Step(steps[end].pat, steps[end].weight + 1)
            continue
        end
        append!(steps, parse_step!(p))
    end
    isempty(steps) && return silence
    if all(s -> s.weight == 1, steps)
        return fastcat([s.pat for s in steps])
    end
    timecat([(s.weight, s.pat) for s in steps])
end

"""
Parse one atom plus its trailing modifiers. May expand to several steps via `!`.
"""
function parse_step!(p::MiniParser)
    pat = parse_atom!(p)
    weight = Time(1)
    reps = 1

    while !done(p)
        c = peekc(p)
        if c == '*'
            advance!(p)
            pat = fast(parse_factor!(p), pat)
        elseif c == '/'
            advance!(p)
            pat = slow(parse_factor!(p), pat)
        elseif c == '@'
            advance!(p)
            weight = parse_factor!(p)
        elseif c == '!'
            advance!(p)
            reps = Int(parse_factor!(p))
        elseif c == '?'
            advance!(p)
            amt = 0.5
            if !done(p) && (isdigit(peekc(p)) || peekc(p) == '.')
                amt = Float64(parse_factor!(p))
            end
            pat = degrade_by(amt, pat)
        elseif c == '('
            advance!(p)
            pat = parse_euclid!(p, pat)
        else
            break
        end
    end

    reps <= 1 ? [Step(pat, weight)] : [Step(pat, weight) for _ in 1:reps]
end

"""
Parse a numeric modifier argument, e.g. the `3` in `bd*3` or `2.5` in `bd/2.5`.
"""
function parse_factor!(p::MiniParser)
    start = p.i
    while !done(p) && (isdigit(peekc(p)) || peekc(p) == '.')
        advance!(p)
    end
    start == p.i && fail(p, "expected a number")
    tok = p.s[start:prevind(p.s, p.i)]
    v = tryparse(Int, tok)
    v !== nothing && return Time(v)
    f = tryparse(Float64, tok)
    f === nothing && fail(p, "bad number '$tok'")
    rationalize(Int, f; tol = 1e-6)
end

"""
Parse `(k,n)` or `(k,n,rotation)` after an atom.
"""
function parse_euclid!(p::MiniParser, pat::Pattern)
    args = Int[]
    while true
        skipws!(p)
        neg = false
        if peekc(p) == '-'
            neg = true
            advance!(p)
        end
        v = Int(parse_factor!(p))
        push!(args, neg ? -v : v)
        skipws!(p)
        if peekc(p) == ','
            advance!(p)
        elseif peekc(p) == ')'
            advance!(p)
            break
        else
            fail(p, "expected ',' or ')' in euclid")
        end
    end
    length(args) in (2, 3) || fail(p, "euclid takes 2 or 3 arguments")
    rot = length(args) == 3 ? args[3] : 0
    euclid(args[1], args[2], pat; rotation = rot)
end

"""
Parse a single atom: a rest, a group, an alternation, or a word/number.
"""
function parse_atom!(p::MiniParser)
    skipws!(p)
    done(p) && fail(p, "unexpected end of input")
    c = peekc(p)

    if c == '~'
        advance!(p)
        return silence
    elseif c == '['
        advance!(p)
        inner = parse_stack!(p, ']')
        skipws!(p)
        peekc(p) == ']' || fail(p, "missing ']'")
        advance!(p)
        return inner
    elseif c == '<'
        advance!(p)
        # Angle brackets alternate: one step of the sequence per cycle.
        steps = Step[]
        while true
            skipws!(p)
            (done(p) || peekc(p) == '>') && break
            append!(steps, parse_step!(p))
        end
        peekc(p) == '>' || fail(p, "missing '>'")
        advance!(p)
        isempty(steps) && return silence
        return slowcat([s.pat for s in steps])
    elseif is_atom_char(c)
        start = p.i
        while !done(p) && is_atom_char(peekc(p))
            advance!(p)
        end
        return pure(atom_value(p.s[start:prevind(p.s, p.i)]))
    end
    fail(p, "unexpected '$c'")
end
