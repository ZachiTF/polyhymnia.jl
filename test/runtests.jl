using Test
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
    end
end
