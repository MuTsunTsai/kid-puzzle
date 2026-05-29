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
import { StaleWhileRevalidate } from "workbox-strategies";
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
const headersPlugin: WorkboxPlugin = {
	handlerWillRespond: async ({ response }) => {
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
	},
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

// 2. 其它一律 stale-while-revalidate（同 cache 名稱避免與 precache 衝突）。
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
