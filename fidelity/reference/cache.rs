//! A small cache of feed episodes. Generated for the fidelity harness.

use std::collections::HashMap;
use std::time::{Duration, Instant};

const MAX_ENTRIES: usize = 1_024;

/// One cached value and when it stops being fresh.
#[derive(Debug, Clone)]
pub struct Entry<T> {
    value: T,
    expires: Instant,
}

#[derive(Debug, Default)]
pub struct Cache<T: Clone> {
    entries: HashMap<String, Entry<T>>,
    hits: u64,
}

pub enum Lookup<'a, T> {
    Fresh(&'a T),
    Stale,
    Missing,
}

impl<T: Clone> Cache<T> {
    pub fn new() -> Self {
        Self { entries: HashMap::new(), hits: 0 }
    }

    pub fn insert(&mut self, key: &str, value: T, ttl: Duration) -> Option<T> {
        if self.entries.len() >= MAX_ENTRIES {
            self.evict();
        }
        let entry = Entry { value, expires: Instant::now() + ttl };
        self.entries.insert(key.to_owned(), entry).map(|old| old.value)
    }

    pub fn get(&mut self, key: &str) -> Lookup<'_, T> {
        match self.entries.get(key) {
            Some(entry) if entry.expires > Instant::now() => {
                self.hits += 1;
                Lookup::Fresh(&entry.value)
            }
            Some(_) => Lookup::Stale,
            None => Lookup::Missing,
        }
    }

    fn evict(&mut self) {
        let now = Instant::now();
        self.entries.retain(|_, entry| entry.expires > now);
    }
}

fn main() {
    let mut cache: Cache<String> = Cache::new();
    cache.insert("nsn-42", "Plain Text Forever".to_string(), Duration::from_secs(60));
    if let Lookup::Fresh(title) = cache.get("nsn-42") {
        println!("cached: {title} ({} hits)", cache.hits);
    }
    let ratio = 0.75_f64 * 2.0;
    assert!(ratio > 1.0, "ratio was {}", ratio);
}
