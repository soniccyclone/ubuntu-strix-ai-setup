# CUJ document: A local Claude suite on Strix Halo

Derived from `spec.md` in this directory. One CUJ per actor-outcome pair.

**Test convention.** The repository has no tests today, so this establishes one.
Tests are `bats-core` files at `tests/NN-<slice>.bats`, run by `make test`.
`bats` installs user-level with `npm i -g bats` (1.13.0, no root); `jq` is
already at `/usr/bin/jq`. Every test is an integration test against a running
system.

**The test harness is containerised; the delivered system is not.** Every agent
and every test runs in a rootless podman container with **no host filesystem
mounted**, so nothing being evaluated can see Nathan's files. Verified today: a
rootless container reaches a bare-metal service at `host.containers.internal`
and reports an empty `/home`. Workspaces are podman named volumes, inspected by
attaching another container to the same volume — nothing is copied out to the
host.

The contract itself runs on **bare metal**, where the GPU and the weights are.
Containers reach it over the network and hold no model weights.

The journeys describe Nathan using **native desktop applications**, which is how
he will actually use them. Tests exercise the plumbing through containerised CLI
and web builds.

**What is tested, and what is not.** An automated test cannot tell whether a
tool is any good. Nathan validates that himself by using it, against his own
taste, which is the only standard that matters here. So the tests below are
deliberately small and mechanical: does it start, does it connect, is the config
where it is supposed to be, and did anything escape the container.

Rigor goes where failure is **silent**. A bad edit or an ugly layout announces
itself in seconds and needs no test. An agent reaching the host filesystem, or
the contract binding to the LAN, is invisible until it matters — so CUJ-09 is
tested hard and everything else gets a smoke test.

**This necklace is complete when the tests pass and the suite is ready to hand
over.** UAT comes after that, not inside it. Every CUJ carries a **UAT covers**
line describing what Nathan will judge once it is in his hands — that is a
handoff note, not a completion criterion, and nothing in this document waits on
it. Whatever he finds in UAT becomes its own necklace: `necklace-tweak` for
small corrections, a new cycle for anything larger.

---

## CUJ-01: Nathan finishes a real coding task at the terminal, on a local model

**Actor:** Nathan at a terminal, writing code
**Trigger:** He has a change to make and does not want it leaving the machine.
**Journey:**
1. Nathan starts the serving contract on bare metal, listening on one port.
2. Nathan runs opencode in a project directory.
3. Nathan describes a change and opencode reads, edits, and runs a command.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `contract answers both API shapes on one port` | the same prompt to `/v1/chat/completions` and to `/v1/messages` | both return a completion; neither 404s | llama-swap documents both; opencode speaks one and OpenPencil can speak the other |
| `opencode reaches the contract and completes one tool call` | opencode in a container, pointed at the contract, asked to read one file in its volume | the file's contents appear in the response and the run exits 0 | this is a smoke test for the wiring, not a judgement of the agent |

**UAT covers:** whether the model is actually useful for his work — whether it holds
a multi-turn loop, makes edits he would keep, and is fast enough to stay in.

**Done when:** the two tests above pass. Both must be red when created.

**Beads:** ubuntu-strix-ai-setup-e20 (epic), e20.1 llama-swap on metal, e20.2 opencode container — all closed

---

## CUJ-02: Nathan reorganises a folder of documents without opening a terminal

**Actor:** Nathan in a GUI, working on files and documents
**Trigger:** A directory of files needs sorting, renaming, and summarising.
**Journey:**
1. Nathan opens the desktop agent and nominates one folder as its workspace.
2. He describes the outcome he wants; it proposes a destructive step and waits.
3. He approves, and it finishes and reports what changed.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `agent runs from environment configuration alone` | `ghcr.io/aaif-goose/goose` given only a provider, a base URL and a role name | a request arrives at the contract naming that role; no model path appears in its config | REPL: goose's published image is configured entirely by environment variables |
| `agent writes nothing outside its workspace volume` | a task whose wording invites writing to a sibling path outside the workspace | no path outside the volume is created or modified | the container makes a failure survivable; this is the one failure mode worth catching mechanically |

**UAT covers:** whether a GUI agent on a local model is pleasant enough to reach for
instead of a terminal, and whether its confirmation prompts land in the right places.

**Done when:** the two tests above pass. Both must be red when created.

**Depends on:** CUJ-01

**Beads:** ubuntu-strix-ai-setup-4sk — all closed

---

## CUJ-03: Nathan takes a described design to an editable document and back to code

**Actor:** Nathan designing something visual
**Trigger:** He wants a screen laid out and eventually wants it as markup.
**Journey:**
1. Nathan opens the design tool and points its AI at the contract.
2. He describes a screen, adjusts a node by hand, exports it as JSX or HTML.
3. He edits that markup, imports it back, and it is editable again.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `web build reaches the contract on the OpenAI shape` | OpenPencil's web build in a container with a base URL and a role name | a request arrives at the contract and a response returns | REPL: `compatible.ts` takes a `baseURL` for both adapters, but the browser build fails CORS on the *Anthropic* shape while the Tauri build does not. Nathan's native app may use either; this covers only one |
| `export and reimport preserves node count and text` | `@open-pencil/cli` in a container: `export -f html --css tailwind`, then `import` | the reimported document has the same node count and the same text content | the round-trip is what replaces Claude Design's handoff, and the CLI exercises it without a display |

**UAT covers:** whether a local model can produce a layout worth editing rather than
worth deleting, and whether the round-trip preserves anything he cares about.

**Done when:** the two tests above pass. Both must be red when created.

**Depends on:** CUJ-01

**Beads:** ubuntu-strix-ai-setup-v9k — all closed

---

## CUJ-04: Nathan changes which model backs a role by editing one file

**Actor:** Nathan, any leg
**Trigger:** A benchmark says a different file should serve the `deep` role.
**Journey:**
1. Nathan edits the roster, points `deep` at a different file, reloads the contract.
2. The next request from an unchanged frontend is served by the new file.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `repointing a role changes what serves it` | the `deep` entry switched from the 122B to the 35B, contract reloaded | the next `deep` request is served by a process whose command line names the 35B file, and no frontend config file changed | the spec makes the roster the only place a model choice lives |
| `an unknown role fails loudly` | a request naming a role absent from the roster | a 4xx naming the unknown role; no fallback model is loaded | fail fast over fail silently |
| `an idle role releases its memory` | two roles requested in turn that do not fit together, with a TTL shorter than the gap | GTT in use falls after the TTL and the second request succeeds | REPL: 108.3 GiB free; 69.10 + 20.74 GiB fits, larger pairs will not |

**UAT covers:** whether swapping a model is quick enough in practice that he actually
does it rather than living with the wrong one.

**Done when:** the three tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:** ubuntu-strix-ai-setup-y8z — all closed

---

## CUJ-05: Nathan asks a question about an image

**Actor:** Nathan, any leg
**Trigger:** He has a screenshot and a question about it.
**Journey:**
1. Nathan attaches the image in whichever frontend he is using.
2. The answer refers to what is actually in the image.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `vision role reads a word out of an image` | a generated PNG containing one specific short word in large type | the response contains that word | a loaded-but-unwired mmproj answers plausibly about a blank image, so "describe this" would prove nothing |
| `a text-only role refuses an image` | the same image sent to a role whose model has no mmproj | an error naming the limitation, not a confident answer about an image it cannot see | a silent wrong answer is the worst outcome here |

**UAT covers:** whether the vision quality is good enough to be worth using on real
screenshots.

**Done when:** the two tests above pass. Both must be red when created.

**Depends on:** CUJ-01

**Beads:** ubuntu-strix-ai-setup-873 — all closed

---

## CUJ-06: A future maintainer reproduces the numbers the roster was chosen on

**Actor:** Whoever administers this box six months from now
**Trigger:** A model looks slow, or a new candidate needs comparing.
**Journey:**
1. They find the benchmark record, read which build and file each number came from.
2. They run the harness and get a comparable row.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `harness refuses to measure while a download runs` | the harness invoked with a `curl` process live | exits non-zero, prints what it found, emits no timing row | REPL: a phantom refusal cost an hour; `pgrep -f` matched its own wrapper, now `pgrep -x curl` |
| `every recorded row names build, packager, quant and size` | the committed results record | no row is identified by size alone | REPL: two files of identical size differed 2.24x by packager |

**UAT covers:** nothing. This one is for whoever comes next, and the tests are the
whole of it.

**Done when:** the two tests above pass. Both must be red when created.

**Beads:** ubuntu-strix-ai-setup-o6m — all closed

---

## CUJ-07: A future maintainer sees exactly which steps needed root

**Actor:** Whoever administers this box six months from now
**Trigger:** They are rebuilding the machine, or undoing something.
**Journey:**
1. They read the root-requiring steps in one place, each with why.
2. They follow one rollback and the machine returns to its prior state.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every privileged step has a recorded rollback` | the recorded procedures | each root command is paired with one that undoes it, and is marked as handed to Nathan rather than executed | REPL: the GTT commands existed only in chat until Nathan asked for them; that is exactly where a rollback gets lost |

**UAT covers:** nothing.

**Done when:** the test above passes. It must be red when created.

**Beads:** ubuntu-strix-ai-setup-7rb — all closed

---

## CUJ-08: The machine comes back after a reboot without being nursed

**Actor:** The machine itself, across reboots
**Trigger:** A kernel update, a power cut, a closed lid.
**Journey:**
1. The machine boots with the memory ceiling it was configured for.
2. The contract is listening without anyone starting it.
3. The first request loads a model and is answered.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the configured ceiling survives a reboot` | the running system after a boot | GTT total reads the configured ceiling; the VRAM carve-out is still 512 MiB | REPL probe 9: 61.41 -> 110.00 GiB with the carve-out held at 512 MiB |
| `the contract answers without being started by hand` | a boot with no console login | the port returns a models listing within a bounded wait | "without hand-holding" is the stated outcome |

**UAT covers:** whether it is actually there when he opens the laptop, which is the
only version of this that counts.

**Done when:** the two tests above pass. Both must be red when created.

**Depends on:** CUJ-01

**Beads:** ubuntu-strix-ai-setup-143 — all closed

---

## CUJ-09: Nothing under evaluation ever reaches Nathan's files

**Actor:** Nathan, while the suite is being built
**Trigger:** An agent is about to be pointed at a task for the first time.
**Journey:**
1. Nathan starts a test run; every agent in it runs with no host path mounted.
2. He inspects what an agent produced by attaching a container to the same volume.
3. Nothing outside podman's own storage changed.

This is the one CUJ tested to destruction, because every failure mode in it is
silent. The rest of this document smoke-tests plumbing and leaves judgement to
Nathan; that trade only works if the blast radius is genuinely contained.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `no agent container declares a host bind mount` | every container specification in the harness | none contains a bind mount of a host path; workspaces are named volumes only | the constraint Nathan set: no filesystem carry-over while capability is unknown |
| `an agent container cannot see the host home` | a container from the harness image | `/home` is empty and no path reaches the host home | REPL: verified on a stock rootless container, `/home entries: 0` |
| `the contract is not reachable from the LAN` | the contract's port dialled from the second machine's address | refused there; the same request from a test container succeeds | there is a second machine on this LAN, and binding `0.0.0.0` is the easy way to get this wrong |
| `an agent container reaches nothing but the contract` | an agent task run with only the contract's host and port permitted | every other destination fails and the task still completes | egress is the only boundary the container does not give for free |
| `a work volume outlives its container and is readable by another` | a volume written by a container that has since exited | a second container attached to the same volume reads what the first wrote | Nathan: inspect through a container on the volume, do not copy anything out |

**UAT covers:** nothing. If this one needs his judgement it has already failed.

**Done when:** the five tests above pass. All must be red when created.

**Beads:** ubuntu-strix-ai-setup-aeg (epic), aeg.1 scaffolding, aeg.2 harness base, aeg.3 isolation tests — all closed

---

<!--
Checks:
  All eight actor-outcome pairs have a CUJ, plus CUJ-09 for the harness boundary.
  Tests are mechanical only. Anything needing taste is on a "UAT covers" line,
  which is a handoff note and never a completion criterion.
  Rigor is concentrated in CUJ-09, where failure is silent.
  21 tests, down from 27. The cut ones were judging quality, which is Nathan's job.
-->
