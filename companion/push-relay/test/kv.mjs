// A KV namespace in memory, as much of one as the relay uses. Expiry is kept, not enforced.
export class MemoryKV {
  constructor() {
    this.map = new Map();
    this.ttl = new Map();
  }
  async get(key) {
    return this.map.has(key) ? this.map.get(key) : null;
  }
  async put(key, value, options = {}) {
    this.map.set(key, String(value));
    this.ttl.set(key, options.expirationTtl ?? null);
  }
  async delete(key) {
    this.map.delete(key);
    this.ttl.delete(key);
  }
  async list({ prefix = "" } = {}) {
    return { keys: [...this.map.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })) };
  }
}
