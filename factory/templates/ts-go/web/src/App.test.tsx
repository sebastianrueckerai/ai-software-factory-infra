import { screen } from '@testing-library/react'
import { expect, test } from 'vitest'
import { mockFetch } from './test/fetch'
import { renderAt } from './test/render'

test('home shows the server up', async () => {
  const fetch = mockFetch((method, path) => (method === 'GET' && path === '/healthz' ? { body: { status: 'ok' } } : { status: 404 }))
  renderAt('/')
  expect(screen.getByRole('heading').textContent).toBe('[[.Name]]')
  expect(await screen.findByText('Server: up')).toBeTruthy()
  expect(fetch).toHaveBeenCalledOnce()
})

test('home shows the server down', async () => {
  mockFetch(() => ({ status: 503 }))
  renderAt('/')
  expect(await screen.findByText('Server: down')).toBeTruthy()
  expect(screen.getAllByRole('heading')).toHaveLength(1)
})
