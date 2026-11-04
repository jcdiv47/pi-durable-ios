# ADR 0007: Instructions (AGENTS.md) and agent skills

Date: 2026-11-04. Status: accepted. Spec: 0001, "Agent design" (the `memory` extension). Follows
[ADR 0006](0006-mcp-servers.md) in how user-chosen content reaches the model.

## Context

Coding agents read standing instructions from an `AGENTS.md` and load skills: folders with a `SKILL.md` (frontmatter
`name` and `description`, then Markdown instructions) and files it refers to (agentskills.io). Both are useful on the
phone: "answer in metric", a weekly-groceries routine, a writing style. pi-durable 1.5 has no loader for either (its
file discovery is Node-only), but prompt sections and tools are all they need.

A phone has no project folder, and both are a way to put text in front of the model, so who may change them matters.

## Decision

### Instructions

- One Markdown text, edited in Settings › Instructions and kept in Application Support `AGENTS.md`. Swift passes it in
  `open` and on every edit (`PiRuntime.setInstructions`).
- The `instructions` extension renders it as the `user_instructions` section, cut at 16,000 characters. Pi re-renders
  sections before each request, so an edit applies from each conversation's next request; nothing is resent when it
  doesn't change.
- **Only the user writes it.** No tool reads or writes it; there is no "remember this" tool.

### Skills

- Imported in Settings › Skills from Files: a skill folder, or a single `.md` file with the frontmatter. A `.zip` or
  `.skill` file has to be unzipped in Files first (iOS has no public unzip API). Or written there (see "Writing and
  editing" below).
- Swift (`SkillLibrary` in PiRuntime) checks the skill and copies it to Application Support `skills/<name>/`. The list is
  read from the folders at start, and passed to JS in `open` and on every change (`PiRuntime.setSkills`).
- What is enforced:

  | Rejected | Warned about | Ignored (kept) |
  | --- | --- | --- |
  | no `SKILL.md`, or no `---` frontmatter | folder name differs from `name` (kept under `name`) | unknown fields (`argument-hint`, `model`, …) |
  | `name` not 1–64 of `a-z 0-9 -`, no leading, trailing or double hyphen | body over 500 lines | `license`, `compatibility`, `metadata` (shown) |
  | empty `description`, or over 1,024 characters | `scripts/` or `allowed-tools` (won't run) | the Markdown body |
  | a symlink, a path out of the folder, over 200 files or 5 MB | | hidden files (not copied) |

  A skill whose name is already installed is replaced only after the user confirms.
- The `skills` extension: a `skills` section listing each skill's name and description, sorted, and two read tools,
  both `replay: "safe"`:
  - `skill_read(name)`: the body after the frontmatter, with the list of its other files.
  - `skill_file(name, path)`: a UTF-8 text file in the skill's folder.

  Both go through host calls (`skills.read`, `skills.file`); Swift keeps every path inside the skill's folder. Text is
  cut at 60,000 characters. The extension is installed from Swift's list before the Harness opens, as `mcp` is, so an
  interrupted read resumes.
- Frontmatter flags from Claude Code: `disable-model-invocation: true` leaves a skill out of the section, and
  `skill_read` refuses it; only "/" runs it. `user-invocable: false` leaves it out of the "/" menu.
- **Scripts never run.** JSC on iOS can't start processes, and running a skill's JS in the runtime would give it every
  tool. The model can read a script as text.
- **Only the user adds, replaces or removes skills.** No tool can, and no skill is fetched from a URL (ADR 0004 rules out
  a generic HTTP fetch). A skill can't change approval policies.

### Writing and editing

- Settings › Skills › New Skill, and Edit on a skill's page, open one form: name, description, the two flags ("Pi reads
  it when it fits", "In the / menu") and the instructions (the Markdown body). Name and description are checked as
  they are typed, with the import's rules; spaces and underscores in a name become hyphens.
- Saving composes the SKILL.md (`SkillLibrary.compose`): the edited fields first, then every other frontmatter line of an
  edited skill as it was written (`license`, `metadata`, `allowed-tools`, comments), then the body. Values are written
  so the parser and YAML read them back as typed: plain when safe, a `|` block over several lines, otherwise
  single-quoted.
- `SkillLibrary.save` stages a copy of the skill's folder with the new SKILL.md, checks it like an import, and swaps it
  in, so an edit keeps the skill's other files. A new name renames the folder; a name another skill has is an error.
  The form edits SKILL.md only; other files still come from an import.
- As with import and remove, only the user does this, and messages that already ran the skill keep what they sent.

### Running a skill with "/"

- Typing `/` at the start of an empty composer opens a menu of the skills (name and description), filtered as you type.
  Picking one puts a chip in the composer; only the chip makes a message a skill run, so a typed "/usr/bin" stays text.
- `PiRuntime.send` takes the skill's name. JS reads its body then and puts it first in the message
  (`<skill name="…">`), followed by the typed text, or with the typed text in place of `$ARGUMENTS` if the body has it,
  then the attachments.
- The message keeps the skill as it was sent: replays, resumes and forks see the same text, even after the skill is
  edited or removed. The input entry's data keeps `skill` and the typed `text`, so the bubble shows the chip and the
  text; a queued skill run comes back to the composer with its chip.

## Consequences

- Skills and instructions are prompt text the user chose, like MCP servers' instructions. A skill imported from
  somewhere untrusted can steer the model; approvals still gate every write.
- Every conversation gets `instructions` and `skills` (`Chat.upgrade` adds them to older ones). With no skills the
  extension has no tools and no section, so it costs nothing.
- Not in this version: zip import, editing a skill's other files, a "Run skill" App Intent, built-in "/" commands.
