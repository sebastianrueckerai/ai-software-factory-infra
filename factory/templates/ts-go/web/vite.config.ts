import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  base: '/app/',
  plugins: [react()],
  test: {
    environment: 'jsdom',
    unstubGlobals: true,
    setupFiles: ['./src/test/setup.ts'],
  },
})
