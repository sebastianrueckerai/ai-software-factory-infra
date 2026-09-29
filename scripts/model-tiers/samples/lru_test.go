package lru

import "testing"

func TestPutEvictsTheOldest(t *testing.T) {
	c := New(2)
	c.Put("a", 1)
	c.Put("b", 2)
	c.Put("c", 3)
	if _, ok := c.Get("a"); ok {
		t.Fatal("a survived; it was the least recently used")
	}
	if v, ok := c.Get("c"); !ok || v != 3 {
		t.Fatalf("c = %d, %v", v, ok)
	}
}

func TestGetMakesAnEntryRecent(t *testing.T) {
	c := New(2)
	c.Put("a", 1)
	c.Put("b", 2)
	if v, ok := c.Get("a"); !ok || v != 1 {
		t.Fatalf("a = %d, %v", v, ok)
	}
	c.Put("c", 3)
	if _, ok := c.Get("b"); ok {
		t.Fatal("b survived; after Get(a) it was the least recently used")
	}
	if v, ok := c.Get("a"); !ok || v != 1 {
		t.Fatalf("a was evicted: %d, %v", v, ok)
	}
}

func TestPutUpdatesInPlace(t *testing.T) {
	c := New(2)
	c.Put("a", 1)
	c.Put("b", 2)
	c.Put("a", 10)
	c.Put("c", 3)
	if v, ok := c.Get("a"); !ok || v != 10 {
		t.Fatalf("a = %d, %v", v, ok)
	}
	if _, ok := c.Get("b"); ok {
		t.Fatal("b survived")
	}
}
