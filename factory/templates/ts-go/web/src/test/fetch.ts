import { vi } from 'vitest'

export type Reply = { status?: number; body?: unknown }

// mockFetch replaces fetch until the test ends: each call answers what
// reply returns for its method and path, as JSON. 204 and 304 answer a null
// body, since a Response with those statuses may carry none.
export function mockFetch(reply: (method: string, path: string) => Reply) {
  const fn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(new URL(input instanceof Request ? input.url : String(input), 'http://localhost'), init)
    const { status = 200, body = null } = reply(req.method, new URL(req.url).pathname)
    if (status === 204 || status === 304) return new Response(null, { status })
    return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fn)
  return fn
}
