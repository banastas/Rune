// A small typed store, generated for the fidelity harness.
import { EventEmitter } from "node:events";
import type { Feed, Episode } from "./types";

export enum Status {
  Idle = "idle",
  Loading = "loading",
  Failed = "failed",
}

export interface StoreOptions {
  readonly url: string;
  retries?: number;
  onChange?: (feeds: Feed[]) => void;
}

type Cache<T> = Map<string, { value: T; expires: number }>;

const DEFAULT_RETRIES = 3;

export class FeedStore<T extends Feed = Feed> extends EventEmitter {
  private status: Status = Status.Idle;
  private readonly cache: Cache<T> = new Map();
  static instances = 0;

  constructor(private options: StoreOptions) {
    super();
    FeedStore.instances += 1;
  }

  get loading(): boolean {
    return this.status === Status.Loading;
  }

  async load(id: string, force = false): Promise<T | undefined> {
    const hit = this.cache.get(id);
    if (hit && hit.expires > Date.now() && !force) {
      return hit.value;
    }
    this.status = Status.Loading;
    for (let attempt = 0; attempt < (this.options.retries ?? DEFAULT_RETRIES); attempt++) {
      try {
        const response = await fetch(`${this.options.url}/feeds/${id}`);
        const feed = (await response.json()) as T;
        this.cache.set(id, { value: feed, expires: Date.now() + 60_000 });
        this.status = Status.Idle;
        return feed;
      } catch (error: unknown) {
        console.warn("retrying", attempt, error);
      }
    }
    this.status = Status.Failed;
    return undefined;
  }

  latest(feed: T, count: number): Episode[] {
    return feed.episodes.filter((episode) => !episode.hidden).slice(0, count);
  }
}

export function isFeed(value: unknown): value is Feed {
  return typeof value === "object" && value !== null && "episodes" in value;
}
