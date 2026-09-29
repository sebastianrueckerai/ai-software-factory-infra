package lru

import "container/list"

// Cache is a least-recently-used cache of ints with a fixed capacity.
type Cache struct {
	capacity int
	order    *list.List // front: most recently used
	items    map[string]*list.Element
}

type entry struct {
	key   string
	value int
}

func New(capacity int) *Cache {
	return &Cache{capacity: capacity, order: list.New(), items: map[string]*list.Element{}}
}

// Get returns the value of key and marks it as the most recently used.
func (c *Cache) Get(key string) (int, bool) {
	if e, ok := c.items[key]; ok {
		return e.Value.(*entry).value, true
	}
	return 0, false
}

// Put stores value under key; when the cache is full it evicts the least
// recently used entry.
func (c *Cache) Put(key string, value int) {
	if e, ok := c.items[key]; ok {
		e.Value.(*entry).value = value
		c.order.MoveToFront(e)
		return
	}
	c.items[key] = c.order.PushFront(&entry{key: key, value: value})
	if c.order.Len() > c.capacity {
		last := c.order.Back()
		c.order.Remove(last)
		delete(c.items, last.Value.(*entry).key)
	}
}
