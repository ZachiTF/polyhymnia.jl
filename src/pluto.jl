# The notebook front end.
#
# Audio reaches the browser as a base64 WAV data URI, decoded by WebAudio into an
# AudioBuffer and looped. That keeps the whole path dependency-free (Base64 is
# stdlib) and gives genuinely gapless looping, which an `<audio loop>` element
# cannot. State lives on `window._polyhymnia` so that a Pluto cell re-run swaps
# the buffer on a running context instead of stacking up a second one.

using Base64: base64encode

# ------------------------------------------------------------ WAV encoding

"""
    wav_bytes(buf; sr) -> Vector{UInt8}

Encode an `n x 2` float buffer as 16-bit PCM WAV.
"""
function wav_bytes(buf::AbstractMatrix{Float64}; sr::Int = SAMPLERATE)
    n = size(buf, 1)
    io = IOBuffer()
    datasize = n * 2 * 2                     # frames x channels x 2 bytes

    write(io, "RIFF")
    write(io, UInt32(36 + datasize))
    write(io, "WAVE")
    write(io, "fmt ")
    write(io, UInt32(16))                    # PCM header size
    write(io, UInt16(1))                     # format: PCM
    write(io, UInt16(2))                     # channels
    write(io, UInt32(sr))
    write(io, UInt32(sr * 2 * 2))            # byte rate
    write(io, UInt16(4))                     # block align
    write(io, UInt16(16))                    # bits per sample
    write(io, "data")
    write(io, UInt32(datasize))

    @inbounds for i in 1:n, ch in 1:2
        v = clamp(buf[i, ch], -1.0, 1.0)
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
        border:1px solid #3a3a4a;border-radius:8px;padding:10px 12px;
        background:#16161e;color:#c8c8d4;display:flex;gap:10px;align-items:center">
     <button id="ph-toggle" style="font:inherit;cursor:pointer;border:0;
             border-radius:5px;padding:5px 12px;background:#7aa2f7;color:#16161e;
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

     const G = (window._polyhymnia = window._polyhymnia || {});
     if (!G.ctx) {
       G.ctx = new (window.AudioContext || window.webkitAudioContext)();
       G.gain = G.ctx.createGain();
       G.gain.connect(G.ctx.destination);
     }
     const ctx = G.ctx;

     function label() {
       btn.textContent = G.playing ? "stop" : "play";
     }

     // Swap the looping buffer, aligned to the current loop's boundary so an
     // edit lands musically rather than mid-note.
     function swap(buf) {
       const src = ctx.createBufferSource();
       src.buffer = buf;
       src.loop = true;
       src.connect(G.gain);

       const now = ctx.currentTime;
       let at = now + 0.06;
       if (G.src && G.startTime != null && G.dur > 0) {
         const k = Math.ceil((now + 0.06 - G.startTime) / G.dur);
         at = G.startTime + k * G.dur;
       }
       src.start(at);
       if (G.src) { try { G.src.stop(at); } catch (e) {} }
       G.src = src;
       G.startTime = at;
       G.dur = buf.duration;
     }

     function stopAll() {
       if (G.src) { try { G.src.stop(); } catch (e) {} }
       G.src = null; G.startTime = null; G.playing = false; label();
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

# ------------------------------------------------------------- visualisation

"""
    pattern_plot(pat; cycles, width, height) -> HTML

A Strudel-style piano roll: one row per distinct sound, time running left to
right. Useful for seeing what a pattern does before committing your ears.
"""
function pattern_plot(pat; cycles::Int = 2, width::Int = 640, height::Int = 160)
    p = to_pattern(pat)
    events = filter(has_onset, p.query(Span(Time(0), Time(cycles))))

    labels = String[]
    for ev in events
        ctl = ev.value isa Controls ? ev.value : as_controls(:s, ev.value)
        lab = string(get(ctl, :s, get(ctl, :note, get(ctl, :n, "?"))))
        lab in labels || push!(labels, lab)
    end
    isempty(labels) && return HTML("""<div style="font-family:ui-monospace,monospace;
        color:#8a8a9a;padding:8px">(silence)</div>""")

    sort!(labels)
    rowh = max(height ÷ max(length(labels), 1), 14)
    h = rowh * length(labels) + 24
    palette = ["#7aa2f7", "#9ece6a", "#e0af68", "#bb9af7", "#7dcfff", "#f7768e", "#73daca"]

    io = IOBuffer()
    print(
        io,
        """<svg width="$width" height="$h" viewBox="0 0 $width $h"
  style="background:#16161e;border-radius:8px;font-family:ui-monospace,monospace">""",
    )

    # cycle gridlines
    for c in 0:cycles
        x = width * c / cycles
        print(
            io,
            """<line x1="$x" y1="0" x2="$x" y2="$(h-24)"
        stroke="#3a3a4a" stroke-width="1"/>""",
        )
        print(io, """<text x="$(x+4)" y="$(h-8)" fill="#6a6a7a" font-size="10">$c</text>""")
    end

    for ev in events
        ctl = ev.value isa Controls ? ev.value : as_controls(:s, ev.value)
        lab = string(get(ctl, :s, get(ctl, :note, get(ctl, :n, "?"))))
        row = findfirst(==(lab), labels)
        ext = ev.extent::Span
        x = width * Float64(ext.b) / cycles
        bw = max(width * Float64(duration(ext)) / cycles - 2, 2.0)
        y = (row - 1) * rowh + 3
        col = palette[mod1(row, length(palette))]
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
            """<text x="6" y="$y" fill="#c8c8d4" font-size="11"
        dominant-baseline="middle">$lab</text>""",
        )
    end
    print(io, "</svg>")
    HTML(String(take!(io)))
end

"""
    transport(e) -> HTML

A compact readout of engine state: backend, tempo, and what it can do.
"""
function transport(e::Engine = live())
    backend = e.sink isa PortAudioSink ? "PortAudio (streaming)" : "WebAudio (looping)"
    HTML("""
    <div style="font-family:ui-monospace,monospace;font-size:12px;
         background:#16161e;color:#c8c8d4;border:1px solid #3a3a4a;
         border-radius:8px;padding:10px 12px;line-height:1.7">
      <b style="color:#7aa2f7">polyhymnia</b><br>
      backend &nbsp;$(backend)<br>
      tempo &nbsp;&nbsp;&nbsp;$(round(e.cps[], digits=3)) cps
             ($(round(e.cps[]*60*4, digits=1)) bpm at 4 beats/cycle)<br>
      state &nbsp;&nbsp;&nbsp;$(e.playing[] ? "playing" : "stopped")<br>
      <span style="opacity:.65">$(describe(e.sink))</span>
    </div>
    """)
end
