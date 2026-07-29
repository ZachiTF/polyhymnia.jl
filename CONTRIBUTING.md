# Contributing to Polyhymnia.jl

## Setup

Polyhymnia needs **Julia 1.11 or newer** — `Project.toml` pins the unregistered
Euterpe dependency through a `[sources]` entry, which is a 1.11 feature.

```bash
git clone <this repo> && cd polyhymnia.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'   # the package
julia run.jl                                          # or just this: it
                                                      # instantiates notebooks/
```

Then install the hooks, once per clone:

```bash
pip install pre-commit                            # or: pipx install pre-commit
pre-commit install                                # pre-commit + commit-msg hooks
julia -e 'using Pkg; Pkg.add("JuliaFormatter")'   # the formatter hook is `language: system`
```

The first `instantiate` takes a while: Euterpe depends on
`DifferentialEquations` and `ModelingToolkit`.

## Branching

`main` is meant to stay green. Work happens on short-lived branches off `main`
and lands through a pull request.

```
feat/euclid-rotation      fix/pan-mono-buffers      docs/mini-notation-table
chore/bump-euterpe        refactor/sink-interface   test/engine-cycles
```

Pull requests are **merged, not squashed** — the squash button is switched off
in the repository settings. A branch arrives on `main` with its commits intact,
under a merge commit.

That is a deliberate trade. `main` no longer reads as one commit per change, but
a branch that did three separable things stays three commits, each one
reviewable, revertable and bisectable on its own. The cost is that **every
commit on the branch lands on `main`**, so every commit subject has to be right
— not just the pull request title. See the commit convention below.

In return, please shape the branch before opening it: one commit per coherent
change, no "fix typo" or "address review" commits left in the history. Rebase
and amend freely while the branch is yours.

## Commits

[Conventional Commits](https://www.conventionalcommits.org) on **every** commit,
not only the pull request title, since merging preserves them all. The
`commit-msg` hook enforces this locally:

```
<type>[optional scope]: <description>

feat(mininotation): support polymetric subsequences
fix(voices): clamp bd envelope so it cannot exceed unity
chore: bump Euterpe to 8ccee3c
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `revert`. Breaking changes get a `!` before the colon.

## What runs, and where

The hooks are deliberately fast — formatting, whitespace, TOML/YAML validity, a
large-file guard. **The test suite is not in the hooks**: `using Polyhymnia`
loads Euterpe's `ModelingToolkit` stack, which takes minutes. Run tests
yourself before opening a PR, and let CI be the gate:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

To format without committing:

```bash
julia -e 'using JuliaFormatter; format(["src", "test", "run.jl"])'
```

## Notebooks

`notebooks/` holds runnable examples, and its own `Project.toml`: the notebook
stack (Pluto, PlutoUI) is *not* a dependency of the package. Nothing in `src/`
imports Pluto — the widgets return `Base.HTML`, which any `text/html` renderer
displays — so the library stays usable from a plain script, a server, or a
different notebook system. Polyhymnia comes into that environment as a path
dependency, which carries the Euterpe pin from `../Project.toml` with it.

A test asserts the split holds, so adding `using Pluto` to `src/` fails CI
rather than quietly re-coupling the two.

`run.jl` activates `notebooks/` itself and takes the notebook to open, so
adding one costs nothing:

```bash
julia run.jl            # notebooks/polyhymnia.jl, the default
julia run.jl scales     # notebooks/scales.jl
```

Two rules, both because Pluto owns the exact bytes of these files:

1. **Never hand-edit or hand-merge a notebook.** Pluto rewrites cell UUIDs and
   the trailing `# ╔═╡ Cell order:` block on every save, so a textual merge can
   produce a file that parses but whose cell order is silently wrong.
   `.gitattributes` marks `notebooks/*.jl` as unmergeable so conflicts fail
   loudly. Resolve one by picking a side, opening it in Pluto, and re-saving.
2. **Notebook changes go in their own commit**, so a conflict never forces you
   to redo source changes as well.

The formatter skips `notebooks/` for the same reason — see
`.JuliaFormatter.toml`.

Never commit rendered audio. `*.wav` is gitignored and a hook rejects anything
over 512 KB.

## Where the pattern language comes from

Polyhymnia is MIT. TidalCycles is GPL-3.0 and Strudel is AGPL-3.0, so **do not
copy, port, or transliterate code from either into this repository** — that
would make Polyhymnia a derivative work and the licence a lie. This is not
hypothetical: it is easy to do accidentally, and easy for an AI assistant to do
on your behalf.

The line to hold:

- **Fine, and the point of the project:** matching the *vocabulary a musician
  types* — `fast`, `slow`, `rev`, `every`, `euclid`, control names like `gain`
  and `cutoff`, and the mini-notation. Reading Tidal's or Strudel's *user
  documentation* to learn what a function should do is fine. So is implementing
  a published algorithm from its paper.
- **Not fine:** reproducing their internal structure — private helper names,
  function decomposition, the shape of a particular algorithm's implementation.
  Names like `Hap`, `sam`, `spanCycles`, `appLeft` or `fastGap` are Strudel and
  Tidal internals; if one appears in a diff, something has gone wrong.

If you are unsure whether a contribution crosses the line, say so in the PR
rather than guessing. See "Prior art, and what this is not" in the README.

## Upgrading Euterpe

Euterpe is not in the General registry, so it is pinned by commit in
`Project.toml`:

```toml
[sources]
Euterpe = {url = "https://github.com/SquidSinker/Euterpe.jl", rev = "8ccee3c9..."}
```

That is the whole lockfile — there is no committed `Manifest.toml`. To move to
a newer Euterpe, change `rev` to the new **commit** SHA (not the
`git-tree-sha1` the Manifest reports), re-instantiate, run the tests, and open
that as its own `chore:` PR so the upgrade is reviewable in isolation.

Note that `Pkg` rewrites `Project.toml` when it resolves and will drop the
explanatory comments around `[sources]`. If that happens, put them back.
