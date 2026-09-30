import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'

// unmount after every test, so each test renders into an empty document
afterEach(cleanup)
