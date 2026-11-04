// The user's standing instructions: the app's AGENTS.md, written by hand in Settings › Instructions. Swift keeps
// the text (Application Support `AGENTS.md`) and passes it in `open` and on every edit (`PiRuntime.setInstructions`);
// the `instructions` extension renders it as a prompt section, so an edit applies from the next model request. No
// tool reads or writes it (docs/adr/0007-instructions-and-skills.md).

import { defineExtension, section } from "@earendil-works/pi-durable";

/** More is cut, so a pasted document can't fill every request. */
export const MAX_INSTRUCTIONS_CHARS = 16_000;

export const instructionsSettings = { text: "" };

/** The text as the prompt holds it: trimmed, and cut at `MAX_INSTRUCTIONS_CHARS`. */
export function instructionsText(text: string): string | undefined {
	const trimmed = text.trim();
	if (trimmed === "") return undefined;
	if (trimmed.length <= MAX_INSTRUCTIONS_CHARS) return trimmed;
	return `${trimmed.slice(0, MAX_INSTRUCTIONS_CHARS)}\n… (${trimmed.length - MAX_INSTRUCTIONS_CHARS} more characters not shown)`;
}

const instructionsSection = section("user_instructions", () => {
	const text = instructionsText(instructionsSettings.text);
	if (text === undefined) return undefined;
	return [
		"The user wrote these standing instructions for you (their AGENTS.md). Follow them in every conversation; what the user asks in the conversation itself comes first.",
		"",
		text,
	].join("\n");
});

export const InstructionsExtension = defineExtension({ name: "instructions", sections: [instructionsSection] });
