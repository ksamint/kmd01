import { afterEach, describe, expect, it, vi } from 'vitest';
import { VaultStorage } from './VaultStorage';

function mockBrowserLocks() {
  const held = new Set<string>();
  vi.stubGlobal('navigator', {
    locks: {
      request: async (name: string, _options: unknown, operation: (lock: { name: string } | null) => Promise<void>) => {
        if (held.has(name)) return operation(null);
        held.add(name);
        try {
          await operation({ name });
        } finally {
          held.delete(name);
        }
      },
    },
  });
  // Isolate the device-key/OPFS setup; exercise the real public lock lifetime.
  const open = vi.spyOn(VaultStorage as unknown as {
    openLocked: (workspaceId: string) => Promise<VaultStorage>;
  }, 'openLocked').mockImplementation(async id => Reflect.construct(VaultStorage, [
    id, undefined, { version: 2, id, name: 'Test', files: [], updatedAt: 0 },
  ]));
  return { held, open };
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('Workspace writer lifetime', () => {
  it('rejects a second instance before recovery and permits reopen after close', async () => {
    const { held, open } = mockBrowserLocks();
    const first = await VaultStorage.open('shared');
    await expect(VaultStorage.open('shared')).rejects.toThrow('already open in another tab');
    expect(open).toHaveBeenCalledTimes(1);
    await first.close();
    const second = await VaultStorage.open('shared');
    expect(open).toHaveBeenCalledTimes(2);
    await second.close();
    expect(held.size).toBe(0);
    await expect(first.createFile('Closed.md')).rejects.toThrow('Workspace is closed');
  });

  it('releases the lock if opening or recovery fails', async () => {
    const { held, open } = mockBrowserLocks();
    open.mockRejectedValueOnce(new Error('Recovery unavailable'));
    await expect(VaultStorage.open('shared')).rejects.toThrow('Recovery unavailable');
    expect(held.size).toBe(0);
    const recovered = await VaultStorage.open('shared');
    await recovered.close();
  });

  it('fails closed when the browser cannot coordinate workspace writers', async () => {
    const { open } = mockBrowserLocks();
    vi.stubGlobal('navigator', {});
    await expect(VaultStorage.open('shared')).rejects.toThrow('requires Web Locks');
    expect(open).not.toHaveBeenCalled();
  });

  it('cancels a stalled sync before releasing the writer lock', async () => {
    const { held } = mockBrowserLocks();
    const first = await VaultStorage.open('shared');
    let entered!: () => void;
    const exchanging = new Promise<void>(resolve => { entered = resolve; });
    const sync = first.synchronize(async () => {
      entered();
      return new Promise<never>(() => {});
    });
    const cancelled = expect(sync).rejects.toThrow('Workspace closed');
    await exchanging;
    await first.close();
    await cancelled;
    expect(held.size).toBe(0);
    const second = await VaultStorage.open('shared');
    await second.close();
  });

  it('waits for admitted writes before allowing a new writer', async () => {
    mockBrowserLocks();
    const first = await VaultStorage.open('shared');
    let finish!: () => void;
    Reflect.set(first, 'writes', new Promise<void>(resolve => { finish = resolve; }));
    const closing = first.close();
    await expect(VaultStorage.open('shared')).rejects.toThrow('already open in another tab');
    finish();
    await closing;
    const second = await VaultStorage.open('shared');
    await second.close();
  });

  it('waits for recovery triggered by a read before releasing the writer', async () => {
    mockBrowserLocks();
    const first = await VaultStorage.open('shared');
    let finish!: () => void;
    Reflect.set(first, 'recovery', new Promise<void>(resolve => { finish = resolve; }));
    const closing = first.close();
    await expect(VaultStorage.open('shared')).rejects.toThrow('already open in another tab');
    finish();
    await closing;
    const second = await VaultStorage.open('shared');
    await second.close();
  });
});
