import { useEffect, useState } from 'react'
import type { RouteObject } from 'react-router'

function Home() {
  const [status, setStatus] = useState('checking')
  useEffect(() => {
    fetch('/healthz')
      .then((res) => setStatus(res.ok ? 'up' : 'down'))
      .catch(() => setStatus('down'))
  }, [])
  return (
    <main>
      <h1>[[.Name]]</h1>
      <p>Server: {status}</p>
    </main>
  )
}

// The app's pages; main.tsx serves them under /app, tests through renderAt.
export const routes: RouteObject[] = [{ path: '/', element: <Home /> }]
