// 本地預覽 build/web，並把 base path 設成 /kid-puzzle/，與 GitHub Pages
// 線上環境路徑結構一致。
//
// 用 polka mount sirv 在 /kid-puzzle/ 下 — polka 自動 strip prefix、
// sirv 處理 MIME / range / ETag / directory traversal 等。
//
// 啟動：pnpm preview → http://localhost:4173/kid-puzzle/

import polka from "polka";
import sirv from "sirv";

const PORT = 4173;
const BASE = "/kid-puzzle/";

polka()
	.get("/", (_req, res) => {
		// 根路徑直接轉址到 base，避免訪問 / 時看到 404
		res.writeHead(302, { Location: BASE });
		res.end();
	})
	.use(BASE, sirv("build/web", { single: true, dev: true }))
	.listen(PORT, () => {
		console.log(`→ http://localhost:${PORT}${BASE}`);
	});
