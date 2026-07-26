# Verify the tracked Julia sources are formatted, mirroring the julia-formatter
# pre-commit hook for contributors who have not installed the hooks.
#
#   julia --project=.ci .ci/format_check.jl

import Pkg
Pkg.instantiate()

using JuliaFormatter

# `notebooks/` is excluded via .JuliaFormatter.toml; see the note there.
const TARGETS = ["src", "test", ".ci", "run.jl"]

if format(TARGETS; overwrite = false)
    println("All files are formatted.")
else
    @error """
    Formatting check failed. From the repository root, run:

        julia -e 'using JuliaFormatter; format(["src", "test", "run.jl"])'
    """
    exit(1)
end
