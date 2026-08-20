# CUJ document: A local Claude suite on Strix Halo

Derived from `spec.md` in this directory. One CUJ per actor-outcome pair.

**Test convention.** The repository has no tests today, so this establishes one.
Tests are `bats-core` files at `tests/NN-<slice>.bats`, run by `make test`.
`bats` installs user-level with `npm i -g bats` (1.13.0, no root); `jq` is
already present at `/usr/bin/jq`. These are integration tests against a running
system — they start services, make HTTP requests, and read files. There is
nothing here worth unit-testing.

---

## CUJ-01: Nathan finishes a real coding task at the terminal, on a local model

**Actor:** Nathan at a terminal, writing code
**Trigger:** He has a change to make and does not want it leaving the machine.
**Journey:**
1. Nathan starts the serving contract, which listens on one port.
2. Nathan runs opencode in a project directory.
3. Nathan describes a change that spans more than one file.
4. opencode reads files, edits them, runs a command, and reports what it did.
5. Nathan reads the diff and it is the change he asked for.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `contract answers both API shapes on one port` | the same logical prompt sent to `/v1/chat/completions` and to `/v1/messages` | both return a completion naming the same role alias; neither 404s | llama-swap documents both; opencode uses one shape and OpenPencil can use the other |
| `agent completes a task spanning two files` | rename a symbol defined in one file and used in another, then run the project's check command | both files are modified, the check command exits 0, and the agent stops on its own | the spec's open risk: throughput was measured, loop reliability was not |
| `no tool call is malformed across the task` | the same two-file task, with the contract's request log captured | every tool call the harness received parsed as valid JSON; zero silently dropped | REPL: no throughput number predicts tool-call well-formedness |
| `agent does not re-read a file it has already read` | a task touching one file twice in the same session | the same path is not read more than twice across the run | the named failure mode for small models in an agent loop |
| `no packets leave the machine during a task` | the same task, with a connection count taken before and after | zero new non-loopback TCP connections from the agent or the contract | "no network egress" is the actor's stated outcome |

**Done when:** the five tests above pass. All must be red when created.

**Beads:**

---

## CUJ-02: Nathan reorganises a folder of documents without opening a terminal

**Actor:** Nathan in a GUI, working on files and documents
**Trigger:** He has a directory of files that needs sorting, renaming, and summarising.
**Journey:**
1. Nathan opens the desktop agent and nominates one folder as its workspace.
2. Nathan describes the outcome he wants for the folder's contents.
3. The agent proposes a destructive step and waits for him.
4. Nathan approves, and the agent finishes and reports what changed.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `agent writes only inside the nominated folder` | a task whose wording invites writing to a sibling directory outside the workspace | no file outside the workspace is created or modified | the actor's outcome names folder scoping explicitly |
| `deletion is not performed without confirmation` | a task that requires removing a file, run with confirmation declined | the file still exists and the agent reports the step as skipped | Cowork's confirmation-before-destructive-action is the behaviour being replicated |
| `desktop agent uses the contract with no model configured in it` | the agent's own config with a base URL and a role name but no model file path | a request arrives at the contract naming that role | the spec puts model choice in exactly one file |

**Done when:** the three tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:**

---

## CUJ-03: Nathan takes a described design to an editable document and back to code

**Actor:** Nathan designing something visual
**Trigger:** He wants a screen laid out and eventually wants it as markup.
**Journey:**
1. Nathan opens the design tool and points its AI at the local contract.
2. Nathan describes the screen he wants.
3. The tool builds it on the canvas as editable nodes, and he adjusts one by hand.
4. Nathan exports the result as JSX or HTML.
5. Nathan edits that markup and imports it back, and it is editable again.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `desktop build reaches the local contract` | the design tool's compatible-provider config with a local base URL and a role name | a request arrives at the contract and a response renders in the tool | REPL: `compatible.ts` takes a `baseURL` for both adapters; the browser build fails CORS on the Anthropic shape, the Tauri build does not |
| `described screen becomes addressable nodes` | one prompt describing a screen with a heading, a body paragraph and a button | the document contains at least one TEXT node whose content matches the requested heading | the claim is editable nodes, not a flat image |
| `export to markup and reimport preserves structure` | a document exported with `openpencil export -f html --css tailwind`, then reimported with `openpencil import` | the reimported document has the same node count and the same text content | the round-trip is what replaces Claude Design's handoff |
| `hand edit survives the next AI turn` | a node whose text Nathan changed by hand, followed by a prompt touching a different node | the hand-edited text is unchanged | direct manipulation is the reason for a canvas over a chat |

**Done when:** the four tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:**

---

## CUJ-04: Nathan changes which model backs a role by editing one file

**Actor:** Nathan, any leg
**Trigger:** A benchmark says a different file should serve the `deep` role.
**Journey:**
1. Nathan edits the contract's roster and points `deep` at a different model file.
2. Nathan reloads the contract.
3. Nathan sends the next request from an unchanged frontend and it is served by the new file.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `repointing a role changes what serves it` | the roster's `deep` entry switched from the 122B to the 35B, contract reloaded | the next `deep` request is served by a process whose command line names the 35B file | the spec makes the roster the only place a model choice lives |
| `no frontend configuration changes` | the same switch, with all three frontend config files hashed before and after | all three hashes are unchanged | "with no frontend reconfigured" is the stated outcome |
| `an unknown role fails loudly` | a request naming a role absent from the roster | a 4xx naming the unknown role; no fallback model is loaded and no request is silently served | fail fast over fail silently |
| `an idle role releases its memory` | two roles requested in turn, larger than fit together, with a TTL shorter than the gap | GTT in use falls after the TTL and the second request succeeds | REPL: 108.3 GiB free; 69.1 + 20.7 GiB fits, but larger pairs will not |

**Done when:** the four tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:**

---

## CUJ-05: Nathan asks a question about an image

**Actor:** Nathan, any leg
**Trigger:** He has a screenshot and a question about what is in it.
**Journey:**
1. Nathan attaches the image in whichever frontend he is already using.
2. The frontend sends it to the contract's vision role.
3. The answer refers to what is actually in the image.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `vision role describes real image content` | a generated PNG containing a specific short word in large type | the response contains that word | REPL: an mmproj that is loaded but unwired still answers plausibly about a blank image |
| `vision role is reachable under both API shapes` | the same image posted as an OpenAI image part and as an Anthropic image block | both return a response naming the word | the frontends do not agree on which shape they speak |
| `a text-only role rejects an image rather than ignoring it` | the same image sent to a role whose model has no mmproj | an error naming the limitation; not a confident answer about an image it cannot see | fail fast; a silent wrong answer is the worst outcome here |

**Done when:** the three tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:**

---

## CUJ-06: A future maintainer reproduces the numbers the roster was chosen on

**Actor:** Whoever administers this box six months from now
**Trigger:** A model looks slow, or a new candidate needs comparing.
**Journey:**
1. They find the benchmark record in the repository.
2. They read which build, which file, and what the GPU was doing for each number.
3. They run the harness against a model and get a comparable row.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `harness refuses to measure while a download runs` | the harness invoked with a `curl` process live | it exits non-zero, prints what it found, and emits no timing row | REPL: a phantom refusal cost an hour; `pgrep -f` matched its own wrapper, now `pgrep -x curl` |
| `every recorded row names its build and its file` | the committed results record | each row carries a build identifier, a packager, a quant and a size; no row is size-only | REPL: identical sizes differed 2.24x by packager, so size alone identifies nothing |
| `harness emits GPU utilisation beside each number` | one harness run | the output contains a utilisation series alongside the timing row | REPL: 25.9 t/s at 98% busy and 25.9 t/s at 10% busy are opposite problems |
| `a fresh checkout can run the harness` | a clean clone with no models present | the harness exits with a clear message naming the missing file, not a stack trace | the record is worthless if only this machine can use it |

**Done when:** the four tests above pass. All must be red when created.

**Beads:**

---

## CUJ-07: A future maintainer sees exactly which steps needed root

**Actor:** Whoever administers this box six months from now
**Trigger:** They are rebuilding the machine, or undoing something.
**Journey:**
1. They read the root-requiring steps in one place, each with why it was needed.
2. They follow the rollback for one of them and the machine returns to its prior state.
3. They remove everything installed under `$HOME` and nothing root-owned is left behind.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `every privileged step has a recorded rollback` | the recorded procedures | each command requiring root is paired with a command that undoes it | REPL: the GTT commands existed only in chat until Nathan asked; that is where a rollback is lost |
| `the boot-argument change is reversible from its backup` | `/etc/default/grub.bak` and the current file | the two differ on exactly one line, and it is the kernel command line | REPL probe 9: the diff was exactly one line and that is what made it safe |
| `no agent-executed command required root` | the recorded procedures | every root command is marked as handed to Nathan, none as executed | REPL: `sudo -n` fails in agent sessions, so this is enforced, not aspirational |
| `removing the user-level install leaves nothing root-owned` | the `$HOME` install paths removed | no file owned by root remains in any path the setup created under `$HOME` | the actor's outcome names separability |

**Done when:** the four tests above pass. All must be red when created.

**Beads:**

---

## CUJ-08: The machine comes back after a reboot without being nursed

**Actor:** The machine itself, across reboots
**Trigger:** A kernel update, a power cut, or Nathan closing the lid for the weekend.
**Journey:**
1. The machine boots.
2. The memory ceiling it was configured for is in effect.
3. The serving contract is listening without anyone starting it.
4. The first request loads a model and is answered.

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `the configured memory ceiling survives a reboot` | the running system after a boot | GTT total reads the configured ceiling and the VRAM carve-out is unchanged at 512 MiB | REPL probe 9: 61.41 -> 110.00 GiB, carve-out held at 512 MiB |
| `the contract is listening without manual start` | a boot with no user login at the console | the port answers a models listing within a bounded wait | "without hand-holding" is the stated outcome |
| `group membership needed by the runtime is present` | the running system after a boot | the service account is in `render` | REPL: `/dev/kfd` is `root render`; this blocked three separate things until it was fixed |
| `a model that needs the raised ceiling actually loads` | a request for the role backed by the 69.10 GiB file | the request is answered and the reported free memory before load exceeded the file size | REPL: at the old 61.41 GiB ceiling this model could not be loaded at all |

**Done when:** the four tests above pass. All must be red when created.

**Depends on:** CUJ-01

**Beads:**

---

<!--
Checks:
  All eight actor-outcome pairs in spec.md have a CUJ.       yes, 01-08
  Every CUJ has test rows with real inputs and assertions.   yes
  Every "Done when" names tests and nothing else.            yes
  Slices are vertical, not layers.                           01 stands the contract up
                                                             through a real task; 02, 03,
                                                             05 each add a frontend end to
                                                             end; 04 and 08 are properties
                                                             of the whole; 06 and 07 are
                                                             independent of the runtime.
  Dependencies sparse.                                       only on CUJ-01, and 06/07 have
                                                             none at all.
-->
