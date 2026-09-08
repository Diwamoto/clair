import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { viteSingleFile } from 'vite-plugin-singlefile';

// The mock ships as one self-contained HTML file so it can be opened from a
// phone through a published URL without any server of its own.
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  build: { target: 'es2022', assetsInlineLimit: 100000000, cssCodeSplit: false },
});
