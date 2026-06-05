// 自製 service worker（取代 Flutter 內建的 flutter_service_worker.js）。
//
// 三個職責：
// 1. precache：對 web/ 內已知的靜態檔做 install-time precache（清單由
//    rsbuild plugin 在 build 時掃 web/ + SHA256 hash 寫到
//    precache-manifest.generated.ts，SW import 過來）。
// 2. runtime cache：其它 same-origin 一律 stale-while-revalidate
//    （Flutter build 產物 main.dart.js / canvaskit / assets 都走這條）。
// 3. COOP/COEP headers：對所有 same-origin 回應補上
//    Cross-Origin-Opener-Policy: same-origin
//    Cross-Origin-Embedder-Policy: credentialless
//    讓頁面 `crossOriginIsolated === true`，為未來 wasm renderer 鋪路。
//    credentialless 模式跨域子資源（esm.sh / fonts.gstatic 等）不需要對方
//    回 CORP header 也能載入（不附 cookie）。
//
// 實作關鍵：headers 注入透過 Workbox 的 `handlerWillRespond` plugin hook，
// 不是另開 fetch listener — 否則會跟 Workbox 的 router 互搶 respondWith
// 造成 InvalidStateError、navigation request 走網路、headers 沒被補、頁面
// 無限 reload。參考 https://github.com/GoogleChrome/workbox/issues/2963
//
// 啟動 flow（HTML 端配合）：
//   1. 頁面載入 → 註冊 SW
//   2. 檢查 window.crossOriginIsolated
//      - true → 直接載 flutter_bootstrap.js
//      - false → 等 SW 進入 active 狀態 → location.reload()
//                reload 後 fetch 走 SW、headers 被補上 → isolated → 載 Flutter

import { PrecacheController, PrecacheRoute } from "workbox-precaching";
import { registerRoute, setDefaultHandler } from "workbox-routing";
import { NetworkFirst, StaleWhileRevalidate } from "workbox-strategies";
import type { WorkboxPlugin } from "workbox-core/types";

import { PRECACHE_MANIFEST } from "./precache-manifest.generated";

declare const self: ServiceWorkerGlobalScope;

// 對所有 Workbox handler 出來的 response 補 COOP/COEP headers，並對 wasm
// 回應額外處理 transfer encoding。
//
// 用 clone() 取 body 而非直接吃 `response.body`：實測現行 Workbox 兩種寫法
// 都能 cache（hook 跑的順序顯然在寫 cache 之後），但 Response body 是
// ReadableStream、只能讀一次，若日後 Workbox 內部順序變動、不 clone 就會
// 踩 stream-already-consumed。clone 成本低、純保險。
//
// 對 application/wasm 的特殊處理：GitHub Pages 對 `.wasm` 強制加
// `Content-Encoding: gzip`、不能關。瀏覽器拿到 gzipped wasm 時：
//   1. fetch 自動把 body decode 成原始 wasm bytes
//   2. 但 `Content-Encoding: gzip` header 仍留在 Response 上
// dart2wasm 的 `WebAssembly.compileStreaming` 在 chunk + dynamic linking
// 路徑下對這個 header 異常敏感（症狀：runtime type metadata 對不上、
// `Provider not found`、無窮 reload）。canvaskit 的 MVP wasm 沒事是因為
// 它走簡單初始化路徑。
//
// 解法：**只刪 header、body 直接以 ReadableStream forward**、不 await
// arrayBuffer()。這樣 wasm streaming compile 可以與 fetch 並行進行
// （首次載入省 100~300ms）；瀏覽器看到沒有 Content-Encoding 會當 identity
// 處理、streaming compiler 走正常路徑。
//
// 注意：Content-Length 必須也刪掉 — 原值是 gzipped 長度（例如 1.1MB），
// 跟 decoded body（例如 3MB）對不上，留著瀏覽器可能據此預估錯誤導致解析失敗。
// 補 COOP/COEP headers + 對 application/wasm 拿掉 Content-Encoding。
// 抽成 pure function 方便手寫 handler（sprite reconcile）也能呼叫、與
// Workbox plugin 行為一致。
function applyHeaders(response: Response): Response {
	const headers = new Headers(response.headers);
	headers.set("Cross-Origin-Opener-Policy", "same-origin");
	headers.set("Cross-Origin-Embedder-Policy", "credentialless");

	const isWasm = (headers.get("Content-Type") ?? "").includes("application/wasm");
	if (isWasm) {
		headers.delete("Content-Encoding");
		headers.delete("Content-Length");
		// 與 non-wasm 同一條路徑：直接 stream forward、不 await
		// arrayBuffer，保留 streaming 優勢。
	}

	const clone = response.clone();
	return new Response(clone.body, {
		status: clone.status,
		statusText: clone.statusText,
		headers,
	});
}

const headersPlugin: WorkboxPlugin = {
	handlerWillRespond: async ({ response }) => applyHeaders(response),
};

// 1. precache：手動掌控 install / activate，每個 cache 都掛 headersPlugin。
const precacheController = new PrecacheController({
	cacheName: "precache",
	plugins: [headersPlugin],
});
precacheController.addToCacheList(PRECACHE_MANIFEST);
registerRoute(new PrecacheRoute(precacheController, {
	ignoreURLParametersMatching: [/.*/],
	cleanURLs: false,
}));

// 2. Sprite 資源版本同步（僅 Web、設計見 docs/sprite-revision.md）：
//
// 每個 sprite 產出檔（sprites.json、images/sprites/*.webp、audio/sprites/*.zip）
// 由 kid-puzzle-sprite build 期算出 SHA-256 前 8 hex、runtime 在 URL 帶
// `?rev=<hash>` query。SW 攔到時：
//   1. 用 path（不含 query）當「身份識別」找 cache 內所有同身份的 entries
//   2. 找到完全相符（path + rev 都一致）→ cache hit、直接回
//   3. 否則走網路抓新版 → 成功後 cache.put 新 entry → 刪所有同身份不同
//      rev 的舊 entries（一定先 put 再 delete、避免 fetch 失敗時連舊版
//      都丟掉）
//
// `sprites_revision.json` 不帶 rev 自身就是「版本指南」、走 network-first：
// 每次嘗試網路、失敗時退回 cache 內最近一份。
//
// 兩個 handler 都 bypass Workbox 預設的 stale-while-revalidate — Workbox 的
// route handler 接管 respondWith 後仍要保留 COOP/COEP headers，因此手動
// 透過 headersPlugin.handlerWillRespond 處理（與其它 handler 一致）。

const SPRITE_CACHE = "sprite-revisioned-v1";

async function handleSpriteFetch(request: Request): Promise<Response> {
	const url = new URL(request.url);
	const idKey = url.pathname;
	const newRev = url.searchParams.get("rev");

	const cache = await caches.open(SPRITE_CACHE);
	const sameIdentity: Request[] = [];
	for (const req of await cache.keys()) {
		const u = new URL(req.url);
		if (u.pathname === idKey) sameIdentity.push(req);
	}

	// 完全相符（path + rev）→ 直接回 cached
	const exact = sameIdentity.find((req) => {
		const u = new URL(req.url);
		return u.searchParams.get("rev") === newRev;
	});
	if (exact) {
		const cached = await cache.match(exact);
		if (cached) return applyHeaders(cached);
	}

	// miss：走網路 → 成功才更新 cache + 刪舊版
	let networkResponse: Response;
	try {
		networkResponse = await fetch(request);
	} catch (err) {
		// 網路失敗時退回任一 same-identity cache（如果有的話），讓使用者至少
		// 還能拿到舊版用、勝過整個 app 因為 sprite 載不到而當掉。
		if (sameIdentity.length > 0) {
			const fallback = await cache.match(sameIdentity[0]);
			if (fallback) return applyHeaders(fallback);
		}
		throw err;
	}
	if (!networkResponse.ok) {
		return applyHeaders(networkResponse);
	}

	// 先 put 新版、再刪舊版（順序顛倒會在失敗時把舊版也丟掉）
	await cache.put(request, networkResponse.clone());
	await Promise.all(sameIdentity.map((req) => cache.delete(req)));
	return applyHeaders(networkResponse);
}

// 路徑 match：assets/data/sprites.json、assets/images/sprites/*、
// assets/audio/sprites/* 三條都走 reconcile。
function isSpriteAssetPath(pathname: string): boolean {
	return /^\/.*\/assets\/(data\/sprites\.json|images\/sprites\/[^/]+|audio\/sprites\/[^/]+)(\?|$)/.test(pathname) ||
		/^\/assets\/(data\/sprites\.json|images\/sprites\/[^/]+|audio\/sprites\/[^/]+)(\?|$)/.test(pathname);
}

registerRoute(
	({ url }) => url.origin === self.location.origin && isSpriteAssetPath(url.pathname),
	({ request }) => handleSpriteFetch(request),
);

// sprites_revision.json 自己走 network-first（不帶 rev、必須每次嘗試網路）。
registerRoute(
	({ url }) =>
		url.origin === self.location.origin &&
		/\/assets\/data\/sprites_revision\.json$/.test(url.pathname),
	new NetworkFirst({
		cacheName: SPRITE_CACHE,
		plugins: [headersPlugin],
	}),
);

// 3. 其它一律 stale-while-revalidate（同 cache 名稱避免與 precache 衝突）。
setDefaultHandler(new StaleWhileRevalidate({
	cacheName: "runtime",
	plugins: [headersPlugin],
}));

self.addEventListener("install", (event) => {
	self.skipWaiting();
	precacheController.install(event);
});

self.addEventListener("activate", (event) => {
	precacheController.activate(event);
});
