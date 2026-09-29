# Benchmarks for Ginger.jl.
#
# Run with:
#
#     julia --project=benchmark benchmark/benchmarks.jl
#
# The suite compares Ginger against OteraEngine and hand-written string
# interpolation for three shapes: a text-heavy page, a loop-heavy list, and an
# inheritance-heavy page. OteraEngine compiles at runtime, so its `Template`
# objects are built once, outside the measured loop.
#
# The hand-written baseline interpolates values directly and does not escape
# them, so it is a floor for the rendering overhead rather than a like-for-like
# secure comparison.

using BenchmarkTools
using Ginger
import OteraEngine

const TEMPLATE_DIR = joinpath(@__DIR__, "templates")

module GingerBench
    using Ginger
    @templates "templates" as TPL
end

# --- fixtures ---------------------------------------------------------------

const TITLE = "Benchmark"
const HEADING = "A heading"
const BODY = "Some body text with a <tag> to escape."
const ITEMS = ["alpha", "beta", "gamma", "delta", "epsilon"]

# --- hand-written baselines -------------------------------------------------

function handwritten_text(title, heading, body)
    return string(
        "<!DOCTYPE html>\n<html><head><title>", title, "</title></head><body>\n",
        "<article><h1>", heading, "</h1><p>", body, "</p></article>\n</body></html>\n",
    )
end

function handwritten_loop(items)
    io = IOBuffer()
    print(io, "<ul>")
    for item in items
        print(io, "<li>", item, "</li>")
    end
    print(io, "</ul>")
    return String(take!(io))
end

function handwritten_page(title, items)
    io = IOBuffer()
    print(io, "<html><body><h1>", title, "</h1>")
    for item in items
        print(io, "<p>", item, "</p>")
    end
    print(io, "</body></html>")
    return String(take!(io))
end

# --- OteraEngine fixtures (compiled once) -----------------------------------

const OTERA_TEXT = OteraEngine.Template(joinpath(TEMPLATE_DIR, "text.html"))
const OTERA_LOOP = OteraEngine.Template(joinpath(TEMPLATE_DIR, "loop.html"))
const OTERA_PAGE = OteraEngine.Template(joinpath(TEMPLATE_DIR, "page.html"))

# --- suite ------------------------------------------------------------------

const SUITE = BenchmarkGroup()

SUITE["text"]["ginger"] = @benchmarkable render(GingerBench.TPL.text; title = $TITLE, heading = $HEADING, body = $BODY)
SUITE["text"]["otera"] = @benchmarkable $OTERA_TEXT(init = Dict(:title => $TITLE, :heading => $HEADING, :body => $BODY))
SUITE["text"]["handwritten"] = @benchmarkable handwritten_text($TITLE, $HEADING, $BODY)

SUITE["loop"]["ginger"] = @benchmarkable render(GingerBench.TPL.loop; items = $ITEMS)
SUITE["loop"]["otera"] = @benchmarkable $OTERA_LOOP(init = Dict(:items => $ITEMS))
SUITE["loop"]["handwritten"] = @benchmarkable handwritten_loop($ITEMS)

SUITE["inheritance"]["ginger"] = @benchmarkable render(GingerBench.TPL.page; title = $TITLE, items = $ITEMS)
SUITE["inheritance"]["otera"] = @benchmarkable $OTERA_PAGE(init = Dict(:title => $TITLE, :items => $ITEMS))
SUITE["inheritance"]["handwritten"] = @benchmarkable handwritten_page($TITLE, $ITEMS)

# --- reporting --------------------------------------------------------------

function report()
    results = run(SUITE)
    for (group, benchmarks) in results
        println("\n== ", group, " ==")
        base = minimum(benchmarks["handwritten"]).time
        for (name, trial) in benchmarks
            est = minimum(trial)
            ratio = round(est.time / base; digits = 2)
            println(
                rpad(name, 14), lpad(round(est.time; digits = 1), 12), " ns   ",
                lpad(est.allocs, 6), " allocs   ", ratio, "x handwritten",
            )
        end
    end
    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    report()
end
