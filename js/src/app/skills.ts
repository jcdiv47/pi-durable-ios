// Agent skills (the SKILL.md folder format): instructions and reference files the user imports in Settings › Skills.
// Swift keeps the folders (Application Support `skills/<name>/`) and their parsed list, passes the list in `open` and
// on every change (`PiRuntime.setSkills`), and reads the files (`skills.read`, `skills.file` host calls), keeping every
// path inside the skill's folder. The prompt lists each skill's name and description; the model reads a skill when it
// needs it, or the user runs one with "/" in the composer and its body goes into the message. No tool can add, change
// or remove a skill, and a skill's scripts never run (docs/adr/0007-instructions-and-skills.md).

import { obj, str } from "@earendil-works/pi-schema";
import type { TextContent } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type Extension, section, type ToolRegistration } from "@earendil-works/pi-durable";
import { hostCall } from "../host/hostcall.ts";

/** A skill as Swift lists it (`SkillLibrary.Skill`). */
export type SkillInfo = {
	name: string;
	description: string;
	/** `disable-model-invocation: true` makes this false: only "/" runs it, and the prompt does not list it. */
	modelInvocable: boolean;
	/** `user-invocable: false` makes this false: the "/" menu leaves it out. */
	userInvocable: boolean;
	/** Paths of the files besides SKILL.md, relative to the skill's folder. */
	files: string[];
};

/** What `skills.read` answers: the body after the frontmatter, and the other files. */
type SkillBody = { name: string; body: string; files: string[] };

/** A skill or file longer than this is cut when read, so one skill can't fill the context. */
export const MAX_SKILL_CHARS = 60_000;
/** The prompt's list stops after this many files per skill. */
const MAX_LISTED_FILES = 40;

function cut(text: string): string {
	return text.length <= MAX_SKILL_CHARS ? text : `${text.slice(0, MAX_SKILL_CHARS)}\n… (${text.length - MAX_SKILL_CHARS} more characters not shown)`;
}

function attribute(value: string): string {
	return value.replace(/[&"<>\n]/g, (c) => (c === "&" ? "&amp;" : c === '"' ? "&quot;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : " "));
}

function fileList(files: readonly string[]): string {
	if (files.length === 0) return "";
	const shown = files.slice(0, MAX_LISTED_FILES).join(", ");
	return `\nFiles (read them with skill_file): ${shown}${files.length > MAX_LISTED_FILES ? `, and ${files.length - MAX_LISTED_FILES} more` : ""}`;
}

/** A skill's body as the model reads it, from `skill_read` or a "/" run. */
export function skillBlock(skill: SkillBody, ran: boolean): string {
	const lead = ran ? `The user ran the skill "${skill.name}". Follow its instructions for this message.` : `Instructions of the skill "${skill.name}".`;
	return `<skill name="${attribute(skill.name)}">\n${lead}${fileList(skill.files)}\n\n${cut(skill.body)}\n</skill>`;
}

/** Where the typed text goes in a skill run: in place of `$ARGUMENTS` if the body has it, otherwise after the skill. */
export function skillContent(skill: SkillBody, text: string): TextContent[] {
	if (skill.body.includes("$ARGUMENTS")) {
		return [{ type: "text", text: skillBlock({ ...skill, body: skill.body.replaceAll("$ARGUMENTS", () => text.trim()) }, true) }];
	}
	const blocks: TextContent[] = [{ type: "text", text: skillBlock(skill, true) }];
	if (text.trim() !== "") blocks.push({ type: "text", text });
	return blocks;
}

/** Reads a skill's body through Swift, for a "/" run. */
export function readSkill(name: string, signal?: AbortSignal): Promise<SkillBody> {
	return hostCall<SkillBody>("skills.read", { name }, signal);
}

/** The skills and the `skills` extension built from them. */
export class SkillHost {
	#skills: SkillInfo[] = [];
	#extension: Extension = defineExtension({ name: "skills" });

	constructor(
		/** Installs the rebuilt extension (`registry.install`); set once the registry exists. */
		public install: (extension: Extension) => void = () => {},
	) {
		this.#rebuild();
	}

	get extension(): Extension {
		return this.#extension;
	}

	skills(): readonly SkillInfo[] {
		return this.#skills;
	}

	/** Replaces the list (from Swift) and installs the rebuilt extension under the same name. */
	setSkills(skills: SkillInfo[]): void {
		this.#skills = skills.map((skill) => ({ ...skill, files: [...(skill.files ?? [])] }));
		this.#rebuild();
		this.install(this.#extension);
	}

	#find(name: string): SkillInfo {
		const skill = this.#skills.find((candidate) => candidate.name === name);
		if (skill === undefined) throw new Error(`No skill named "${name}". The skills are: ${this.#skills.map((s) => s.name).join(", ") || "none"}.`);
		return skill;
	}

	#rebuild(): void {
		const listed = this.#skills.filter((skill) => skill.modelInvocable);
		const skillsSection = section("skills", () => {
			if (listed.length === 0) return undefined;
			return [
				"Skills are instructions the user installed for kinds of tasks. When a task matches a skill's description, call skill_read with its name before you start, then follow it. A skill's files are reference material; its scripts can't run here.",
				"",
				...[...listed].sort((a, b) => a.name.localeCompare(b.name)).map((skill) => `- ${skill.name}: ${skill.description.replace(/\s+/g, " ").trim()}`),
			].join("\n");
		});
		const tools: ToolRegistration[] = [];
		if (listed.length > 0) {
			tools.push(
				defineTool({
					name: "skill_read",
					description: "Read a skill's instructions (its SKILL.md) by name, with the list of its other files.",
					parameters: obj({ name: str({ description: "The skill's name, as the skills list gives it" }) }),
					replay: "safe",
					execute: async (args, _api, context) => {
						const skill = this.#find(args.name);
						if (!skill.modelInvocable) throw new Error(`The skill "${skill.name}" runs only when the user runs it with /${skill.name}.`);
						const body = await hostCall<SkillBody>("skills.read", { name: skill.name }, context.abortSignal);
						return { output: [{ type: "text", text: skillBlock(body, false) }] };
					},
				}),
			);
		}
		if (this.#skills.length > 0) {
			tools.push(
				defineTool({
					name: "skill_file",
					description: "Read a text file from a skill's folder, by the path skill_read lists (such as references/guide.md).",
					parameters: obj({
						name: str({ description: "The skill's name" }),
						path: str({ description: "The file's path inside the skill's folder" }),
					}),
					replay: "safe",
					execute: async (args, _api, context) => {
						const skill = this.#find(args.name);
						const file = await hostCall<{ text: string }>("skills.file", { name: skill.name, path: args.path }, context.abortSignal);
						return { output: [{ type: "text", text: cut(file.text) }] };
					},
				}),
			);
		}
		this.#extension = defineExtension({ name: "skills", sections: [skillsSection], tools });
	}
}
