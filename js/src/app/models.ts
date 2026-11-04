// The providers the app offers and how their keys reach pi-ai. Keys never enter JS: a configured
// provider resolves to a placeholder that Swift's fetch bridge swaps for the Keychain key, and only on
// requests to that provider's hosts (`ProviderKeys` in PiRuntime).

import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { clampThinkingLevel, createModels, createProvider, getSupportedThinkingLevels, type MutableModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { deepseekProvider } from "@earendil-works/pi-ai/providers/deepseek";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { createScriptedModel } from "./scripted.ts";

/** Header value Swift's fetch replaces with the Keychain key; must match `ProviderKeys.placeholder(for:)`. */
export const keyPlaceholder = (provider: string) => `pi-host-key:${provider}`;

/** The env variable pi-ai reads each keyed provider's API key from. */
const keyEnvironment: Record<string, string> = {
	ANTHROPIC_API_KEY: "anthropic",
	DEEPSEEK_API_KEY: "deepseek",
	OPENAI_API_KEY: "openai",
	OPENROUTER_API_KEY: "openrouter",
};

/** An OpenAI-compatible endpoint the user configures in Settings (provider id `custom`). */
export type CustomProvider = {
	readonly name: string;
	readonly baseUrl: string;
	readonly modelIds: readonly string[];
	readonly contextWindow?: number;
};

export function customProvider(config: CustomProvider) {
	return createProvider({
		id: "custom",
		name: config.name || "Custom",
		baseUrl: config.baseUrl,
		auth: {
			apiKey: {
				name: `${config.name || "Custom"} API key`,
				resolve: async ({ ctx }) => {
					const key = await ctx.env("CUSTOM_API_KEY");
					return key ? { auth: { apiKey: key }, source: "Keychain" } : undefined;
				},
			},
		},
		models: config.modelIds.map((id) => ({
			id,
			name: id,
			api: "openai-completions" as const,
			provider: "custom",
			baseUrl: config.baseUrl,
			reasoning: false,
			input: ["text" as const],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: config.contextWindow ?? 128_000,
			maxTokens: 16_384,
		})),
		api: openAICompletionsApi(),
	});
}

/** An Apple Intelligence model Swift reports available (`AppleIntelligence.Model`). */
export type AppleModel = {
	readonly id: string;
	readonly name: string;
	readonly contextWindow: number;
	readonly maxTokens: number;
};

/** Registered while Apple Intelligence is unavailable, so conversations on it keep resolving their model. */
const appleFallback: AppleModel = { id: "on-device", name: "Apple Intelligence (on device)", contextWindow: 4096, maxTokens: 1024 };

/** Must match `AppleIntelligence.host`: Swift's fetch bridge answers this host in the process. */
export const appleBaseUrl = "https://apple-intelligence.pi.local/v1";

/**
 * Apple Intelligence (docs/adr/0008-apple-intelligence.md): Swift serves the on-device model as an OpenAI-compatible
 * endpoint on a host that never reaches the network, so it needs no key. Text only; the endpoint ignores tools.
 */
export function appleProvider(models: readonly AppleModel[]) {
	return createProvider({
		id: "apple",
		name: "Apple Intelligence",
		baseUrl: appleBaseUrl,
		auth: {
			apiKey: {
				name: "Apple Intelligence (no key)",
				resolve: async () => ({ auth: { apiKey: "on-device" }, source: "Apple Intelligence" }),
			},
		},
		models: models.map((model) => ({
			id: model.id,
			name: model.name,
			api: "openai-completions" as const,
			provider: "apple",
			baseUrl: appleBaseUrl,
			reasoning: false,
			input: ["text" as const],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: model.contextWindow,
			maxTokens: model.maxTokens,
		})),
		api: openAICompletionsApi(),
	});
}

export class ModelSetup {
	/** Providers whose keys Swift holds; only these resolve to a placeholder key. */
	keyed = new Set<string>();
	readonly models: MutableModels;

	constructor() {
		this.models = createModels({
			authContext: {
				env: async (name) => {
					const provider = name === "CUSTOM_API_KEY" ? "custom" : keyEnvironment[name];
					return provider !== undefined && this.keyed.has(provider) ? keyPlaceholder(provider) : undefined;
				},
				fileExists: async () => false,
			},
			identity: { attribution: { name: "pi-durable-ios", url: "https://github.com/earendil-works/pi" } },
		});
		this.models.setProvider(anthropicProvider());
		this.models.setProvider(deepseekProvider());
		this.models.setProvider(openaiProvider());
		this.models.setProvider(openrouterProvider());
		this.models.setProvider(createScriptedModel().provider);
		this.models.setProvider(appleProvider([appleFallback]));
	}

	/** The Apple Intelligence models that can run now; none removes the provider from the picker. */
	setApple(models: readonly AppleModel[]): void {
		this.apple = models.length > 0;
		// Kept registered with no models' worth of availability: a conversation already on `apple/on-device` must still
		// resolve its model (and fail with Swift's "unavailable" error) rather than lose it.
		this.models.setProvider(appleProvider(models.length > 0 ? models : [appleFallback]));
	}

	/** Whether the Apple models are offered in the picker. */
	private apple = false;

	setCustom(config: CustomProvider | undefined): void {
		if (config === undefined || config.baseUrl === "" || config.modelIds.length === 0) this.models.deleteProvider("custom");
		else this.models.setProvider(customProvider(config));
	}

	/**
	 * The nearest level `model` supports, so a request never asks a model for an effort it lacks (not every pi-ai API
	 * clamps). An unknown model keeps the level.
	 */
	clampThinking(model: { provider: string; modelId: string }, level: ModelThinkingLevel): ModelThinkingLevel {
		const resolved = this.models.getModel(model.provider, model.modelId);
		return resolved === undefined ? level : clampThinkingLevel(resolved, level);
	}

	/** Chat models of the providers that have keys (and the keyless offline one), for the model picker. */
	available(): {
		provider: string;
		providerName: string;
		id: string;
		name: string;
		reasoning: boolean;
		thinkingLevels: ModelThinkingLevel[];
		contextWindow: number;
		/** Takes image input; others get a placeholder for each attached image. */
		images: boolean;
	}[] {
		return this.models
			.getProviders()
			.filter((provider) => this.keyed.has(provider.id) || provider.id === "scripted" || (provider.id === "apple" && this.apple))
			.flatMap((provider) =>
				this.models.getModels(provider.id).map((model) => ({
					provider: provider.id,
					providerName: provider.name,
					id: model.id,
					name: model.name,
					reasoning: model.reasoning,
					thinkingLevels: getSupportedThinkingLevels(model),
					contextWindow: model.contextWindow,
					images: model.input.includes("image"),
				})),
			);
	}
}
