import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  plugins: [
    {
      name: "remove-crossorigin-for-local-wkwebview",
      transformIndexHtml(html) {
        // The bundle is served by Clair's local WKWebView scheme.  Vite's
        // crossorigin attributes are unnecessary there and can prevent local
        // module/style subresources from loading.
        return html.replace(/ crossorigin/g, "");
      },
    },
  ],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: "index.html",
    },
  },
});
