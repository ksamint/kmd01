import { describe, expect, it, vi } from 'vitest';
import { PendingFileSave } from './PendingFileSave';

describe('PendingFileSave', () => {
  it('flushes queued editor text before a workspace mutation continues', async () => {
    const writes: string[] = [];
    const saved: string[] = [];
    const coordinator = new PendingFileSave(
      async (_fileId, content) => {
        writes.push(content);
        return content;
      },
      value => saved.push(value),
      () => undefined,
      () => undefined,
      60_000,
    );

    coordinator.queue('note', 'newest editor text');
    await coordinator.flush();

    expect(writes).toEqual(['newest editor text']);
    expect(saved).toEqual(['newest editor text']);
  });

  it('does not replace newer in-memory text when an older write finishes', async () => {
    let release: (() => void) | undefined;
    const firstWrite = new Promise<void>(resolve => { release = resolve; });
    const saved = vi.fn();
    let writes = 0;
    const coordinator = new PendingFileSave(
      async (_fileId, content) => {
        writes += 1;
        if (writes === 1) await firstWrite;
        return content;
      },
      saved,
      () => undefined,
      () => undefined,
      60_000,
    );

    coordinator.queue('note', 'first');
    const flushing = coordinator.flush();
    coordinator.queue('note', 'second');
    release?.();
    await flushing;

    expect(saved).not.toHaveBeenCalled();
    await coordinator.flush();
    expect(saved).toHaveBeenCalledWith('second', { fileId: 'note', content: 'second' });
  });

  it('keeps later workspace mutations behind an in-flight editor write', async () => {
    let release: (() => void) | undefined;
    const blockedWrite = new Promise<void>(resolve => { release = resolve; });
    const coordinator = new PendingFileSave(
      async () => {
        await blockedWrite;
        return 'saved';
      },
      () => undefined,
      () => undefined,
      () => undefined,
      60_000,
    );
    coordinator.queue('note', 'new text');
    const editorWrite = coordinator.flush();
    let barrierFinished = false;
    const mutationBarrier = coordinator.flush().then(() => { barrierFinished = true; });

    await Promise.resolve();
    expect(barrierFinished).toBe(false);
    release?.();
    await Promise.all([editorWrite, mutationBarrier]);
    expect(barrierFinished).toBe(true);
  });
});

describe('PendingFileSave across files', () => {
  it('flushes a pending edit for another file instead of discarding it', async () => {
    const writes: Array<[string, string]> = [];
    const coordinator = new PendingFileSave(
      async (fileId, content) => {
        writes.push([fileId, content]);
        return content;
      },
      () => undefined,
      () => undefined,
      () => undefined,
      60_000,
    );

    coordinator.queue('a', 'text of a');
    coordinator.queue('b', 'text of b');
    await coordinator.flush();

    expect(writes).toEqual([['a', 'text of a'], ['b', 'text of b']]);
  });
});

describe('PendingFileSave failures across files', () => {
  it('retains failed A while B is queued, then saves both on retry', async () => {
    const persisted = new Map<string, string>();
    let release!: () => void;
    const blocked = new Promise<void>(resolve => { release = resolve; });
    let started!: () => void;
    const writing = new Promise<void>(resolve => { started = resolve; });
    let fail = true;
    const saving = vi.fn();
    const coordinator = new PendingFileSave(
      async (id, content) => {
        if (id === 'a' && fail) {
          started();
          await blocked;
          throw new Error('Disk unavailable');
        }
        persisted.set(id, content);
        return content;
      },
      () => undefined, saving, () => undefined, 60_000,
    );
    coordinator.queue('a', 'unsaved A');
    const failed = expect(coordinator.flush()).rejects.toThrow('Disk unavailable');
    await writing;
    coordinator.queue('b', 'unsaved B');
    release();
    await failed;
    expect(saving).toHaveBeenLastCalledWith(true);
    await expect(coordinator.flush()).rejects.toThrow('Disk unavailable');
    fail = false;
    await coordinator.flush();
    expect([...persisted]).toEqual([['a', 'unsaved A'], ['b', 'unsaved B']]);
    expect(saving).toHaveBeenLastCalledWith(false);
  });

  it('keeps newer text for A when an older in-flight write fails', async () => {
    let release!: () => void;
    const blocked = new Promise<void>(resolve => { release = resolve; });
    let started!: () => void;
    const writing = new Promise<void>(resolve => { started = resolve; });
    let fail = true;
    const saved = vi.fn();
    const coordinator = new PendingFileSave(
      async (_id, content) => {
        if (fail) {
          started();
          await blocked;
          throw new Error('Disk unavailable');
        }
        return content;
      }, saved, () => undefined, () => undefined, 60_000,
    );
    coordinator.queue('a', 'older A');
    const failed = expect(coordinator.flush()).rejects.toThrow('Disk unavailable');
    await writing;
    coordinator.queue('a', 'newer A');
    release();
    await failed;
    fail = false;
    await coordinator.flush();
    expect(saved).toHaveBeenCalledExactlyOnceWith('newer A', { fileId: 'a', content: 'newer A' });
  });
});
