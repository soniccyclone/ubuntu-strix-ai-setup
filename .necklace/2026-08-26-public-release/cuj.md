# CUJ document: Make the repository publishable

Derived from `spec.md` in this directory. One CUJ per actor-outcome pair.

Test files follow the existing convention: bats, one file per CUJ, prose test
names. The first cycle used `NN-`, the media cycle used `mNN-`; this one uses
`rNN-`.

Two of these need `dolt` on `PATH`. It is a single static binary installed
user-level and belongs in `make setup` alongside the bats, jq and podman
checks, because a history assertion that silently skips is worse than no
assertion.

---

## CUJ-01: Stranger clones onto a machine laid out differently and reaches a working contract

**Actor:** a stranger who finds the repository and wants to run it
**Trigger:** they clone it to a path that is not `~/code-stuff`, with weights on a second disk
**Journey:**

1. Stranger runs the setup command.
2. Setup writes a gitignored `.env` carrying the paths it detected, and says so.
3. Stranger edits `MODELS=` in `.env` to point at their second disk.
4. Stranger re-runs setup.
5. Setup leaves their edit alone, derives the serving overlay from it, and installs the unit.
6. The contract starts and loads weights from the second disk.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `setup writes .env once and never overwrites an edit` | run the generator, replace `MODELS=` with a sentinel, run it again | after the second run the sentinel is still there | REPL: `env-to-overlay.sh` — a value typed once has to survive every later run, which the environment-variable design did not give it |
| `a models path set only in .env reaches the launched process` | `.env` naming a directory that is not `$HOME/models` | the process launched by llama-swap receives that directory in its argv | REPL: `env-to-overlay.sh` — `ARGV=/srv/user-edited-this/weights.gguf-5800` |
| `no tracked file contains a literal home directory` | the tracked file list | zero matches for `/home/<anything>`; `%h` and `$HOME` are permitted | REPL: the grep that started this cycle found 11 across 6 files |
| `.env is ignored by git` | a `.env` containing a sentinel | `git status --porcelain` does not mention it and `git check-ignore` does | |

**Done when:** the four tests above pass. All must be red when created.

**Beads:**

---

## CUJ-02: Stranger runs a tracked config without its overlay and is told exactly what is missing

**Actor:** a stranger who finds the repository and wants to run it
**Trigger:** they run llama-swap against a tracked config directly, before running setup
**Journey:**

1. Stranger points llama-swap at `config/llama-swap-kairic.yaml` on its own.
2. llama-swap refuses to start and names the value that is not defined.
3. Stranger runs setup, which creates that value, and the same command works.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the tracked contract refuses to load without the machine overlay` | each tracked llama-swap config, passed alone | llama-swap exits nonzero and starts no model | REPL: `env-to-overlay.sh` — `error="model probe env: unknown macro '${opt}'"` |
| `the refusal names the missing value` | the same invocation | the error text contains `unknown macro` and the macro's name | REPL: `envexpand.sh` — llama-swap hard-errors on undeclared names rather than passing them through |
| `the same config loads once the overlay is present` | tracked config plus a generated overlay | llama-swap starts and `/v1/models` lists the expected roles | REPL: `macro-overlay.sh` — `-config` and `-config-dir` are additive |

**Done when:** the three tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:**

---

## CUJ-03: Stranger who wants to reuse a piece of it learns what they may do

**Actor:** a stranger who wants to reuse part of it in their own work
**Trigger:** they open the repository root intending to copy the isolation harness into their own project
**Journey:**

1. Stranger sees a LICENSE at the root and a licence line in the README.
2. Stranger checks whether the parts that are not Nathan's are covered by it.
3. Stranger finds the beads-generated content identified with its own terms.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `LICENSE is Apache-2.0 with the copyright line completed` | the LICENSE file | contains `Apache License`, `Version 2.0`, and a filled `Copyright <year> <name>` line rather than the template placeholder | REPL: `soniccyclone/necklace` fills the appendix as `Copyright 2026 Nathan Barlow` |
| `the README states the terms` | the README | carries a licence section naming Apache-2.0 and linking LICENSE | REPL: necklace's README does this in three lines |
| `content that is not ours is identified with its own licence` | the beads-generated hooks and instruction blocks | a tracked file names beads as the origin and MIT as its terms | REPL: `@beads/bd` ships MIT, "Beads Contributors" |

**Done when:** the three tests above pass. All must be red when created.

**Beads:**

---

## CUJ-04: Stranger arriving from the benchmark traces each number to the upstream that produced it

**Actor:** a stranger reading the headline throughput comparison
**Trigger:** they want to reproduce the 41.89 against 22.21 figures, or check who wrote each engine
**Journey:**

1. Stranger reads the comparison in the README.
2. For each engine named, they find the upstream repository it was built from.
3. They learn the two are different people's forks kept apart deliberately, without opening a container definition.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every engine in the headline comparison names its upstream` | the documentation carrying the comparison | each engine in the table resolves to a repository URL in tracked documentation | REPL: both URLs currently appear only inside `harness/Containerfile.*` |
| `the two engines are recorded as separate forks on purpose` | the same documentation | states that the Kairic and ROCmFPX images come from different forks and why they are not shared | REPL: `Containerfile.kairic:3-6` already explains it, in a file nobody browsing the numbers opens |
| `the upstream a Containerfile clones matches the one documented` | each `harness/Containerfile.*` that clones an engine | the cloned URL appears in the documentation for that engine | |

**Done when:** the three tests above pass. All must be red when created.

**Beads:**

---

## CUJ-05: Nathan sees what every published ref carries before the repository is public

**Actor:** Nathan
**Trigger:** he is about to flip visibility and wants the publication surface enumerated rather than discovered
**Journey:**

1. Nathan runs one command.
2. It lists every ref the remote carries, including the ones git created on beads' behalf.
3. It reports what each ref holds and flags any ref not on the recorded list.
4. Nathan reads the record of what the surface is intended to be and confirms it matches.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the publication surface is recorded` | tracked documentation | names every ref the remote carries and what each one holds | REPL: `git ls-remote` shows `refs/dolt/data` and `refs/heads/__dolt_remote_info__` beside `master` |
| `the audit flags a ref that is not on the record` | a ref list with one unrecorded entry injected | the audit exits nonzero and names the unrecorded ref | |
| `the issue database carries no credentials` | the dolt `config` and `metadata` tables | no row whose key or value matches a credential pattern | REPL: `config` holds only compaction settings; beads warns `linear.api_key` and `github.token` can live there |

**Done when:** the three tests above pass. All must be red when created.

**Beads:**

---

## CUJ-06: The defect analysis is gone from the working tree and from both histories

**Actor:** the third-party project whose defect was analysed
**Trigger:** the repository becomes public and anyone can clone every ref
**Journey:**

1. The issue is deleted and the export regenerated.
2. Git history is rewritten from the first commit that carried it.
3. The issue database history is rewritten to drop it from all of its versions.
4. Beads still syncs, and the issue count is unchanged apart from the one removed.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the defect analysis is absent from the working tree` | the tracked file list | zero matches for the defect wording | REPL: it currently appears in exactly one path, `.beads/issues.jsonl` |
| `the defect analysis is absent from every commit on every ref` | every commit reachable from every ref | zero commits whose tree contains the wording | REPL: carried by 40 commits, from `7b0c5cc` (#78 of 117) to HEAD |
| `the defect analysis is absent from every version in the issue database` | `dolt_history_issues` across all commits | zero rows matching the wording | REPL: presently 10 versions; editing the issue would have written an 11th |
| `beads still syncs after the rewrite` | the rewritten database | `bd` exports and re-imports without error and reports the expected issue count | REPL risk: git and dolt reference each other through `refs/dolt/data`, so the two rewrites must be verified together |

**Done when:** the four tests above pass. All must be red when created.

**Depends on:** CUJ-05

**Beads:**

---

## CUJ-07: Stranger auditing the security posture finds no tracked file contradicting itself

**Actor:** a stranger auditing it before running it on their own machine
**Trigger:** they read the contract configuration's header to find out what it binds
**Journey:**

1. Stranger reads the comment describing the bind address and network posture.
2. They compare it against the flags the same file passes.
3. They compare it against the document that comment cites.
4. All three agree.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `a contract config's stated bind address matches the one it passes` | each tracked llama-swap config | the address named in its comments equals the value of its `--host` flag | REPL: `llama-swap.yaml` claims `0.0.0.0`, passes `--host 127.0.0.1` |
| `no tracked file claims a firewall is required` | the tracked file list | nothing asserts a firewall rule is needed | REPL: `docs/privileged-steps.md` §3 records that design as abandoned and unnecessary |
| `the isolation tests still prove the binding directly` | the existing isolation suite | it asserts the listening address rather than inferring it from a refused connection | REPL: the existing suite already does this; the test pins it against regression |

**Done when:** the three tests above pass. All must be red when created.

**Beads:**

---

## CUJ-08: Stranger reading the front matter finds claims that are still true

**Actor:** Nathan, and any stranger who reads the repository's own description of itself
**Trigger:** they read the README's claims and the agent-instruction files
**Journey:**

1. Stranger reads the README's stated suite count and checks it against the tests directory.
2. Stranger opens the agent-instruction file and finds no unfilled template prompts.
3. Stranger finds it pointing at the README, `make help` and the operations guide rather than restating them.
4. Nathan sets the repository description by hand. It is GitHub metadata rather than a tracked file, so no test covers it.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every suite count the README states matches the suites present` | the README and `tests/*.bats` | every stated count equals the file count | REPL: the README states it twice, at lines 105 and 119, and both are currently 17 — a test checking one would pass while the other rotted |
| `the agent-instruction files carry no unfilled template prompts` | `CLAUDE.md` and `AGENTS.md` | zero occurrences of the `_Add ..._` placeholder form | REPL: three in `CLAUDE.md`, and only two of them end in `here_` — matching the narrower form would leave one behind |
| `the agent-instruction files point at the documentation rather than restating it` | the same two files | each section that replaced a stub names an existing file or command as its authority | |
| `CLAUDE.md and AGENTS.md do not disagree` | both files | their substantive sections match, per the beads note that they are independent files needing mirrored edits | |

**Done when:** the four tests above pass. All must be red when created.

**Beads:**

---

<!--
Checks before finishing.

  Every actor-outcome pair in spec.md has a CUJ: eight pairs, eight CUJs.
  Every CUJ has a test table with real inputs and single observable assertions.
  Every "Done when" names tests and nothing else.
  Dependencies are sparse: CUJ-02 on CUJ-01, CUJ-06 on CUJ-05, nothing else.

  CUJ-08's suite-count test is deliberately self-consistency rather than a
  fixed number, so it does not have to be ordered after the CUJs that add test
  files.

  The repository description is step 4 of CUJ-08's journey and deliberately has
  no test row. It is GitHub metadata rather than a tracked file, and asserting
  it would need a network round trip to prove something a human sets once.
-->
