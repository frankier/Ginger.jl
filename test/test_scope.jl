using Test
using Ginger

const G = Ginger

module ScopeHost
    export hostfn
    hostfn(x) = x
    const HOSTCONST = 1
end

vars(str, mod) = G.context_vars(Meta.parseall(str), mod)

@testset "scope: inference" begin
    @test vars("hostfn(HOSTCONST) + z", ScopeHost) == [:z]
    @test vars("q = 1\nq + r", Main) == [:r]
    @test vars("for item in items\n    item\nend", Main) == [:items]
    @test vars("let a = b\n    a + c\nend", Main) == [:b, :c]
    @test vars("map(x -> x + y, xs)", Main) == [:xs, :y]
    @test vars("[i * s for i in v]", Main) == [:s, :v]
    @test vars("f(a = d) = a + e", Main) == [:d, :e]
    @test vars("function g(u)\n    u + w\nend", Main) == [:w]
    @test vars("if flag\n    thenval\nelse\n    elseval\nend", Main) == [:elseval, :flag, :thenval]
    @test vars("begin\n    local z = 1\n    z + q\nend", Main) == [:q]
    @test vars("try\n    risky()\ncatch e\n    log(e)\nend", Main) == [:risky]
    @test vars("try\n    risky()\ncatch e\n    log(e)\nelse\n    ok()\nfinally\n    cleanup()\nend", Main) == [:cleanup, :ok, :risky]
end
