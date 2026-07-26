# Two ways to get sound out, behind one interface.
#
# PortAudioSink streams continuously from a background task, so playback is
# genuinely endless and a pattern swap lands on the next cycle boundary.
#
# WebAudioSink renders a fixed number of cycles and hands the buffer to the
# browser to loop. Nothing streams from Julia, which is what lets it work with no
# sound device at all (and over a network); the trade-off is that variation
# longer than the rendered window repeats.

abstract type AudioSink end

"""
Human-readable note on what a sink can and cannot do.
"""
function describe end

# ------------------------------------------------------------- PortAudioSink

"""
    PortAudioSink(; device, blocksize)

Streams to the machine's sound card via PortAudio. On WSL2 this needs ALSA
pointed at WSLg's PulseAudio — see `ensure_alsa_config!`.
"""
mutable struct PortAudioSink <: AudioSink
    device::Union{String,Nothing}
    stream::Any
    PortAudioSink(; device = nothing) = new(device, nothing)
end

describe(
    ::PortAudioSink,
) = "PortAudio: continuous local playback, endless variation, needs a sound device."

# Remember the generated config so repeated calls do not litter /tmp.
const ALSA_CONF = Ref{Union{String,Nothing}}(nothing)

"""
    ensure_alsa_config!() -> Bool

PortAudio finds zero devices under WSL2 because ALSA has no configuration
pointing at WSLg's PulseAudio socket. This writes a minimal config, points
`ALSA_CONFIG_PATH` at it, and — because PortAudio initialises ALSA when the
package loads, which is almost always before this runs — re-initialises
PortAudio so the new config actually takes effect.

Returns true when a config is in effect. An existing `~/.asoundrc` or a
pre-set `ALSA_CONFIG_PATH` is left alone.
"""
function ensure_alsa_config!()
    configured = if haskey(ENV, "ALSA_CONFIG_PATH") && isfile(ENV["ALSA_CONFIG_PATH"])
        true
    elseif isfile(expanduser("~/.asoundrc"))
        true
    elseif ispath("/mnt/wslg/PulseServer")
        path = ALSA_CONF[]
        if path === nothing || !isfile(path)
            path = joinpath(mktempdir(; cleanup = false), "asound.conf")
            write(
                path,
                """
    pcm.!default { type pulse }
    ctl.!default { type pulse }
    pcm.pulse { type pulse }
    ctl.pulse { type pulse }
    """,
            )
            ALSA_CONF[] = path
        end
        ENV["ALSA_CONFIG_PATH"] = path
        true
    else
        false
    end

    # ALSA reads its configuration once, when PortAudio first initialises it.
    # Cycling PortAudio makes it pick up what we just wrote.
    if configured
        try
            if PortAudio.LibPortAudio.Pa_GetDeviceCount() <= 0
                PortAudio.LibPortAudio.Pa_Terminate()
                PortAudio.LibPortAudio.Pa_Initialize()
            end
        catch err
            @debug "could not re-initialise PortAudio" exception = err
        end
    end
    configured
end

"""
Number of output devices PortAudio can see, after fixing up ALSA if needed.
"""
function device_count()
    try
        ensure_alsa_config!()
        return Int(PortAudio.LibPortAudio.Pa_GetDeviceCount())
    catch
        return 0
    end
end

function start!(sink::PortAudioSink, e::Engine)
    ensure_alsa_config!()
    if Threads.nthreads() < 2
        @warn """PortAudio playback wants a spare thread: rendering a cycle and \
                 writing it cannot overlap on a single thread, so the device \
                 starves and you get dropouts. Restart Julia with `-t auto` \
                 (or use WebAudioSink, which is unaffected)."""
    end
    # Render one cycle up front. Compiling the render path takes a second or so
    # on first use, which would otherwise starve the stream just after it opens.
    try
        render_cycles(e.pattern[], 0, 1; cps = e.cps[], sr = SAMPLERATE, tail = 0.0)
    catch err
        @debug "warm-up render failed" exception = err
    end

    e.playing[] = true
    e.task = Threads.@spawn _stream_loop(sink, e)
    e
end

function stop!(sink::PortAudioSink, e::Engine)
    e.playing[] = false
    e.task !== nothing && !istaskdone(e.task) && (
        try
            wait(e.task)
        catch
        end
    )
    e.task = nothing
    e
end

"""
Render cycles ahead of playback on one task and write them on another.

Writing to PortAudio blocks for roughly the duration of the buffer, so rendering
has to happen *during* that wait or the device runs dry between cycles. The
channel gives the writer a couple of cycles of slack to draw on.
"""
function _stream_loop(sink::PortAudioSink, e::Engine)
    sr = SAMPLERATE
    args = sink.device === nothing ? () : (sink.device,)
    ready = Channel{Matrix{Float64}}(2)

    producer = Threads.@spawn begin
        try
            carry = zeros(Float64, 0, 2)
            c = e.cycle[]
            while e.playing[]
                cps = e.cps[]
                buf = render_cycles(
                    e.pattern[],
                    c,
                    c + 1;
                    cps = cps,
                    sr = sr,
                    tail = 2.0,
                    wrap = false,
                )
                nmain = min(round(Int, sr / cps), size(buf, 1))

                # Fold in whatever was still ringing from the previous cycle.
                if !isempty(carry)
                    m = min(size(carry, 1), size(buf, 1))
                    buf[1:m, :] .+= carry[1:m, :]
                end

                out = buf[1:nmain, :]
                limit!(out)
                carry =
                    size(buf, 1) > nmain ? buf[(nmain + 1):end, :] : zeros(Float64, 0, 2)

                put!(ready, out)      # blocks while the writer is two cycles behind
                c += 1
            end
        catch err
            err isa InvalidStateException || @debug "render task ended" exception = err
        finally
            close(ready)
        end
    end

    try
        PortAudio.PortAudioStream(
            args...,
            0,
            2;
            samplerate = sr,
            warn_xruns = false,
        ) do stream
            sink.stream = stream
            for out in ready
                e.playing[] || break
                write(stream, out)
                e.cycle[] += 1
            end
        end
    catch err
        err isa InterruptException || @error "PortAudio stream stopped" exception = err
    finally
        e.playing[] = false
        sink.stream = nothing
        isopen(ready) && close(ready)
        istaskdone(producer) || (
            try
                wait(producer)
            catch
            end
        )
    end
end

# -------------------------------------------------------------- WebAudioSink

"""
    WebAudioSink(; cycles)

Renders `cycles` cycles up front; the browser loops the result and crossfades to
a new buffer at the next loop boundary whenever the pattern changes.
"""
mutable struct WebAudioSink <: AudioSink
    cycles::Int
    buffer::Matrix{Float64}
    revision::Int
    WebAudioSink(; cycles::Int = 4) = new(cycles, zeros(Float64, 0, 2), 0)
end

describe(s::WebAudioSink) =
    "WebAudio: no sound device needed, plays in the browser; " *
    "loops every $(s.cycles) cycles, so longer variation repeats."

"""
Re-render the loop buffer from the engine's current pattern and tempo.
"""
function refresh!(sink::WebAudioSink, e::Engine)
    buf = render_cycles(
        e.pattern[],
        0,
        sink.cycles;
        cps = e.cps[],
        sr = SAMPLERATE,
        tail = 2.0,
        wrap = true,
    )
    limit!(buf)
    sink.buffer = buf
    sink.revision += 1
    sink
end

function start!(sink::WebAudioSink, e::Engine)
    e.playing[] = true
    refresh!(sink, e)
    e
end

stop!(sink::WebAudioSink, e::Engine) = (e.playing[] = false; e)

"""
Interleaved `Float32` frames, the layout WebAudio wants.
"""
function interleaved(sink::WebAudioSink)
    buf = sink.buffer
    n = size(buf, 1)
    out = Vector{Float32}(undef, 2n)
    @inbounds for i in 1:n
        out[2i - 1] = Float32(buf[i, 1])
        out[2i] = Float32(buf[i, 2])
    end
    out
end

# ----------------------------------------------------------------- dispatch

start!(e::Engine) = start!(e.sink, e)
stop!(e::Engine) = stop!(e.sink, e)

"""
Pick a sink automatically: the sound card if there is one, else the browser.
"""
default_sink(; cycles::Int = 4) =
    device_count() > 0 ? PortAudioSink() : WebAudioSink(; cycles = cycles)
