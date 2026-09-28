using Test
using Pkg

const GINGER_ROOT = dirname(@__DIR__)
const PROBE_ROOT = joinpath(@__DIR__, "precompile_probe")

# `JULIA_DEPOT_PATH` entries are separated by `;` on Windows and `:` elsewhere.
const _DEPOT_SEP = Sys.iswindows() ? ';' : ':'

# Run `code` in a fresh Julia process against `project`, with `depot` first on the
# depot path. `debug_loading` turns on the `loading` log group so the
# "Precompiling <pkg>" message is visible in a non-interactive process.
function _probe_run(project, depot, code; debug_loading = false)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $code`
    env = copy(ENV)
    default_depot = get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia"))
    env["JULIA_DEPOT_PATH"] = string(depot, _DEPOT_SEP, default_depot)
    # `Pkg.test` may set these for the parent process; clear them so the
    # subprocess uses the `--project` we pass.
    delete!(env, "JULIA_LOAD_PATH")
    delete!(env, "JULIA_PROJECT")
    debug_loading ? (env["JULIA_DEBUG"] = "loading") : delete!(env, "JULIA_DEBUG")
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(setenv(cmd, env); stdout = out, stderr = err); wait = true)
    return proc.exitcode, String(take!(out)), String(take!(err))
end

@testset "precompilation probe" begin
    mktempdir() do tmp
        probe = joinpath(tmp, "PrecompileProbe")
        cp(PROBE_ROOT, probe)
        env = joinpath(tmp, "env")
        depot = joinpath(tmp, "depot")
        mkpath(env)
        mkpath(depot)

        setup = """
        using Pkg
        Pkg.activate($(repr(env)))
        Pkg.develop(path = $(repr(GINGER_ROOT)))
        Pkg.develop(path = $(repr(probe)))
        Pkg.precompile()
        """
        code, out, err = _probe_run(env, depot, setup)
        @test code == 0
        code == 0 || @info "probe setup failed" out err

        # A second load must not recompile: `include_dependency` recorded the
        # template files and directories during the first expansion.
        code, out, err = _probe_run(
            env, depot,
            "using PrecompileProbe, Ginger; println(render(TPL.page; who = \"frank\"))";
            debug_loading = true,
        )
        @test code == 0
        @test occursin("Hello frank!", out)
        @test !occursin("Precompiling PrecompileProbe", err)

        # Editing a template marks the package stale, so the next load recompiles
        # and the new output is visible.
        write(
            joinpath(probe, "src", "templates", "page.html"),
            "{% extends \"base.html\" %}{% block content %}Hi {{ who }}!{% endblock %}\n",
        )
        sleep(1.1)
        code, out, err = _probe_run(
            env, depot,
            "using PrecompileProbe, Ginger; println(render(TPL.page; who = \"frank\"))";
            debug_loading = true,
        )
        @test code == 0
        @test occursin("Hi frank!", out)
        @test occursin("Precompiling PrecompileProbe", err)

        # Adding a template marks the package stale too, and the new template is
        # discovered and bound on the next load.
        write(joinpath(probe, "src", "templates", "added.html"), "added {{ x }}\n")
        sleep(1.1)
        code, out, err = _probe_run(
            env, depot,
            "using PrecompileProbe, Ginger; println(render(TPL.added; x = \"yes\"))";
            debug_loading = true,
        )
        @test code == 0
        @test occursin("added yes", out)
        @test occursin("Precompiling PrecompileProbe", err)
    end
end
