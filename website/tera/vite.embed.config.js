import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react()],
  root: path.resolve(__dirname, "embed"),
  base: "./",
  build: {
    outDir: path.resolve(__dirname, "../../Nook/Resources/ShaderGradient"),
    emptyOutDir: true,
    sourcemap: false,
    assetsDir: ".",
    rollupOptions: {
      input: path.resolve(__dirname, "embed/shader-gradient.html"),
      output: {
        entryFileNames: "shader-gradient.js",
        chunkFileNames: "shader-gradient-[name].js",
        assetFileNames: "shader-gradient-[name][extname]",
      },
    },
  },
});
