// What pi-mcp's OAuth modules take from Node and WebCrypto, given to those modules only (`build.ts` imports this into
// `oauth/flow.js` and `oauth/provider.js`). A global `Buffer` would send the provider SDKs down their Node paths, and a
// global `crypto.subtle` with one algorithm would look like WebCrypto to code that needs more of it.

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function base64(bytes: Uint8Array): string {
	let out = "";
	for (let i = 0; i < bytes.length; i += 3) {
		const a = bytes[i]!;
		const b = bytes[i + 1];
		const c = bytes[i + 2];
		out += BASE64[a >> 2]! + BASE64[((a & 3) << 4) | ((b ?? 0) >> 4)]!;
		out += b === undefined ? "=" : BASE64[((b & 15) << 2) | ((c ?? 0) >> 6)]!;
		out += c === undefined ? "=" : BASE64[c & 63]!;
	}
	return out;
}

/** The part of Node's `Buffer` pi-mcp's OAuth uses: bytes or UTF-8 text, as hex, base64 or base64url. */
class BytesBuffer {
	private constructor(private readonly bytes: Uint8Array) {}

	static from(value: string | ArrayBuffer | ArrayBufferView): BytesBuffer {
		if (typeof value === "string") return new BytesBuffer(new TextEncoder().encode(value));
		if (value instanceof ArrayBuffer) return new BytesBuffer(new Uint8Array(value));
		return new BytesBuffer(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
	}

	toString(encoding: "hex" | "base64" | "base64url"): string {
		switch (encoding) {
			case "hex":
				return Array.from(this.bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
			case "base64":
				return base64(this.bytes);
			case "base64url":
				return base64(this.bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
			default:
				throw new TypeError(`Buffer shim: unsupported encoding ${String(encoding)}`);
		}
	}
}

export const Buffer = BytesBuffer;

// ---- SHA-256 (FIPS 180-4), for the PKCE challenge --------------------------

const K = new Uint32Array([
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
	0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
	0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
	0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n));

export function sha256(data: Uint8Array): Uint8Array {
	const bitLength = data.length * 8;
	const padded = new Uint8Array(Math.ceil((data.length + 9) / 64) * 64);
	padded.set(data);
	padded[data.length] = 0x80;
	const view = new DataView(padded.buffer);
	view.setUint32(padded.length - 8, Math.floor(bitLength / 2 ** 32));
	view.setUint32(padded.length - 4, bitLength >>> 0);

	const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
	const w = new Uint32Array(64);
	for (let offset = 0; offset < padded.length; offset += 64) {
		for (let t = 0; t < 16; t++) w[t] = view.getUint32(offset + t * 4);
		for (let t = 16; t < 64; t++) {
			const s0 = rotr(w[t - 15]!, 7) ^ rotr(w[t - 15]!, 18) ^ (w[t - 15]! >>> 3);
			const s1 = rotr(w[t - 2]!, 17) ^ rotr(w[t - 2]!, 19) ^ (w[t - 2]! >>> 10);
			w[t] = w[t - 16]! + s0 + w[t - 7]! + s1;
		}
		let [a, b, c, d, e, f, g, hh] = h as unknown as [number, number, number, number, number, number, number, number];
		for (let t = 0; t < 64; t++) {
			const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[t]! + w[t]!) >>> 0;
			const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
			hh = g;
			g = f;
			f = e;
			e = (d + t1) >>> 0;
			d = c;
			c = b;
			b = a;
			a = (t1 + t2) >>> 0;
		}
		h[0]! += a;
		h[1]! += b;
		h[2]! += c;
		h[3]! += d;
		h[4]! += e;
		h[5]! += f;
		h[6]! += g;
		h[7]! += hh;
	}
	const out = new Uint8Array(32);
	const outView = new DataView(out.buffer);
	for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i]!);
	return out;
}

/** `crypto` for those modules: the global `getRandomValues`, and `subtle.digest` with SHA-256 only. */
export const crypto = {
	getRandomValues: <T extends ArrayBufferView>(array: T): T => globalThis.crypto.getRandomValues(array as never) as T,
	subtle: {
		digest: async (algorithm: string, data: ArrayBuffer | ArrayBufferView): Promise<ArrayBuffer> => {
			if (algorithm.toUpperCase() !== "SHA-256") throw new Error(`crypto shim: unsupported digest ${algorithm}`);
			const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
			return sha256(bytes).buffer as ArrayBuffer;
		},
	},
};
