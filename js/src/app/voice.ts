// Talk to Pi (`RealtimeVoice` in Swift) keeps its sessions in the conversation they went to: what the user said and
// what the voice said, as display-only entries the model never reads, next to the requests the voice handed to Pi
// (input entries whose data carries the session). The recording is a file in Swift; lines point into it by offset.

/** A spoken line: written as the session goes, so it sits among Pi's work in the order it was said. */
export const VoiceEntry = "app.voice";

export type VoiceLine = {
	/** The voice session, which names its recording. */
	session: string;
	/** `user`: what the user said; `pi`: what the voice said aloud. */
	role: "user" | "pi";
	text: string;
	/** Where the line is in the session's recording, when there is one. */
	startMs?: number;
	endMs?: number;
	/** When it was said, ms since 1970. */
	at: number;
};

/** What Swift sends to write a line; the item ID (the Realtime API's) makes a repeated write one entry. */
export type VoiceLineInput = VoiceLine & { conversationId: number; itemId: string };

/** The voice session a display item belongs to, and for a spoken line where it is in the recording. */
export type DisplayVoice = { session: string; role?: "user" | "pi"; startMs?: number; endMs?: number };
