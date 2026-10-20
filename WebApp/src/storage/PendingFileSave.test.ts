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
