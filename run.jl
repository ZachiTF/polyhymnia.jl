#!/usr/bin/env julia
# Launch a Polyhymnia notebook.
#
#   julia --project=. run.jl                  # opens notebooks/polyhymnia.jl
#   julia --project=. run.jl scales           # opens notebooks/scales.jl
#   julia --project=. run.jl path/to/nb.jl    # opens an explicit path
#
# Opens Pluto on the live-coding page. Pass --no-browser to only print the URL.

import Pkg
Pkg.activate(@__DIR__)

# Instantiate on first run so a fresh clone just works. Euterpe is unregistered
# and pinned in Project.toml's [sources], so this resolves without a Manifest.
try
    Pkg.instantiate()
catch err
    @warn "Pkg.instantiate() failed; continuing with the existing environment" exception =
        err
end

import Pluto

const NOTEBOOK_DIR = joinpath(@__DIR__, "notebooks")
const DEFAULT_NOTEBOOK = "polyhymnia"

notebook_names() =
    sort([first(splitext(f)) for f in readdir(NOTEBOOK_DIR) if endswith(f, ".jl")])

"""
Resolve `name` to a notebook path: an explicit path if one exists, otherwise a
name looked up in `notebooks/`, with or without the `.jl` extension.
"""
function find_notebook(name)
    candidates = (name, joinpath(NOTEBOOK_DIR, name), joinpath(NOTEBOOK_DIR, name * ".jl"))
    for candidate in candidates
        isfile(candidate) && return candidate
    end
    error("""
    no notebook matching "$name".
    Available in notebooks/: $(join(notebook_names(), ", "))
    """)
end

# Anything that is not a flag names the notebook to open.
selected = filter(a -> !startswith(a, "-"), ARGS)
length(selected) <= 1 ||
    error("expected at most one notebook, got: $(join(selected, ", "))")
notebook = find_notebook(isempty(selected) ? DEFAULT_NOTEBOOK : only(selected))

# Note: the ALSA/WSLg setup PortAudio needs happens inside the notebook process,
# via `ensure_alsa_config!` in `default_sink()` and `start!`.

# Pluto's default security (a secret token in the URL) is left on deliberately.
# Disabling it would let any website you visit reach this server on localhost and
# run code on your machine. The launcher opens the URL with the token for you;
# with --no-browser, the token is in the URL printed below.
Pluto.run(notebook = notebook, launch_browser = !("--no-browser" in ARGS))
