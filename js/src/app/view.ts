// A conversation's whole transcript over Pi's windowed view (`Conversation.watch()`). The view holds only the newest
// entries; `ConversationTranscript` keeps every entry a client got, and `complete` pages in the rest, so the chat's
// frames keep their contract: the first frame holds the whole transcript, later ones append.

import type { Context } from "@earendil-works/chord";
import { type Conversation, ConversationTranscript, type EntryRecord, type TranscriptView } from "@earendil-works/pi-durable";

/** Entries per page when loading earlier history or filling a gap. */
const pageSize = 200;

export function transcriptOf(conversation: Conversation): ConversationTranscript {
	return new ConversationTranscript((query, limit, context) => conversation.entries(query, limit, undefined, context), { pageSize });
}

/** Loads what `view` is missing (earlier pages and gaps), so its `items` are the whole history. */
export async function complete(transcript: ConversationTranscript, view: TranscriptView, context: Context): Promise<TranscriptView> {
	for (;;) {
		const missing = view.items.find((item) => item.kind !== "entry");
		if (missing === undefined) return view;
		const next = missing.kind === "earlier" ? await transcript.loadEarlier(context) : await transcript.fillGap(missing, context);
		// A load that adds nothing returns the same array; stop rather than ask again.
		if (next.items === view.items) return next;
		view = next;
	}
}

export function entriesOf(view: TranscriptView): EntryRecord[] {
	return view.items.flatMap((item) => (item.kind === "entry" ? [item.entry] : []));
}

/** One read of a conversation's whole transcript and its documents. */
export async function readView(conversation: Conversation, context: Context): Promise<TranscriptView> {
	const transcript = transcriptOf(conversation);
	const watch = await conversation.watch(context);
	try {
		return await complete(transcript, transcript.merge(watch.value), context);
	} finally {
		await watch.stop();
	}
}
