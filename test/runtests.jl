using Test
using TOML
using Polyhymnia

# Events of one cycle, ordered by onset — the shape most assertions want.
cyc(p, c = 0) = sort(query_cycle(to_pattern(p), c), by = ev -> ev.extent.b)
vals(p, c = 0) = [ev.value for ev in cyc(p, c)]
spans(p, c = 0) = [(ev.extent.b, ev.extent.e) for ev in cyc(p, c)]

@testset "Polyhymnia" begin
    @testset "pattern algebra" begin
        @test isempty(cyc(silence))
        @test vals(pure("a")) == ["a"]
        @test spans(pure("a")) == [(0 // 1, 1 // 1)]

        @test spans(fastcat([pure("a"), pure("b")])) == [(0 // 1, 1 // 2), (1 // 2, 1 // 1)]
        @test sort(vals(overlay(pure("a"), pure("b")))) == ["a", "b"]

        # slowcat advances one of *its own* cycles per visit
        sc = slowcat([mini("a b"), pure("c")])
        @test vals(sc, 0) == ["a", "b"]
        @test vals(sc, 1) == ["c"]
        @test vals(sc, 2) == ["a", "b"]

        @test spans(fast(2, pure("a"))) == [(0 // 1, 1 // 2), (1 // 2, 1 // 1)]
        @test vals(slow(2, mini("a b")), 0) == ["a"]
        @test vals(slow(2, mini("a b")), 1) == ["b"]

        @test vals(rev(mini("a b c"))) == ["c", "b", "a"]
        @test rev(rev(mini("a b c"))) |> vals == ["a", "b", "c"]

        @test spans(rotr(1 // 4, pure("a"))) == [(1 // 4, 5 // 4)]
        # Shifting earlier moves cycle 0's onset off the front; the next one
        # lands at 3/4, since only events *beginning* in the cycle are kept.
        @test spans(rotl(1 // 4, pure("a"))) == [(3 // 4, 7 // 4)]

        # `every` fires on cycles divisible by n
        ev = every(2, rev, mini("a b"))
        @test vals(ev, 0) == ["b", "a"]
        @test vals(ev, 1) == ["a", "b"]

        @test spans(timecat([(3, pure("a")), (1, pure("b"))])) ==
              [(0 // 1, 3 // 4), (3 // 4, 1 // 1)]
    end

    @testset "euclid" begin
        @test Int.(bjorklund(3, 8)) == [1, 0, 0, 1, 0, 0, 1, 0]
        @test Int.(bjorklund(5, 8)) == [1, 0, 1, 1, 0, 1, 1, 0]
        @test Int.(bjorklund(4, 4)) == [1, 1, 1, 1]
        @test count(bjorklund(5, 16)) == 5
        @test length(cyc(euclid(3, 8, pure("x")))) == 3
    end

    @testset "derived combinators" begin
        @test sort(vals(superimpose(rev, m"a b"))) == ["a", "a", "b", "b"]

        # off layers a copy shifted later in time
        @test [ev.extent.b for ev in cyc(off(1 // 4, identity, m"a"))] == [0 // 1, 1 // 4]

        # ply subdivides each event inside its own extent — four events in the
        # same places `a b` had two, not the pattern running twice as fast
        @test vals(ply(2, m"a b")) == ["a", "a", "b", "b"]
        @test spans(ply(2, m"a b")) ==
              [(0 // 1, 1 // 4), (1 // 4, 1 // 2), (1 // 2, 3 // 4), (3 // 4, 1 // 1)]
        @test vals(ply(1, m"a b")) == ["a", "b"]

        it = iter(2, m"a b")
        @test vals(it, 0) == ["a", "b"]
        @test vals(it, 1) == ["b", "a"]
        @test vals(it, 2) == ["a", "b"]

        pal = palindrome(m"a b c")
        @test vals(pal, 0) == ["a", "b", "c"]
        @test vals(pal, 1) == ["c", "b", "a"]

        # segment samples a continuous signal into discrete events
        seg = segment(4, saw_lfo)
        @test length(cyc(seg)) == 4
        @test all(v -> 0 <= v <= 1, vals(seg))
        @test issorted(vals(seg))          # a saw rises across the cycle

        # `within` transforms the whole pattern and keeps only the window's
        # share of the result, so the first half runs double-time here
        @test vals(within(0, 1 // 2, p -> fast(2, p), m"a b")) == ["a", "b", "b"]

        # chunk walks that window along, one place per cycle
        ch = chunk(2, p -> fast(2, p), m"a b")
        @test vals(ch, 0) == ["a", "b", "b"]
        @test vals(ch, 1) == ["a", "a", "b"]

        # sometimes_by splits the events in two and transforms one half; the
        # halves are complementary, so nothing is lost or doubled
        shout = p -> map_values(_ -> "B", p)
        @test length(cyc(sometimes(shout, m"a*16"))) == 16
        @test all(==("a"), vals(sometimes_by(0, shout, m"a*16")))
        @test all(==("B"), vals(sometimes_by(1, shout, m"a*16")))
        @test count(==("B"), vals(rarely(shout, m"a*16"))) <
              count(==("B"), vals(often(shout, m"a*16")))

        # leaving the pattern off gives back the transformation itself
        @test vals(every(2, fast(2), m"a b"), 0) == ["a", "b", "a", "b"]
        @test vals(every(2, fast(2), m"a b"), 1) == ["a", "b"]
        @test vals(ply(2)(m"a b")) == vals(ply(2, m"a b"))
        @test vals(iter(2)(m"a b"), 1) == ["b", "a"]

        # jux sends the original one way and the transform the other
        j = cyc(jux(rev, m"a b"))
        @test length(j) == 4
        @test sort([ev.value[:pan] for ev in j]) == [0.0, 0.0, 1.0, 1.0]
        @test sort([ev.value[:pan] for ev in cyc(jux(rev, m"a"; by = 0))]) == [0.5, 0.5]
    end

    @testset "mini-notation" begin
        @test vals(m"bd sd") == ["bd", "sd"]
        @test vals(m"bd [sd sd]") == ["bd", "sd", "sd"]
        @test spans(m"bd [sd sd]") == [(0 // 1, 1 // 2), (1 // 2, 3 // 4), (3 // 4, 1 // 1)]

        @test length(cyc(m"bd*4")) == 4
        @test vals(m"~ sd") == ["sd"]
        @test vals(m"bd!3") == ["bd", "bd", "bd"]
        @test spans(m"bd@3 sd") == spans(m"bd _ _ sd")

        # alternation, including nesting
        @test vals(m"<a b>", 0) == ["a"]
        @test vals(m"<a b>", 1) == ["b"]
        @test [vals(m"<a <b c>>", c)[1] for c in 0:3] == ["a", "b", "a", "c"]

        @test sort(vals(m"[bd, hh]")) == ["bd", "hh"]
        @test length(cyc(m"bd(3,8)")) == 3
        @test vals(m"1 2 3") == [1, 2, 3]
        @test vals(m"0.5") == [0.5]
        @test isempty(cyc(m""))

        # degrade is deterministic: identical queries agree
        @test length(cyc(m"bd*16?")) == length(cyc(m"bd*16?"))

        @test_throws Polyhymnia.MiniError mini("bd [sd")
        @test_throws Polyhymnia.MiniError mini("bd ]")
    end

    @testset "controls" begin
        ev = cyc(m"bd" |> gain(0.5))[1]
        @test ev.value isa Controls
        @test ev.value[:s] == "bd"
        @test ev.value[:gain] == 0.5

        # timing comes from the left, so a slower control does not add events
        p = m"bd sd" |> gain(1.0)
        @test length(cyc(p)) == 2

        # A faster control does not add events: timing comes from the left,
        # so one note takes the gain value overlapping its onset.
        q = m"bd" |> gain("0.2 0.9")
        @test length(cyc(q)) == 1
        @test cyc(q)[1].value[:gain] == 0.2

        # Bare values survive having a control applied to them.
        @test cyc(m"bd" |> gain(0.5))[1].value[:s] == "bd"

        @test cyc(m"c4" |> sound("saw"))[1].value[:s] == "saw"

        # LFOs and arithmetic
        lfo = saw_lfo * 100 + 10
        val = lfo.query(Span(Time(0), Time(1)))[1].value
        @test 10 <= val <= 110
    end

    @testset "event helpers" begin
        ev = onset_events(m"bd" |> gain(0.5))[1]
        @test controls_of(ev) isa Controls
        @test controls_of(ev)[:s] == "bd"
        # a bare value is promoted the same way `ensure_controls` promotes one
        bare = onset_events(m"bd")[1]
        @test controls_of(bare) == Controls(:s => "bd")

        @test event_label(ev) == "bd"
        @test event_label(onset_events(note("c3"))[1]) == "c3"
        @test event_label(Controls()) == "?"

        # ordered by onset, across as many cycles as asked for
        @test [Float64(e.extent.b) for e in onset_events(m"bd [sd sd]", 0, 2)] == [0.0, 0.5, 0.75, 1.0, 1.5, 1.75]
        @test length(onset_events(m"bd sd", 1)) == 2
        @test isempty(onset_events(silence))
    end

    @testset "pitch" begin
        @test to_freq("c4") ≈ 261.6 atol = 1.0
        @test to_freq("a4") ≈ 440.0 atol = 1.0
        @test to_freq("A4") ≈ 440.0 atol = 1.0
        @test to_freq("c5") ≈ 2 * to_freq("c4") atol = 1.0
        @test to_freq("f#3") ≈ to_freq("gb3") atol = 0.01
        @test to_freq(60) ≈ to_freq("c4") atol = 1.0    # MIDI note numbers
        @test to_freq(69) ≈ 440.0 atol = 1e-6
        @test to_freq(440.0) == 440.0                   # already a frequency
        @test to_freq("nonsense") == 0.0
    end

    @testset "synthesis" begin
        v = render_voice(Controls(:s => "sine", :note => "a4"), 0.25)
        @test !isempty(v)
        @test all(isfinite, v)
        @test maximum(abs, v) <= 1.0

        # every drum name renders something audible
        for d in ["bd", "sd", "hh", "oh", "cp", "rim", "lt", "mt", "ht"]
            b = render_voice(Controls(:s => d), 0.25)
            @test !isempty(b)
            @test maximum(abs, b) > 0
            @test all(isfinite, b)
        end

        # oscillators are the right length and in range
        for w in ["sine", "square", "saw", "tri", "noise"]
            o = oscillator(w, 440, 0.1, SAMPLERATE)
            @test length(o) == round(Int, 0.1 * SAMPLERATE)
            @test maximum(abs, o) <= 1.01
        end

        @test isempty(render_voice(Controls(:s => "sine", :note => "bogus"), 0.2))

        @test sound_name(Controls(:s => "saw")) == "saw"
        @test sound_name(Controls(:s => "bd:3")) == "bd"    # Strudel sample suffix
        @test sound_name(Controls()) == "sine"

        # `voice_freq` is what `_render_voice` pitches the oscillator by, so a
        # drawing that asks it cannot disagree with what is synthesised.
        @test voice_freq(Controls(:note => "a4")) ≈ 440.0 atol = 1e-6
        @test voice_freq(Controls(:n => "a4")) ≈ 440.0 atol = 1e-6
        @test voice_freq(Controls(:note => "a4", :speed => 2)) ≈ 880.0 atol = 1e-6
        @test voice_freq(Controls()) ≈ to_freq("c4")         # default pitch
        @test voice_freq(Controls(:s => "bd", :note => "a4")) == 0.0
        @test first(
            voice_stages(Controls(:s => "saw", :note => "a4", :speed => 2), 0.2)[1],
        ) == "osc \"saw\" @ 880.0 Hz"
    end

    @testset "voice stages" begin
        ctl = Controls(
            :s => "saw",
            :note => "c2",
            :gain => 0.5,
            :cutoff => 800,
            :hcutoff => 60,
            :shape => 0.3,
        )
        st = voice_stages(ctl, 0.4)
        names = first.(st)
        @test any(n -> startswith(n, "osc \"saw\""), names)
        @test "adsr envelope" in names
        @test "osc × envelope" in names
        @test any(n -> startswith(n, "lowpass"), names)
        @test any(n -> startswith(n, "highpass"), names)
        @test any(n -> startswith(n, "shape"), names)
        @test any(n -> startswith(n, "gain"), names)

        # The inspector must show exactly what the synth produces.
        @test last(st[end]) == render_voice(ctl, 0.4)
        @test all(length(b) == length(last(st[end])) for (_, b) in st)

        # Stages appear in the order the chain applies them, and only when used.
        plain = first.(voice_stages(Controls(:s => "sine", :note => "a4"), 0.2))
        @test plain ==
              ["osc \"sine\" @ 440.0 Hz", "adsr envelope", "osc × envelope", "gain 0.8"]

        drum = voice_stages(Controls(:s => "bd", :gain => 0.9), 0.25)
        @test first(drum[1]) == "drum \"bd\""
        @test last(drum[end]) == render_voice(Controls(:s => "bd", :gain => 0.9), 0.25)

        @test isempty(voice_stages(Controls(:s => "sine", :note => "bogus"), 0.2))
    end

    @testset "rendering" begin
        buf = render_cycles(m"bd sd hh*2" |> gain(0.8), 0, 2; cps = 0.5)
        @test size(buf, 2) == 2
        @test size(buf, 1) == round(Int, 2 / 0.5 * SAMPLERATE)
        @test maximum(abs, buf) > 0
        @test all(isfinite, buf)

        @test isempty(render_cycles(silence, 0, 0; cps = 0.5))

        # panning is honoured
        left = render_cycles(m"bd" |> pan(0.0), 0, 1; cps = 1.0)
        @test sum(abs, left[:, 1]) > sum(abs, left[:, 2])

        lim = limit!(fill(5.0, 10, 2))
        @test maximum(abs, lim) <= 0.95 + 1e-9
    end

    @testset "stems" begin
        tracks = [
            "bass" => note("c2 g2") |> sound("saw") |> gain(0.9),
            "keys" => note("c4 e4 g4") |> sound("tri") |> gain(0.9),
        ]
        stems = render_stems(tracks, 0, 2; cps = 0.5, tail = 2.0, wrap = true)
        @test first.(stems) == ["bass", "keys"]
        @test all(size(b, 2) == 2 for (_, b) in stems)

        # Summing the stems has to reproduce the limited mix, or the picture and
        # the sound disagree. (Only exact for voices that do not use noise.)
        mix = sum(last.(stems))
        ref = limit!(
            render_cycles(
                overlay(last.(tracks)...),
                0,
                2;
                cps = 0.5,
                tail = 2.0,
                wrap = true,
            ),
        )
        @test maximum(abs, mix .- ref) < 1e-12
        @test maximum(abs, mix) <= 0.95 + 1e-9

        # Unnamed tracks get positional names.
        @test first.(render_stems([m"bd", m"sd"], 0, 1; cps = 1.0)) ==
              ["track 1", "track 2"]
        @test isempty(render_stems([], 0, 1; cps = 1.0))
    end

    @testset "engine and sinks" begin
        e = Engine(m"bd sd"; cps = 0.5, sink = WebAudioSink(cycles = 2))
        @test !is_playing(e)
        set_bpm!(e, 120)
        @test e.cps[] ≈ 0.5
        set_cps!(e, 1.0)
        @test e.cps[] ≈ 1.0

        refresh!(e.sink, e)
        @test size(e.sink.buffer, 1) == round(Int, 2 / 1.0 * SAMPLERATE)
        @test e.sink.revision == 1

        set_pattern!(e, m"hh*4")
        refresh!(e.sink, e)
        @test e.sink.revision == 2

        il = Polyhymnia.interleaved(e.sink)
        @test length(il) == 2 * size(e.sink.buffer, 1)
        @test eltype(il) == Float32
    end

    @testset "wav export" begin
        buf = render_cycles(m"bd sd", 0, 1; cps = 1.0)
        bytes = wav_bytes(buf)
        @test String(bytes[1:4]) == "RIFF"
        @test String(bytes[9:12]) == "WAVE"
        @test length(bytes) == 44 + size(buf, 1) * 4

        # A vector encodes as mono: half the bytes, one channel in the header.
        mono = wav_bytes(view(buf, :, 1))
        @test length(mono) == 44 + size(buf, 1) * 2
        @test reinterpret(UInt16, mono[23:24])[1] == 1
        @test reinterpret(UInt16, bytes[23:24])[1] == 2
    end

    @testset "packaging" begin
        # The point of the split: `using Polyhymnia` must not drag in Pluto.
        # Nothing in src/ imports it — the widgets return `Base.HTML`, which any
        # text/html renderer displays — so a second frontend costs nothing here.
        root = joinpath(@__DIR__, "..")
        deps = TOML.parsefile(joinpath(root, "Project.toml"))["deps"]
        for pkg in ("Pluto", "PlutoUI", "AbstractPlutoDingetjes")
            @test !haskey(deps, pkg)
        end
        for f in readdir(joinpath(root, "src"); join = true)
            src = read(f, String)
            @test !occursin(r"^\s*(using|import)\s+.*Pluto"m, src)
        end
        # ...and the notebook environment is where it went.
        nb = TOML.parsefile(joinpath(root, "notebooks", "Project.toml"))
        @test haskey(nb["deps"], "Pluto")
        @test nb["sources"]["Polyhymnia"]["path"] == ".."
    end

    @testset "notebook helpers" begin
        # These return HTML; assert they render without error and mention the basics.
        html = repr("text/html", pattern_plot(m"bd sd hh", cycles = 2))
        @test occursin("svg", html)
        @test occursin("bd", html)
        @test occursin("(silence)", repr("text/html", pattern_plot(silence)))

        e = Engine(m"bd"; cps = 1.0, sink = WebAudioSink(cycles = 1))
        @test occursin("data:audio/wav;base64,", repr("text/html", webaudio(e)))
        @test occursin("cps", repr("text/html", transport(e)))

        # peaks bracket the signal they summarise
        mins, maxs = peaks(sin.(range(0, 8π, length = 5000)), 40)
        @test length(mins) == length(maxs) == 40
        @test all(mins .<= maxs)
        @test maximum(maxs) ≈ 1.0 atol = 0.01
        @test peaks(Float64[], 8) == (zeros(8), zeros(8))

        chain = repr(
            "text/html",
            signal_chain(note("c3 e3") |> sound("saw") |> gain(0.4); cps = 1.0),
        )
        @test occursin("osc &quot;saw&quot;", chain)
        @test occursin("gain 0.4", chain)
        @test occursin("event 1/2 of cycle 0", chain)
        # out-of-range picks clamp rather than throw
        @test occursin("event 2/2", repr("text/html", signal_chain(m"bd sd"; event = 9)))
        @test occursin("no events", repr("text/html", signal_chain(silence)))

        sc = repr(
            "text/html",
            scope(e, ["drums" => m"bd sd", "hats" => m"hh*4"]; cycles = 1),
        )
        @test occursin("data:audio/wav;base64,", sc)
        @test occursin("drums", sc) && occursin("hats", sc)
        @test occursin("2 tracks", sc)
        @test occursin("(no tracks)", repr("text/html", scope(e, [])))
        # the engine follows what the scope is playing
        @test length(query_cycle(e.pattern[], 0)) == 6
    end
end
