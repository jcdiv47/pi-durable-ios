// Pi's web cards: the page API (`pi`) and the <pi-*> components, injected by the app (WebCardView) at document start,
// before the agent's HTML is parsed. Plain JavaScript with no dependencies: it runs in WebKit, not in Pi's JSC.
// The app puts `window.__piCard` ({ id, version, title, data }) in place first.
(() => {
	"use strict";

	// MARK: Bridge

	const post = (message) => {
		try {
			window.webkit.messageHandlers.pi.postMessage(message);
		} catch (_) {
			// Not in the app (a browser preview): nothing to send to.
		}
	};
	const config = window.__piCard || {};
	const plain = (value) => (value === undefined ? null : JSON.parse(JSON.stringify(value)));
	const pi = Object.freeze({
		card: Object.freeze({ id: config.id, version: config.version, title: config.title }),
		data: Object.freeze(config.data || {}),
		/** Sends `value` back to Pi as the user's answer; `label` is what the chat shows for it. */
		submit(value, label) {
			post({ type: "submit", value: plain(value), label: label == null ? undefined : String(label) });
		},
		/** Sends `text` to Pi as the user. */
		prompt(text) {
			post({ type: "prompt", text: String(text) });
		},
		openURL(url) {
			post({ type: "open", url: String(url) });
		},
	});
	Object.defineProperty(window, "pi", { value: pi, writable: false, configurable: false });

	// No peer connections: STUN would reach the network around the page's content security policy.
	for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCSessionDescription"]) {
		try {
			Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false });
		} catch (_) {}
	}

	// The card's height, for the chat to size the view (it does not scroll inline).
	let lastHeight = 0;
	const reportHeight = () => {
		const height = Math.ceil(document.documentElement.getBoundingClientRect().height);
		if (height !== lastHeight) {
			lastHeight = height;
			post({ type: "height", value: height });
		}
	};
	new ResizeObserver(reportHeight).observe(document.documentElement);
	window.addEventListener("load", reportHeight);
	window.addEventListener("error", (event) => post({ type: "error", message: String(event.message), line: event.lineno }));

	// MARK: Helpers

	const h = (tag, attrs, ...children) => {
		const element = document.createElement(tag);
		for (const [key, value] of Object.entries(attrs || {})) {
			if (value == null || value === false) continue;
			if (key === "class") element.className = value;
			else if (key === "text") element.textContent = value;
			else if (key.startsWith("on")) element.addEventListener(key.slice(2), value);
			else element.setAttribute(key, value === true ? "" : String(value));
		}
		for (const child of children.flat()) if (child != null && child !== false) element.append(child instanceof Node ? child : String(child));
		return element;
	};
	const svg = (tag, attrs) => {
		const element = document.createElementNS("http://www.w3.org/2000/svg", tag);
		for (const [key, value] of Object.entries(attrs || {})) if (value != null) element.setAttribute(key, String(value));
		return element;
	};
	const json = (element, name, fallback) => {
		const text = element.getAttribute(name);
		if (text == null || text.trim() === "") return fallback;
		try {
			return JSON.parse(text);
		} catch (_) {
			console.error(`<${element.localName} ${name}> is not JSON`);
			return fallback;
		}
	};
	const number = (value, fallback) => {
		const n = Number(value);
		return value == null || value === "" || !Number.isFinite(n) ? fallback : n;
	};
	const format = (value, unit) => {
		if (typeof value !== "number" || !Number.isFinite(value)) return value == null ? "—" : String(value);
		const abs = Math.abs(value);
		const text =
			abs >= 1e6
				? `${(value / 1e6).toFixed(abs >= 1e7 ? 0 : 1)}M`
				: abs >= 1e4
					? `${(value / 1e3).toFixed(abs >= 1e5 ? 0 : 1)}K`
					: value.toLocaleString(undefined, { maximumFractionDigits: abs < 10 ? 2 : abs < 100 ? 1 : 0 });
		return unit ? `${text}${unit}` : text;
	};
	const words = (key) => {
		const spaced = String(key)
			.replace(/[_-]+/g, " ")
			.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
			.toLowerCase();
		return spaced.charAt(0).toUpperCase() + spaced.slice(1);
	};
	const palette = ["var(--pi-accent)", "var(--pi-success)", "var(--pi-warning)", "#AF52DE", "#30B0C7", "var(--pi-danger)"];
	const define = (name, element) => {
		if (!customElements.get(name)) customElements.define(name, element);
	};

	/** Renders once the element's children are parsed, and again when an observed attribute changes. */
	class PiElement extends HTMLElement {
		connectedCallback() {
			if (this._ready) return;
			const go = () => {
				if (this._ready) return;
				this._ready = true;
				this.setup();
				this.render();
			};
			if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go, { once: true });
			else go();
		}
		attributeChangedCallback() {
			if (this._ready) this.render();
		}
		setup() {}
		render() {}
	}

	// MARK: Layout

	define(
		"pi-card",
		class extends PiElement {
			setup() {
				const body = h("div", { class: "pi-card-body" });
				body.append(...this.childNodes);
				const kicker = this.getAttribute("kicker");
				const title = this.getAttribute("title");
				const subtitle = this.getAttribute("subtitle");
				// The title is drawn, not a tooltip.
				this.removeAttribute("title");
				const head =
					kicker || title || subtitle
						? h(
								"div",
								{ class: "pi-card-head" },
								kicker && h("div", { class: "pi-kicker", text: kicker }),
								title && h("div", { class: "pi-card-title", text: title }),
								subtitle && h("div", { class: "pi-card-subtitle", text: subtitle }),
							)
						: null;
				this.replaceChildren(...[head, body.childNodes.length > 0 ? body : null].filter(Boolean));
			}
		},
	);

	define(
		"pi-tabs",
		class extends PiElement {
			setup() {
				const tabs = [...this.querySelectorAll(":scope > pi-tab")];
				if (tabs.length === 0) return;
				const buttons = tabs.map((tab, index) =>
					h("button", { type: "button", role: "tab", onclick: () => select(index) }, tab.getAttribute("label") || `Tab ${index + 1}`),
				);
				const select = (index) => {
					tabs.forEach((tab, i) => (tab.hidden = i !== index));
					buttons.forEach((button, i) => button.setAttribute("aria-selected", String(i === index)));
				};
				this.prepend(h("div", { class: "pi-segments", role: "tablist" }, buttons));
				select(Math.max(0, tabs.findIndex((tab) => tab.hasAttribute("selected"))));
			}
		},
	);

	// MARK: Data

	define(
		"pi-stat",
		class extends PiElement {
			static observedAttributes = ["label", "value", "delta", "trend"];
			render() {
				const trend = this.getAttribute("trend");
				const delta = this.getAttribute("delta");
				this.replaceChildren(
					h("div", { class: "pi-stat-label", text: this.getAttribute("label") || "" }),
					h("div", { class: "pi-stat-value", text: this.getAttribute("value") ?? "—" }),
					delta && h("div", { class: `pi-stat-delta ${trend === "up" || trend === "down" ? trend : ""}`, text: `${trend === "up" ? "▲ " : trend === "down" ? "▼ " : ""}${delta}` }),
				);
			}
		},
	);

	define(
		"pi-progress",
		class extends PiElement {
			static observedAttributes = ["value", "label"];
			render() {
				let value = number(this.getAttribute("value"), 0);
				if (value > 1) value /= 100;
				value = Math.min(Math.max(value, 0), 1);
				const label = this.getAttribute("label");
				this.setAttribute("role", "progressbar");
				this.setAttribute("aria-valuenow", String(Math.round(value * 100)));
				this.replaceChildren(
					label ? h("div", { class: "pi-progress-head" }, h("span", { text: label }), h("span", { text: `${Math.round(value * 100)}%` })) : null,
					h("div", { class: "pi-progress-track" }, h("div", { class: "pi-progress-fill", style: `width:${value * 100}%` })),
				);
			}
		},
	);

	/** Rounded tick values covering min…max in about `count` steps. */
	const ticks = (min, max, count) => {
		if (min === max) {
			max = min + 1;
			min = Math.min(0, min);
		}
		const raw = (max - min) / count;
		const magnitude = 10 ** Math.floor(Math.log10(raw));
		const error = raw / magnitude;
		const step = (error >= 7.5 ? 10 : error >= 3.5 ? 5 : error >= 1.5 ? 2 : 1) * magnitude;
		const out = [];
		for (let v = Math.floor(min / step) * step; v <= Math.ceil(max / step) * step + step / 2; v += step) out.push(Number(v.toFixed(10)));
		return out;
	};

	define(
		"pi-chart",
		class extends PiElement {
			static observedAttributes = ["data", "values", "labels", "type", "height", "unit"];
			setup() {
				let width = 0;
				new ResizeObserver(() => {
					if (Math.abs(this.clientWidth - width) > 1) {
						width = this.clientWidth;
						this.render();
					}
				}).observe(this);
			}
			data() {
				const data = json(this, "data", null);
				if (data && Array.isArray(data.series)) return { labels: data.labels || [], series: data.series };
				if (Array.isArray(data)) return { labels: json(this, "labels", []), series: [{ name: "", values: data }] };
				return { labels: json(this, "labels", []), series: [{ name: this.getAttribute("label") || "", values: json(this, "values", []) }] };
			}
			render() {
				const { labels, series } = this.data();
				const type = ["bar", "area", "line"].includes(this.getAttribute("type")) ? this.getAttribute("type") : "line";
				const unit = this.getAttribute("unit") || "";
				const count = Math.max(0, ...series.map((s) => (s.values || []).length));
				const W = Math.max(this.clientWidth, 200);
				const H = number(this.getAttribute("height"), 180);
				if (count === 0) {
					this.replaceChildren(h("div", { class: "pi-secondary", text: "No data" }));
					return;
				}
				const all = series.flatMap((s) => (s.values || []).filter((v) => typeof v === "number"));
				let min = Math.min(...all);
				let max = Math.max(...all);
				// Bars and areas stand on zero; a line keeps its own range, so small changes show.
				if (type !== "line") min = Math.min(0, min);
				const yTicks = ticks(min, max, 4);
				const lo = yTicks[0];
				const hi = yTicks[yTicks.length - 1];
				const left = Math.max(...yTicks.map((t) => format(t, unit).length)) * 6.4 + 8;
				const top = 8;
				const bottom = 22;
				const plotW = W - left - 4;
				const plotH = H - top - bottom;
				const y = (v) => top + plotH - ((v - lo) / (hi - lo || 1)) * plotH;
				const band = plotW / count;
				const x = (i) => (type === "bar" ? left + band * i + band / 2 : left + (count === 1 ? plotW / 2 : (plotW * i) / (count - 1)));

				const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, height: H, role: "img" });
				for (const t of yTicks) {
					root.append(svg("line", { class: "pi-grid", x1: left, x2: W - 4, y1: y(t), y2: y(t) }));
					const label = svg("text", { class: "pi-axis", x: left - 6, y: y(t) + 3.5, "text-anchor": "end" });
					label.textContent = format(t, unit);
					root.append(label);
				}
				const every = Math.ceil(count / 7);
				for (let i = 0; i < count; i += every) {
					const label = svg("text", { class: "pi-axis", x: x(i), y: H - 6, "text-anchor": type === "bar" || (i > 0 && i < count - 1) ? "middle" : i === 0 ? "start" : "end" });
					label.textContent = labels[i] == null ? "" : String(labels[i]);
					root.append(label);
				}
				const defs = svg("defs");
				root.append(defs);
				series.forEach((s, index) => {
					const color = s.color || palette[index % palette.length];
					const values = s.values || [];
					if (type === "bar") {
						const groupWidth = band * 0.7;
						const barWidth = groupWidth / series.length;
						values.forEach((v, i) => {
							if (typeof v !== "number") return;
							const x0 = left + band * i + (band - groupWidth) / 2 + barWidth * index;
							const y0 = Math.min(y(v), y(Math.max(lo, 0)));
							const height = Math.max(Math.abs(y(v) - y(Math.max(lo, 0))), 1);
							root.append(svg("rect", { x: x0 + 1, y: y0, width: Math.max(barWidth - 2, 1), height, rx: Math.min(4, barWidth / 3), fill: color }));
						});
						return;
					}
					const points = values.map((v, i) => (typeof v === "number" ? [x(i), y(v)] : null)).filter(Boolean);
					if (points.length === 0) return;
					const line = points.map(([px, py], i) => `${i === 0 ? "M" : "L"}${px.toFixed(1)},${py.toFixed(1)}`).join(" ");
					if (type === "area") {
						const id = `g${Math.random().toString(36).slice(2)}`;
						const gradient = svg("linearGradient", { id, x1: 0, x2: 0, y1: 0, y2: 1 });
						gradient.append(svg("stop", { offset: "0%", "stop-color": color, "stop-opacity": 0.28 }), svg("stop", { offset: "100%", "stop-color": color, "stop-opacity": 0.02 }));
						defs.append(gradient);
						const base = y(Math.max(lo, 0));
						root.append(svg("path", { d: `${line} L${points[points.length - 1][0]},${base} L${points[0][0]},${base} Z`, fill: `url(#${id})` }));
					}
					root.append(svg("path", { d: line, fill: "none", stroke: color, "stroke-width": 2.2, "stroke-linejoin": "round", "stroke-linecap": "round" }));
					const [lx, ly] = points[points.length - 1];
					root.append(svg("circle", { cx: lx, cy: ly, r: 3.2, fill: color }));
				});

				// Touch or hover a column for its values.
				const guide = svg("line", { class: "pi-guide", y1: top, y2: top + plotH, visibility: "hidden" });
				root.append(guide);
				const tip = h("div", { class: "pi-tip", hidden: true });
				const show = (event) => {
					const box = root.getBoundingClientRect();
					const px = ((event.clientX - box.left) / box.width) * W;
					const i = Math.min(count - 1, Math.max(0, type === "bar" ? Math.floor((px - left) / band) : Math.round(((px - left) / plotW) * (count - 1))));
					guide.setAttribute("x1", x(i));
					guide.setAttribute("x2", x(i));
					guide.setAttribute("visibility", "visible");
					tip.replaceChildren(
						h("b", { text: labels[i] == null ? `#${i + 1}` : String(labels[i]) }),
						...series.map((s, index) =>
							h("div", {}, h("span", { style: `color:${s.color || palette[index % palette.length]}`, text: "● " }), `${s.name ? `${s.name}: ` : ""}${format((s.values || [])[i], unit)}`),
						),
					);
					tip.hidden = false;
					const tipX = (x(i) / W) * box.width;
					tip.style.left = `${Math.min(Math.max(tipX - tip.offsetWidth / 2, 0), box.width - tip.offsetWidth)}px`;
				};
				const hide = () => {
					guide.setAttribute("visibility", "hidden");
					tip.hidden = true;
				};
				root.addEventListener("pointerdown", show);
				root.addEventListener("pointermove", show);
				root.addEventListener("pointerleave", hide);
				root.addEventListener("pointerup", (event) => event.pointerType !== "mouse" && setTimeout(hide, 1500));

				const legend =
					series.length > 1 || series[0].name
						? h(
								"div",
								{ class: "pi-legend" },
								series.map((s, index) => h("span", {}, h("i", { style: `background:${s.color || palette[index % palette.length]}` }), s.name || `Series ${index + 1}`)),
							)
						: null;
				this.replaceChildren(root, tip, legend);
			}
		},
	);

	define(
		"pi-table",
		class extends PiElement {
			static observedAttributes = ["data", "columns", "rows"];
			setup() {
				this.sort = null;
			}
			render() {
				const records = json(this, "data", null);
				let columns;
				let rows;
				if (Array.isArray(records)) {
					columns = json(this, "columns", null) || [...new Set(records.flatMap((r) => (r && typeof r === "object" ? Object.keys(r) : [])))];
					rows = records.map((r) => columns.map((c) => (r == null ? null : r[c])));
				} else {
					columns = json(this, "columns", []);
					rows = json(this, "rows", []);
				}
				const numeric = columns.map((_, c) => rows.length > 0 && rows.every((row) => row[c] == null || typeof row[c] === "number"));
				if (this.sort) {
					const { column, direction } = this.sort;
					rows = [...rows].sort((a, b) => {
						const x = a[column];
						const y = b[column];
						const order = typeof x === "number" && typeof y === "number" ? x - y : String(x ?? "").localeCompare(String(y ?? ""), undefined, { numeric: true });
						return order * direction;
					});
				}
				const cell = (value) => (value == null ? "—" : typeof value === "boolean" ? (value ? "Yes" : "No") : typeof value === "number" ? format(value) : String(value));
				const table = h(
					"table",
					{ class: "pi-table" },
					h(
						"thead",
						{},
						h(
							"tr",
							{},
							columns.map((column, index) =>
								h(
									"th",
									{
										class: numeric[index] ? "num" : null,
										"data-sort": this.sort && this.sort.column === index ? (this.sort.direction > 0 ? "↑" : "↓") : null,
										onclick: () => {
											this.sort = this.sort && this.sort.column === index ? { column: index, direction: -this.sort.direction } : { column: index, direction: 1 };
											this.render();
										},
									},
									Array.isArray(records) ? words(column) : String(column),
								),
							),
						),
					),
					h(
						"tbody",
						{},
						rows.map((row) => h("tr", {}, columns.map((_, index) => h("td", { class: numeric[index] ? "num" : null, text: cell(row[index]) })))),
					),
				);
				this.replaceChildren(h("div", { class: "pi-table-wrap" }, table));
			}
		},
	);

	define(
		"pi-list",
		class extends PiElement {
			static observedAttributes = ["items"];
			render() {
				const items = json(this, "items", []);
				this.replaceChildren(
					...items.map((item) => {
						const tap = item.prompt ? () => pi.prompt(item.prompt) : item.href ? () => pi.openURL(item.href) : null;
						return h(
							"div",
							{ class: "pi-row", "data-tap": tap ? "" : null, role: tap ? "button" : null, onclick: tap },
							item.icon && h("span", { text: item.icon }),
							h("div", { class: "pi-row-main" }, h("div", { class: "pi-row-title", text: item.title ?? "" }), item.subtitle && h("div", { class: "pi-row-subtitle", text: item.subtitle })),
							item.trailing != null && h("div", { class: "pi-row-trailing", text: String(item.trailing) }),
						);
					}),
				);
			}
		},
	);

	define(
		"pi-code",
		class extends PiElement {
			setup() {
				const code = this.textContent.replace(/^\n/, "").replace(/\s+$/, "");
				this.replaceChildren(h("div", { class: "pi-code-head" }, h("span", { text: this.getAttribute("lang") || "code" })), h("pre", {}, h("code", { text: code })));
			}
		},
	);

	define(
		"pi-diff",
		class extends PiElement {
			setup() {
				const lines = this.textContent.replace(/^\n/, "").replace(/\s+$/, "").split("\n");
				let added = 0;
				let removed = 0;
				const rows = lines.map((line) => {
					let kind = "";
					if (line.startsWith("@@")) kind = "hunk";
					else if (/^(diff |index |\+\+\+ |--- )/.test(line)) kind = "meta";
					else if (line.startsWith("+")) (kind = "add"), added++;
					else if (line.startsWith("-")) (kind = "del"), removed++;
					return h("span", { class: `l ${kind}`, text: line || " " });
				});
				this.replaceChildren(
					h("div", { class: "pi-code-head" }, h("span", { text: "diff" }), h("span", {}, h("span", { class: "add", text: `+${added}` }), h("span", { class: "del", text: `−${removed}` }))),
					h("pre", {}, rows),
				);
			}
		},
	);

	// MARK: Inputs

	/** A field's label row, with an optional live value on the right. */
	const fieldLabel = (text, output) => (text || output ? h("div", { class: "pi-label" }, h("span", { text: text || "" }), output || null) : null);
	let fieldCount = 0;

	define(
		"pi-input",
		class extends PiElement {
			setup() {
				const id = `f${++fieldCount}`;
				const type = this.getAttribute("type") || "text";
				const control =
					type === "textarea"
						? h("textarea", { class: "pi-input", id, name: this.getAttribute("name"), rows: this.getAttribute("rows") || 3, placeholder: this.getAttribute("placeholder"), required: this.hasAttribute("required") })
						: h("input", {
								class: "pi-input",
								id,
								type,
								name: this.getAttribute("name"),
								value: this.getAttribute("value"),
								placeholder: this.getAttribute("placeholder"),
								required: this.hasAttribute("required"),
								min: this.getAttribute("min"),
								max: this.getAttribute("max"),
								step: this.getAttribute("step"),
							});
				if (type === "textarea" && this.getAttribute("value")) control.value = this.getAttribute("value");
				const label = fieldLabel(this.getAttribute("label"));
				if (label) label.firstChild.replaceWith(h("label", { for: id, text: this.getAttribute("label") }));
				this.replaceChildren(h("div", { class: "pi-field" }, label, control));
			}
		},
	);

	define(
		"pi-date",
		class extends PiElement {
			setup() {
				const type = ["date", "time", "datetime-local", "month"].includes(this.getAttribute("type")) ? this.getAttribute("type") : "date";
				this.replaceChildren(
					h(
						"div",
						{ class: "pi-field" },
						fieldLabel(this.getAttribute("label")),
						h("input", { class: "pi-input", type, name: this.getAttribute("name"), value: this.getAttribute("value"), min: this.getAttribute("min"), max: this.getAttribute("max"), required: this.hasAttribute("required") }),
					),
				);
			}
		},
	);

	define(
		"pi-slider",
		class extends PiElement {
			setup() {
				const unit = this.getAttribute("unit") || "";
				const min = number(this.getAttribute("min"), 0);
				const max = number(this.getAttribute("max"), 100);
				const output = h("output");
				const input = h("input", {
					class: "pi-range",
					type: "range",
					name: this.getAttribute("name"),
					min,
					max,
					step: this.getAttribute("step") || 1,
					value: number(this.getAttribute("value"), (min + max) / 2),
				});
				const show = () => (output.textContent = `${format(Number(input.value))}${unit}`);
				input.addEventListener("input", show);
				show();
				this.replaceChildren(h("div", { class: "pi-field" }, fieldLabel(this.getAttribute("label"), output), input));
			}
		},
	);

	define(
		"pi-toggle",
		class extends PiElement {
			setup() {
				this.replaceChildren(
					h(
						"label",
						{ class: "pi-toggle" },
						h("span", { text: this.getAttribute("label") || "" }),
						h("input", { type: "checkbox", role: "switch", name: this.getAttribute("name"), checked: this.hasAttribute("checked") || this.getAttribute("value") === "true" }),
					),
				);
			}
		},
	);

	define(
		"pi-choice",
		class extends PiElement {
			setup() {
				const name = this.getAttribute("name") || "choice";
				const multiple = this.hasAttribute("multiple");
				const options = json(this, "options", []).map((option) => (option && typeof option === "object" ? option : { label: String(option), value: String(option) }));
				const selected = new Set(multiple ? json(this, "value", []) : [this.getAttribute("value")]);
				const inForm = this.closest("pi-form") !== null;
				const chips = options.map((option) => {
					const value = option.value ?? option.label;
					const input = h("input", { type: multiple ? "checkbox" : "radio", name, value, "data-multi": multiple ? "1" : null, checked: selected.has(value) });
					if (!inForm && !multiple) {
						// On its own, a single choice is the answer: send it on tap.
						input.addEventListener("change", () => {
							const label = this.getAttribute("label");
							pi.submit({ [name]: value }, label ? `${label}: ${option.label}` : option.label);
							for (const other of this.querySelectorAll("input")) other.disabled = other !== input;
						});
					}
					return h("label", { class: "pi-chip" }, input, h("span", { text: option.label ?? value }));
				});
				this.replaceChildren(h("div", { class: "pi-field" }, fieldLabel(this.getAttribute("label")), h("div", { class: "pi-chips", role: multiple ? "group" : "radiogroup" }, chips)));
			}
		},
	);

	/** The values of a form's named controls: numbers for ranges, booleans for lone checkboxes, arrays for multiple choices. */
	const formValues = (form) => {
		const out = {};
		for (const element of form.elements) {
			const name = element.name;
			if (!name || element.type === "submit" || element.type === "button") continue;
			if (element.type === "radio") {
				if (element.checked) out[name] = element.value;
				else if (!(name in out)) out[name] = null;
			} else if (element.type === "checkbox") {
				if (element.dataset.multi === "1") {
					out[name] = out[name] || [];
					if (element.checked) out[name].push(element.value);
				} else out[name] = element.checked;
			} else if (element.type === "range" || element.type === "number") {
				out[name] = element.value === "" ? null : Number(element.value);
			} else {
				out[name] = element.value;
			}
		}
		return out;
	};

	/** "Pace: Balanced · Nights: 4 · Rent a car: Yes": the form's answer in its own labels. */
	const formLabel = (root, values) =>
		Object.entries(values)
			.map(([name, value]) => {
				const field = root.querySelector(`[name="${CSS.escape(name)}"]`)?.closest("pi-input,pi-date,pi-slider,pi-toggle,pi-choice");
				const label = field?.getAttribute("label") || words(name);
				const shown = value == null || value === "" ? "—" : value === true ? "Yes" : value === false ? "No" : Array.isArray(value) ? value.join(", ") || "—" : String(value);
				return `${label}: ${shown}${field?.localName === "pi-slider" && field.getAttribute("unit") ? field.getAttribute("unit") : ""}`;
			})
			.join(" · ");

	define(
		"pi-form",
		class extends PiElement {
			setup() {
				const button = h("button", { type: "submit", text: this.getAttribute("submit") || "Send" });
				const form = h("form", { novalidate: null });
				form.append(...this.childNodes, h("div", { class: "pi-actions" }, button));
				form.addEventListener("submit", (event) => {
					event.preventDefault();
					if (!form.reportValidity()) return;
					const values = formValues(form);
					pi.submit(values, formLabel(form, values));
					this.setAttribute("data-sent", "");
					button.textContent = "Sent";
					button.disabled = true;
				});
				this.replaceChildren(form);
			}
		},
	);

	define(
		"pi-button",
		class extends PiElement {
			setup() {
				const label = this.textContent.trim() || this.getAttribute("label") || "Go";
				const tone = this.getAttribute("tone");
				const button = h("button", { type: "button", class: tone === "plain" ? "pi-plain" : null, text: label });
				button.addEventListener("click", () => {
					if (this.hasAttribute("prompt")) pi.prompt(this.getAttribute("prompt") || label);
					else if (this.hasAttribute("href")) pi.openURL(this.getAttribute("href"));
					else if (this.hasAttribute("value")) pi.submit(json(this, "value", this.getAttribute("value")), label);
					else pi.prompt(label);
				});
				this.replaceChildren(button);
			}
		},
	);
})();
