# The notebook front end.
#
# Audio reaches the browser as a base64 WAV data URI, decoded by WebAudio into an
# AudioBuffer and looped. That keeps the whole path dependency-free (Base64 is
# stdlib) and gives genuinely gapless looping, which an `<audio loop>` element
# cannot. State lives on `window._polyhymnia` so that a Pluto cell re-run swaps
# the buffer on a running context instead of stacking up a second one.

using Base64: base64encode

# ----------------------------------------------------------------- palette

"""
The one place a colour is named. Every widget below interpolates from here, so
a second front end — or a light mode — is a matter of rebinding this constant
rather than hunting hex codes through a few hundred lines of HTML, SVG and
canvas drawing.
"""
const THEME = (
    bg = "#16161e",         # a panel's own background
    inset = "#1c1c26",      # a well inside a panel: track rows, canvases
    border = "#3a3a4a",     # panel edges and the zero line of a waveform
    fg = "#c8c8d4",         # body text
    dim = "#8a8a9a",        # secondary text, and a button at rest
    faint = "#6a6a7a",      # axis numbers, units, peak readouts
    accent = "#7aa2f7",     # the blue anything active is drawn in
    on_accent = "#16161e",  # text sitting on accent, alert or warn
    warn = "#e0af68",       # solo engaged
    alert = "#f7768e",      # mute engaged
    trace = "#ffffff",      # the playhead, over inset
)

# Per-track and per-stage colours, cycled. The first is the accent, so a single
# track or a one-stage chain matches the rest of the interface rather than
# looking like an arbitrary choice.
const PALETTE =
    [THEME.accent, "#9ece6a", THEME.warn, "#bb9af7", "#7dcfff", THEME.alert, "#73daca"]

# ------------------------------------------------------------ WAV encoding

"""
    wav_bytes(buf; sr) -> Vector{UInt8}

Encode a float buffer as 16-bit PCM WAV: an `n x 2` matrix becomes stereo, a
length-`n` vector becomes mono. Mono halves the bytes, which is worth having
when a whole mix is travelling to the browser as text.
"""
function wav_bytes(buf::AbstractVecOrMat{Float64}; sr::Int = SAMPLERATE)
    n = size(buf, 1)
    nch = buf isa AbstractVector ? 1 : size(buf, 2)
    io = IOBuffer()
    datasize = n * nch * 2                   # frames x channels x 2 bytes

    write(io, "RIFF")
    write(io, UInt32(36 + datasize))
    write(io, "WAVE")
    write(io, "fmt ")
    write(io, UInt32(16))                    # PCM header size
    write(io, UInt16(1))                     # format: PCM
    write(io, UInt16(nch))                   # channels
    write(io, UInt32(sr))
    write(io, UInt32(sr * nch * 2))          # byte rate
    write(io, UInt16(nch * 2))               # block align
    write(io, UInt16(16))                    # bits per sample
    write(io, "data")
    write(io, UInt32(datasize))

    @inbounds for i in 1:n, ch in 1:nch
        v = clamp(buf isa AbstractVector ? buf[i] : buf[i, ch], -1.0, 1.0)
        write(io, Int16(round(Int, v * 32767)))
    end
    take!(io)
end

"""
    wav(x; sr) -> Vector{UInt8}

WAV bytes for a buffer, a sink, or an engine — handy for `write("out.wav", wav(e))`.
"""
wav(buf::AbstractMatrix{Float64}; sr::Int = SAMPLERATE) = wav_bytes(buf; sr = sr)
wav(sink::WebAudioSink; sr::Int = SAMPLERATE) = wav_bytes(sink.buffer; sr = sr)
function wav(e::Engine; cycles::Int = 4, sr::Int = SAMPLERATE)
    buf = render_cycles(e.pattern[], 0, cycles; cps = e.cps[], sr = sr)
    wav_bytes(limit!(buf); sr = sr)
end

data_uri(bytes::Vector{UInt8}) = "data:audio/wav;base64," * base64encode(bytes)

# ------------------------------------------------------------- global engine

const CURRENT = Ref{Union{Engine,Nothing}}(nothing)

"""
    live(; cps, bpm, sink, cycles) -> Engine

Fetch (or create) the notebook's engine. Calling it again reuses the same engine
so re-running a cell never starts a second stream.
"""
function live(;
    cps::Real = 0.5,
    bpm::Union{Real,Nothing} = nothing,
    sink = nothing,
    cycles::Int = 4,
)
    e = CURRENT[]
    if e === nothing
        e = Engine(
            silence;
            cps = cps,
            sink = sink === nothing ? default_sink(; cycles = cycles) : sink,
        )
        CURRENT[] = e
    end
    sink !== nothing && (e.sink = sink)
    bpm === nothing ? set_cps!(e, cps) : set_bpm!(e, bpm)
    e
end

"""
    play!(pat; ...) / play!(engine, pat)

Send a pattern to the engine and make sure it is running. This is the call a
Pluto cell makes on every edit: the pattern swaps at the next cycle boundary.
"""
function play!(e::Engine, pat)
    set_pattern!(e, pat)
    if e.sink isa WebAudioSink
        refresh!(e.sink, e)
        e.playing[] = true
    elseif !e.playing[]
        start!(e)
    end
    e
end

play!(pat) = play!(live(), pat)

"""
Silence everything and stop the stream.
"""
function hush(e::Engine = live())
    set_pattern!(e, silence)
    stop!(e)
    e.sink isa WebAudioSink && refresh!(e.sink, e)
    e
end

# Let an engine be called directly: `engine("bd*4")`.
(e::Engine)(pat) = play!(e, pat)

# --------------------------------------------------------------- audio glue

# The JavaScript both widgets need, in one place so the player and the scopes
# cannot disagree about who owns the audio graph. Interpolated into each
# widget's <script>; `G` is the shared state parked on `window._polyhymnia`,
# which is what lets a Pluto re-run swap buffers on a running context instead of
# stacking up a second one.
const AUDIO_GLUE = """
     const G = (window._polyhymnia = window._polyhymnia || {});
     if (!G.ctx) {
       G.ctx = new (window.AudioContext || window.webkitAudioContext)();
       G.gain = G.ctx.createGain();
       G.gain.connect(G.ctx.destination);
     }
     const ctx = G.ctx;

     // Stop whatever is sounding, whichever widget started it: one buffer from
     // `webaudio` or a list of stems from `scope`. Passing a time stops them
     // exactly when the replacement starts — stopping immediately instead would
     // leave silence from now until the boundary the new audio begins on.
     function phStop(at) {
       const kill = s => { try { at == null ? s.stop() : s.stop(at); } catch (e) {} };
       if (G.src) { kill(G.src); G.src = null; }
       (G.srcs || []).forEach(kill);
       G.srcs = [];
     }

     // The loop boundary an edit should land on, so it arrives musically rather
     // than mid-note. Falls back to "as soon as possible" when nothing plays:
     // stopping clears `startTime`, so a cold start does not wait for a phantom
     // boundary left behind by a previous run.
     function phBoundary() {
       const soon = ctx.currentTime + 0.06;
       if (G.startTime == null || !(G.dur > 0)) return soon;
       return G.startTime + Math.ceil((soon - G.startTime) / G.dur) * G.dur;
     }
"""

# ------------------------------------------------------------- browser audio

"""
    webaudio(e) -> HTML

The player widget. Re-running the cell that produced it swaps the looping buffer
at the next boundary, so edits do not interrupt playback.
"""
function webaudio(e::Engine = live(); cycles::Union{Int,Nothing} = nothing)
    sink = e.sink isa WebAudioSink ? e.sink : WebAudioSink(; cycles = something(cycles, 4))
    e.sink isa WebAudioSink || (e.sink = sink)

    # `play!` already renders, so only render here when something is actually
    # out of date — otherwise every edit would render the same audio twice.
    if cycles !== nothing && cycles != sink.cycles
        sink.cycles = cycles
        refresh!(sink, e)
    elseif isempty(sink.buffer)
        refresh!(sink, e)
    end

    uri = data_uri(wav_bytes(sink.buffer))
    dur = size(sink.buffer, 1) / SAMPLERATE
    HTML(
        """
   <div class="polyhymnia-player" style="font-family:ui-monospace,monospace;
        border:1px solid $(THEME.border);border-radius:8px;padding:10px 12px;
        background:$(THEME.bg);color:$(THEME.fg);display:flex;gap:10px;align-items:center">
     <button id="ph-toggle" style="font:inherit;cursor:pointer;border:0;
             border-radius:5px;padding:5px 12px;background:$(THEME.accent);color:$(THEME.on_accent);
             font-weight:600">play</button>
     <span id="ph-status" style="opacity:.75;font-size:12px">
       $(round(dur, digits=2))s loop · $(sink.cycles) cycles · $(round(e.cps[], digits=3)) cps
     </span>
   </div>
   <script>
   (function() {
     const root = currentScript.parentElement;
     const btn = root.querySelector("#ph-toggle");
     const status = root.querySelector("#ph-status");
     const uri = "$(uri)";
$(AUDIO_GLUE)
     function label() {
       btn.textContent = G.playing ? "stop" : "play";
     }

     // Swap the looping buffer on the loop boundary. `phStop(at)` hands the
     // graph over from whatever was playing — including `scope`'s stems — so
     // the two widgets never stack on top of each other.
     function swap(buf) {
       const src = ctx.createBufferSource();
       src.buffer = buf;
       src.loop = true;
       src.connect(G.gain);

       const at = phBoundary();
       src.start(at);
       phStop(at);
       G.src = src;
       G.startTime = at;
       G.dur = buf.duration;
     }

     function stopAll() {
       phStop(null);
       G.startTime = null; G.playing = false; label();
     }

     const decoded = fetch(uri)
       .then(r => r.arrayBuffer())
       .then(b => ctx.decodeAudioData(b));

     decoded.then(buf => {
       G.buffer = buf;
       // Already playing from a previous run? Swap seamlessly, don't restart.
       if (G.playing) swap(buf);
       label();
     }).catch(err => { status.textContent = "decode failed: " + err; });

     btn.onclick = async () => {
       if (ctx.state === "suspended") await ctx.resume();
       if (G.playing) { stopAll(); return; }
       const buf = G.buffer || (await decoded);
       G.playing = true;
       swap(buf);
       label();
     };

     label();
     // Pluto discards the cell output on re-run; keep the audio, drop the node.
     invalidation.then(() => { btn.onclick = null; });
   })();
   </script>
   """,
    )
end

# -------------------------------------------------------- waveform drawing

_esc(x) = replace(string(x), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

"""
    peaks(buf, cols) -> (mins, maxs)

Minimum and maximum of `buf` per output column. Drawing a waveform that is far
longer than the pixels available has to go through min/max like this — plain
subsampling aliases the signal into noise that looks nothing like the sound.
"""
function peaks(buf::AbstractVector{<:Real}, cols::Int)
    mins = zeros(Float64, cols)
    maxs = zeros(Float64, cols)
    n = length(buf)
    n == 0 && return mins, maxs
    @inbounds for c in 1:cols
        a = 1 + fld((c - 1) * n, cols)
        b = min(max(fld(c * n, cols), a), n)
        lo, hi = Inf, -Inf
        for i in a:b
            v = Float64(buf[i])
            v < lo && (lo = v)
            v > hi && (hi = v)
        end
        mins[c] = isfinite(lo) ? lo : 0.0
        maxs[c] = isfinite(hi) ? hi : 0.0
    end
    mins, maxs
end

# One decimal is well under a pixel and roughly halves the size of the emitted
# SVG, which matters when a chain has six stages of a few hundred columns each.
_r1(x) = round(Float64(x), digits = 1)
_ycoord(v, y, h, scale) = _r1(y + h / 2 - clamp(v / scale, -1.0, 1.0) * (h / 2))

"""
A filled min/max band — the DAW-style waveform blob.
"""
function _band_svg(buf, x, y, w, h, scale, colour)
    cols = max(round(Int, w), 2)
    mins, maxs = peaks(buf, cols)
    io = IOBuffer()
    # The stroke matters for signals that barely deviate — a slow envelope is a
    # sub-pixel band, and without it the row looks empty.
    print(
        io,
        """<polygon fill="$colour" fill-opacity="0.75" stroke="$colour"
        stroke-width="0.8" points=\"""",
    )
    for c in 1:cols
        print(io, _r1(x + (c - 0.5) * w / cols), ",", _ycoord(maxs[c], y, h, scale), " ")
    end
    for c in cols:-1:1
        print(io, _r1(x + (c - 0.5) * w / cols), ",", _ycoord(mins[c], y, h, scale), " ")
    end
    print(io, "\"/>")
    String(take!(io))
end

"""
A line trace of samples `a:b` — close enough in to see the actual wave shape.
"""
function _trace_svg(buf, a::Int, b::Int, x, y, w, h, scale, colour)
    a = clamp(a, 1, max(length(buf), 1))
    b = clamp(b, a, length(buf))
    b <= a && return ""
    step = max(1, (b - a) ÷ (2 * max(round(Int, w), 1)))
    io = IOBuffer()
    print(io, """<polyline fill="none" stroke="$colour" stroke-width="1.2" points=\"""")
    for i in a:step:b
        print(io, _r1(x + w * (i - a) / (b - a)), ",", _ycoord(buf[i], y, h, scale), " ")
    end
    print(io, "\"/>")
    String(take!(io))
end

# ------------------------------------------------------- signal-chain view

"""
    signal_chain(pat; event, cycle, cps, width, periods) -> HTML

Take one event out of `pat` and show what every stage of the synth does to it:
the raw oscillator, the envelope, their product, each filter, the gain. Left
column is the whole voice, right column zooms to `periods` periods of the
fundamental so the wave shape itself is visible.

`event` picks which note of the cycle to inspect (1-based, in time order).
"""
function signal_chain(
    pat;
    event::Int = 1,
    cycle::Int = 0,
    cps::Real = 0.5,
    width::Int = 700,
    rowh::Int = 58,
    periods::Real = 4,
)
    note_ = """style="font-family:ui-monospace,monospace;color:$(THEME.dim);padding:8px" """
    evs = onset_events(pat, cycle)
    isempty(evs) && return HTML("<div $note_>(no events in cycle $cycle)</div>")

    idx = clamp(event, 1, length(evs))
    ev = evs[idx]
    ctl = controls_of(ev)
    dur = Float64(duration(ev.extent)) / cps

    stages = voice_stages(ctl, dur)
    isempty(stages) && return HTML("<div $note_>(event $idx makes no sound)</div>")

    scale = max(1.0, maximum(b -> isempty(b) ? 0.0 : maximum(abs, b), last.(stages)))
    final = last(stages[end])
    sr = SAMPLERATE

    # Zoom in on the loudest moment: for a plucked note the interesting shape is
    # right after the attack, not at the start or the tail.
    freq = voice_freq(ctl)
    win = max(round(Int, (freq > 0 ? periods / freq : 0.012) * sr), 16)
    centre = isempty(final) ? 1 : argmax(abs.(final))
    a = clamp(centre - win ÷ 2, 1, max(length(final) - win, 1))
    b = min(a + win, length(final))

    labelw, gap, pad = 138, 10, 8
    rest = width - labelw - 2gap - 2pad
    fullw = round(Int, rest * 0.58)
    detw = rest - fullw
    x1 = pad + labelw
    x2 = x1 + fullw + gap
    top, foot = 26, 20
    h = top + rowh * length(stages) + foot

    label = event_label(ctl)
    head =
        "$(_esc(label)) · event $idx/$(length(evs)) of cycle $cycle · " *
        "$(round(dur * 1000, digits = 1)) ms · $(length(final)) samples"

    io = IOBuffer()
    print(
        io,
        """<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$h"
  viewBox="0 0 $width $h"
  style="background:$(THEME.bg);border-radius:8px;font-family:ui-monospace,monospace">""",
    )
    print(
        io,
        """<text x="$pad" y="16" fill="$(THEME.accent)" font-size="11">$head</text>""",
    )

    for (i, (name, buf)) in enumerate(stages)
        y = top + (i - 1) * rowh
        ph = rowh - 12
        colour = PALETTE[mod1(i, length(PALETTE))]
        peak = isempty(buf) ? 0.0 : maximum(abs, buf)

        print(
            io,
            """<text x="$pad" y="$(y + ph / 2 - 4)" fill="$(THEME.fg)" font-size="10.5"
        dominant-baseline="middle">$(_esc(name))</text>""",
            """<text x="$pad" y="$(y + ph / 2 + 9)" fill="$(THEME.faint)" font-size="9.5"
        dominant-baseline="middle">peak $(round(peak, digits = 3))</text>""",
        )
        for (x, w) in ((x1, fullw), (x2, detw))
            print(
                io,
                """<rect x="$x" y="$y" width="$w" height="$ph" rx="3" fill="$(THEME.inset)"/>""",
                """<line x1="$x" y1="$(y + ph / 2)" x2="$(x + w)" y2="$(y + ph / 2)"
            stroke="$(THEME.border)" stroke-width="1"/>""",
            )
        end
        # Show where the right-hand zoom is taken from.
        if !isempty(final)
            zx = x1 + fullw * (a - 1) / length(final)
            zw = max(fullw * (b - a) / length(final), 1.0)
            print(
                io,
                """<rect x="$zx" y="$y" width="$zw" height="$ph"
            fill="$(THEME.accent)" fill-opacity="0.10"/>""",
            )
        end
        print(io, _band_svg(buf, x1, y, fullw, ph, scale, colour))
        print(io, _trace_svg(buf, a, b, x2, y, detw, ph, scale, colour))
    end

    zoomlab =
        freq > 0 ?
        "$(round(periods, digits = 1)) periods of $(round(freq, digits = 1)) Hz" : "12 ms"
    print(
        io,
        """<text x="$pad" y="$(h - 6)" fill="$(THEME.faint)" font-size="9.5">left: whole voice
    · right: $zoomlab · vertical scale ±$(round(scale, digits = 2))</text></svg>""",
    )
    HTML(String(take!(io)))
end

signal_chain(e::Engine, pat; kwargs...) = signal_chain(pat; cps = e.cps[], kwargs...)

# ------------------------------------------------------------- visualisation

"""
    pattern_plot(pat; cycles, width, height) -> HTML

A Strudel-style piano roll: one row per distinct sound, time running left to
right. Useful for seeing what a pattern does before committing your ears.
"""
function pattern_plot(pat; cycles::Int = 2, width::Int = 640, height::Int = 160)
    events = onset_events(pat, 0, cycles)

    labels = String[]
    for ev in events
        lab = event_label(ev)
        lab in labels || push!(labels, lab)
    end
    isempty(labels) && return HTML("""<div style="font-family:ui-monospace,monospace;
        color:$(THEME.dim);padding:8px">(silence)</div>""")

    sort!(labels)
    rowh = max(height ÷ max(length(labels), 1), 14)
    h = rowh * length(labels) + 24

    io = IOBuffer()
    print(
        io,
        """<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$h"
  viewBox="0 0 $width $h"
  style="background:$(THEME.bg);border-radius:8px;font-family:ui-monospace,monospace">""",
    )

    # cycle gridlines
    for c in 0:cycles
        x = width * c / cycles
        print(
            io,
            """<line x1="$x" y1="0" x2="$x" y2="$(h-24)"
        stroke="$(THEME.border)" stroke-width="1"/>""",
        )
        print(
            io,
            """<text x="$(x+4)" y="$(h-8)" fill="$(THEME.faint)" font-size="10">$c</text>""",
        )
    end

    for ev in events
        ctl = controls_of(ev)
        row = findfirst(==(event_label(ctl)), labels)
        ext = ev.extent::Span
        x = width * Float64(ext.b) / cycles
        bw = max(width * Float64(duration(ext)) / cycles - 2, 2.0)
        y = (row - 1) * rowh + 3
        col = PALETTE[mod1(row, length(PALETTE))]
        op = clamp(Float64(get(ctl, :gain, 0.8)), 0.15, 1.0)
        print(
            io,
            """<rect x="$x" y="$y" width="$bw" height="$(rowh-6)" rx="3"
        fill="$col" opacity="$op"/>""",
        )
    end

    for (i, lab) in enumerate(labels)
        y = (i - 1) * rowh + rowh / 2 + 2
        print(
            io,
            """<text x="6" y="$y" fill="$(THEME.fg)" font-size="11"
        dominant-baseline="middle">$lab</text>""",
        )
    end
    print(io, "</svg>")
    HTML(String(take!(io)))
end

# ------------------------------------------------------------ track scopes

_js_str(x) =
    '"' *
    replace(string(x), '\\' => "\\\\", '"' => "\\\"", '<' => "\\u003c", '\n' => "\\n") *
    '"'

_js_nums(v) = '[' * join((round(Float64(x), digits = 3) for x in v), ',') * ']'

"""
    scope(e, tracks; cycles, width) -> HTML

Player and live visualiser for a *list* of tracks. Each track is rendered to its
own buffer and gets its own node in the browser's audio graph, so each one can be
metered, soloed and scoped independently — the sum is exactly what `webaudio`
would have played.

`tracks` is a vector of patterns or of `"name" => pattern` pairs. Every track
shows the whole loop as a waveform with a playhead on it, and an oscilloscope
reading real samples off an `AnalyserNode` as they play.

Note that this needs the browser to hold the audio, so it visualises the
`WebAudioSink` path; under `PortAudioSink` the samples never leave Julia.

Per-track audio means the payload is roughly `cycles x tracks` seconds of WAV
travelling to the browser on every edit — about 240 kB per track-second, halved
for tracks that are not panned. `cycles` is the dial for that: widen it for more
variation, narrow it if edits start to feel sticky.
"""
function scope(
    e::Engine,
    tracks;
    cycles::Int = 2,
    width::Int = 700,
    rowh::Int = 52,
    cols::Int = 420,
)
    named = _named_tracks(tracks)
    isempty(named) && return HTML("""<div style="font-family:ui-monospace,monospace;
        color:$(THEME.dim);padding:8px">(no tracks)</div>""")

    # Keep the engine in step so `transport`, `wav` and `hush` still describe
    # what you are hearing.
    set_pattern!(e, stack(Pattern[pat for (_, pat) in named]))
    e.playing[] = true

    stems = render_stems(
        named,
        0,
        cycles;
        cps = e.cps[],
        sr = SAMPLERATE,
        tail = 2.0,
        wrap = true,
    )
    dur = maximum(size(buf, 1) for (_, buf) in stems) / SAMPLERATE

    entries = String[]
    for (i, (name, buf)) in enumerate(stems)
        summed = size(buf, 1) == 0 ? Float64[] : vec(sum(buf; dims = 2) ./ 2)
        mins, maxs = peaks(summed, cols)
        colour = PALETTE[mod1(i, length(PALETTE))]
        # An unpanned track carries the same samples twice; send it as mono and
        # let WebAudio's upmix put it back across both speakers. The comparison
        # needs slack: centre pan is `cos(π/4)` against `sin(π/4)`, which differ
        # in the last bit, and 16-bit PCM cannot represent the difference anyway.
        centred =
            size(buf, 1) > 0 && all(i -> abs(buf[i, 1] - buf[i, 2]) < 1e-9, axes(buf, 1))
        payload = centred ? view(buf, :, 1) : buf
        push!(
            entries,
            "{name:$(_js_str(name)),colour:$(_js_str(colour))," *
            "uri:$(_js_str(data_uri(wav_bytes(payload)))),mins:$(_js_nums(mins))," *
            "maxs:$(_js_nums(maxs))}",
        )
    end

    labelw, gap = 132, 8
    rest = width - labelw - 2gap
    loopw = round(Int, rest * 0.58)
    scopew = rest - loopw
    ph = rowh - 10

    rows = IOBuffer()
    for (i, (name, _)) in enumerate(stems)
        colour = PALETTE[mod1(i, length(PALETTE))]
        print(
            rows,
            """
    <div style="display:flex;gap:$(gap)px;align-items:center;margin-top:6px">
      <div style="width:$(labelw)px">
        <div style="color:$colour;font-size:11px;white-space:nowrap;overflow:hidden;
             text-overflow:ellipsis">$(_esc(name))</div>
        <div style="display:flex;gap:4px;align-items:center;margin-top:3px">
          <button data-mute="$i" style="font:inherit;font-size:9px;cursor:pointer;
                  border:1px solid $(THEME.border);border-radius:3px;padding:1px 5px;
                  background:$(THEME.inset);color:$(THEME.dim)">m</button>
          <button data-solo="$i" style="font:inherit;font-size:9px;cursor:pointer;
                  border:1px solid $(THEME.border);border-radius:3px;padding:1px 5px;
                  background:$(THEME.inset);color:$(THEME.dim)">s</button>
          <div style="flex:1;height:4px;background:$(THEME.inset);border-radius:2px;
               overflow:hidden"><div data-meter="$i" style="width:0%;height:100%;
               background:$colour"></div></div>
        </div>
      </div>
      <canvas data-loop="$i" width="$loopw" height="$ph"
              style="width:$(loopw)px;height:$(ph)px;border-radius:3px"></canvas>
      <canvas data-scope="$i" width="$scopew" height="$ph"
              style="width:$(scopew)px;height:$(ph)px;border-radius:3px"></canvas>
    </div>""",
        )
    end

    HTML(
        """
    <div class="polyhymnia-scope" style="font-family:ui-monospace,monospace;
         border:1px solid $(THEME.border);border-radius:8px;padding:10px 12px;
         background:$(THEME.bg);color:$(THEME.fg);width:$(width + 24)px;box-sizing:border-box">
      <div style="display:flex;gap:10px;align-items:center">
        <button id="ph-scope-toggle" style="font:inherit;cursor:pointer;border:0;
                border-radius:5px;padding:5px 12px;background:$(THEME.accent);color:$(THEME.on_accent);
                font-weight:600">play</button>
        <span id="ph-scope-status" style="opacity:.75;font-size:12px">
          $(length(stems)) tracks · $(round(dur, digits=2))s loop · $cycles cycles ·
          $(round(e.cps[], digits=3)) cps
        </span>
      </div>
      $(String(take!(rows)))
      <div style="opacity:.5;font-size:9.5px;margin-top:8px">
        left: whole loop with playhead · right: live oscilloscope (~20 ms,
        trigger-synced) · m mute, s solo
      </div>
    </div>
    <script>
    (function() {
      const root = currentScript.parentElement;
      const tracks = $(String("[" * join(entries, ",") * "]"));
      const btn = root.querySelector("#ph-scope-toggle");
      const status = root.querySelector("#ph-scope-status");

$(AUDIO_GLUE)
      const state = tracks.map(() => ({ mute: false, solo: false }));
      let nodes = [];          // per-track {gain, analyser, data} for this cell
      let raf = null;
      let dead = false;

      const label = () => { btn.textContent = G.playing ? "stop" : "play"; };

      function applyGains() {
        const anySolo = state.some(s => s.solo);
        nodes.forEach((n, i) => {
          const on = (anySolo ? state[i].solo : true) && !state[i].mute;
          n.gain.gain.setTargetAtTime(on ? 1 : 0, ctx.currentTime, 0.01);
        });
      }

      // Build the graph and start every stem at the same instant, so the tracks
      // stay sample-locked to each other however long this loops for.
      function startAt(bufs, at) {
        const fresh = [];
        bufs.forEach(buf => {
          const src = ctx.createBufferSource();
          src.buffer = buf;
          src.loop = true;
          const g = ctx.createGain();
          const an = ctx.createAnalyser();
          an.fftSize = 2048;
          an.smoothingTimeConstant = 0;
          src.connect(g); g.connect(an); an.connect(G.gain);
          src.start(at);
          fresh.push({ src: src, gain: g, analyser: an,
                       data: new Float32Array(an.fftSize) });
        });
        phStop(at);
        G.srcs = fresh.map(n => n.src);
        G.startTime = at;
        G.dur = bufs[0].duration;
        nodes = fresh;
        applyGains();
      }

      const decoded = Promise.all(tracks.map(t =>
        fetch(t.uri).then(r => r.arrayBuffer()).then(b => ctx.decodeAudioData(b))));

      decoded.then(bufs => {
        G.buffers = bufs;
        // Already playing from a previous run? Land the swap on the loop
        // boundary so an edit never cuts a note in half.
        if (G.playing) startAt(bufs, phBoundary());
        label();
      }).catch(err => { status.textContent = "decode failed: " + err; });

      btn.onclick = async () => {
        if (ctx.state === "suspended") await ctx.resume();
        if (G.playing) {
          phStop(null);
          G.playing = false; G.startTime = null; nodes = [];
          label();
          return;
        }
        const bufs = G.buffers || (await decoded);
        startAt(bufs, ctx.currentTime + 0.08);
        G.playing = true;
        label();
      };

      root.querySelectorAll("[data-mute]").forEach(b => {
        b.onclick = () => {
          const i = +b.dataset.mute - 1;
          state[i].mute = !state[i].mute;
          b.style.background = state[i].mute ? "$(THEME.alert)" : "$(THEME.inset)";
          b.style.color = state[i].mute ? "$(THEME.on_accent)" : "$(THEME.dim)";
          applyGains();
        };
      });
      root.querySelectorAll("[data-solo]").forEach(b => {
        b.onclick = () => {
          const i = +b.dataset.solo - 1;
          state[i].solo = !state[i].solo;
          b.style.background = state[i].solo ? "$(THEME.warn)" : "$(THEME.inset)";
          b.style.color = state[i].solo ? "$(THEME.on_accent)" : "$(THEME.dim)";
          applyGains();
        };
      });

      // ------------------------------------------------------------- drawing
      const loops = tracks.map((_, i) =>
        root.querySelector('[data-loop="' + (i + 1) + '"]'));
      const scopes = tracks.map((_, i) =>
        root.querySelector('[data-scope="' + (i + 1) + '"]'));
      const meters = tracks.map((_, i) =>
        root.querySelector('[data-meter="' + (i + 1) + '"]'));

      function drawLoop(cv, t, phase) {
        const g = cv.getContext("2d");
        const w = cv.width, h = cv.height, mid = h / 2;
        g.fillStyle = "$(THEME.inset)"; g.fillRect(0, 0, w, h);
        g.strokeStyle = "$(THEME.border)"; g.lineWidth = 1;
        g.beginPath(); g.moveTo(0, mid + 0.5); g.lineTo(w, mid + 0.5); g.stroke();

        const n = t.maxs.length;
        g.fillStyle = t.colour; g.globalAlpha = 0.75;
        g.beginPath();
        for (let c = 0; c < n; c++) {
          g.lineTo(c * w / n, mid - t.maxs[c] * mid);
        }
        for (let c = n - 1; c >= 0; c--) {
          g.lineTo(c * w / n, mid - t.mins[c] * mid);
        }
        g.closePath(); g.fill(); g.globalAlpha = 1;

        if (phase != null) {
          const x = Math.round(phase * w) + 0.5;
          g.strokeStyle = "$(THEME.trace)"; g.globalAlpha = 0.8;
          g.beginPath(); g.moveTo(x, 0); g.lineTo(x, h); g.stroke();
          g.globalAlpha = 1;
        }
      }

      function drawScope(cv, t, node) {
        const g = cv.getContext("2d");
        const w = cv.width, h = cv.height, mid = h / 2;
        g.fillStyle = "$(THEME.inset)"; g.fillRect(0, 0, w, h);
        g.strokeStyle = "$(THEME.border)"; g.lineWidth = 1;
        g.beginPath(); g.moveTo(0, mid + 0.5); g.lineTo(w, mid + 0.5); g.stroke();
        if (!node) return 0;

        const d = node.data;
        node.analyser.getFloatTimeDomainData(d);
        const span = Math.min(d.length >> 1, 900);   // ~20 ms at 44.1 kHz

        // Trigger on a rising zero crossing, or the trace slides sideways every
        // frame and the wave shape is impossible to read.
        let start = 0;
        for (let i = 1; i < d.length - span; i++) {
          if (d[i - 1] <= 0 && d[i] > 0) { start = i; break; }
        }

        g.strokeStyle = t.colour; g.lineWidth = 1.2;
        g.beginPath();
        for (let i = 0; i < span; i++) {
          const v = Math.max(-1, Math.min(1, d[start + i]));
          const x = i * w / span, y = mid - v * mid * 0.95;
          i ? g.lineTo(x, y) : g.moveTo(x, y);
        }
        g.stroke();

        let sum = 0;
        for (let i = 0; i < d.length; i++) sum += d[i] * d[i];
        return Math.sqrt(sum / d.length);
      }

      function frame() {
        if (dead) return;
        let phase = null;
        if (G.playing && G.startTime != null && G.dur > 0) {
          const el = ctx.currentTime - G.startTime;
          phase = el < 0 ? 0 : (el % G.dur) / G.dur;
        }
        tracks.forEach((t, i) => {
          drawLoop(loops[i], t, phase);
          const rms = drawScope(scopes[i], t, nodes[i]);
          meters[i].style.width = Math.min(100, rms * 260).toFixed(1) + "%";
        });
        raf = requestAnimationFrame(frame);
      }
      frame();

      label();
      // Pluto throws the DOM away on re-run; stop drawing into it, but leave the
      // audio graph alone so the next render can swap into it mid-loop.
      invalidation.then(() => {
        dead = true;
        if (raf) cancelAnimationFrame(raf);
        btn.onclick = null;
      });
    })();
    </script>
    """,
    )
end

scope(tracks; kwargs...) = scope(live(), tracks; kwargs...)

"""
    transport(e) -> HTML

A compact readout of engine state: backend, tempo, and what it can do.
"""
function transport(e::Engine = live())
    backend = e.sink isa PortAudioSink ? "PortAudio (streaming)" : "WebAudio (looping)"
    HTML("""
    <div style="font-family:ui-monospace,monospace;font-size:12px;
         background:$(THEME.bg);color:$(THEME.fg);border:1px solid $(THEME.border);
         border-radius:8px;padding:10px 12px;line-height:1.7">
      <b style="color:$(THEME.accent)">polyhymnia</b><br>
      backend &nbsp;$(backend)<br>
      tempo &nbsp;&nbsp;&nbsp;$(round(e.cps[], digits=3)) cps
             ($(round(e.cps[]*60*4, digits=1)) bpm at 4 beats/cycle)<br>
      state &nbsp;&nbsp;&nbsp;$(e.playing[] ? "playing" : "stopped")<br>
      <span style="opacity:.65">$(describe(e.sink))</span>
    </div>
    """)
end
