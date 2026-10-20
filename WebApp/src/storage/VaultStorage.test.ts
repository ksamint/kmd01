import { describe, expect, it } from 'vitest';
import { migrateVaultManifest, VaultStorage } from './VaultStorage';

describe('Vault manifest v2 migration', () => {
  it('upgrades v1 Markdown records without changing identities or paths', () => {
    const migrated = migrateVaultManifest({
      version: 1,
      id: 'offline',
      name: 'Personal Workspace',
      updatedAt: 42,
      files: [{ id: 'one', path: 'Café/计划.md', modifiedAt: 41 }],
    });
    expect(migrated).toEqual({
      version: 2,
      id: 'offline',
      name: 'Personal Workspace',
      updatedAt: 42,
      files: [{
        id: 'one',
        path: 'Café/计划.md',
        modifiedAt: 41,
        kind: 'markdown',
        mimeType: 'text/markdown',
        byteSize: 0,
      }],
    });
  });

  it('leaves v2 attachment metadata intact', () => {
    const manifest = {
      version: 2 as const,
      id: 'offline',
      name: 'Personal Workspace',
      updatedAt: 42,
      files: [{
        id: 'asset',
        path: 'Conversations/Assets/hash.png',
        modifiedAt: 41,
        kind: 'attachment' as const,
        mimeType: 'image/png',
        byteSize: 12,
        contentDigest: 'hash',
      }],
    };
    expect(migrateVaultManifest(manifest)).toEqual(manifest);
  });
});

describe('Vault sync cleanup', () => {
  it('keeps removed notes readable if the replacement manifest cannot be saved', async () => {
    const objects = new Map<string, ArrayBuffer>();
    let failManifestWrite = false;
    const directory = {
      getDirectoryHandle: async () => directory,
      getFileHandle: async (name: string) => ({
        getFile: async () => ({ arrayBuffer: async () => objects.get(name) }),
        createWritable: async () => {
          if (name === 'manifest.ksv' && failManifestWrite) {
            throw new Error('Disk full');
          }
          let pending: ArrayBuffer;
          return {
            write: async (payload: ArrayBuffer) => { pending = payload; },
            close: async () => { objects.set(name, pending); },
          };
        },
      }),
      removeEntry: async (name: string) => { objects.delete(name); },
    };
    const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    // Inject an isolated OPFS directory without opening the user's device store.
    const storage: VaultStorage = Reflect.construct(VaultStorage, [
      'test', key, { version: 2, id: 'test', name: 'Test', files: [], updatedAt: 0 }, directory,
    ]);
    const note = await storage.createFile('Keep.md', 'irreplaceable text');
    const manifest = objects.get('manifest.ksv');

    failManifestWrite = true;
    await expect(storage.replaceFiles([])).rejects.toThrow('Disk full');

    expect(objects.get('manifest.ksv')).toBe(manifest);
    expect(objects.has(`${note.id}.ksv`)).toBe(true);
    expect((await storage.readFile(note.id)).content).toBe('irreplaceable text');

    failManifestWrite = false;
    await expect(storage.replaceFiles([])).resolves.toEqual([]);
    expect(storage.listFiles()).toEqual([]);
    expect(objects.has(`${note.id}.ksv`)).toBe(false);
    expect(objects.get('manifest.ksv')).not.toBe(manifest);
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}

async function isolatedStorage() {
  const objects = new Map<string, ArrayBuffer>();
  const faults = {
    beforeRead: async (name: string) => { void name; },
    beforeWrite: async (name: string) => { void name; },
    beforeClose: async (name: string) => { void name; },
    aborts: 0,
    failManifest: false,
    failCleanup: false,
  };
  const directory = {
    getDirectoryHandle: async () => directory,
    getFileHandle: async (name: string) => ({
      getFile: async () => {
        await faults.beforeRead(name);
        return { arrayBuffer: async () => objects.get(name) };
      },
      createWritable: async () => {
        await faults.beforeWrite(name);
        if (name === 'manifest.ksv' && faults.failManifest) throw new Error('Disk full');
        let pending: ArrayBuffer;
        return {
          write: async (payload: ArrayBuffer) => { pending = payload; },
          close: async () => {
            await faults.beforeClose(name);
            objects.set(name, pending);
          },
          abort: async () => { faults.aborts += 1; },
        };
      },
    }),
    removeEntry: async (name: string) => {
      if (faults.failCleanup) throw new Error('Cleanup unavailable');
      objects.delete(name);
    },
  };
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const storage: VaultStorage = Reflect.construct(VaultStorage, [
    'test', key, { version: 2, id: 'test', name: 'Test', files: [], updatedAt: 0 }, directory,
  ]);
  const reopen = async () => {
    const reopened: VaultStorage = Reflect.construct(VaultStorage, [
      'test', key, storage.workspace(), directory,
    ]);
    // Run the same recovery routine used by open(), without a real device-key store.
    await Reflect.get(reopened, 'recoverReplacement').call(reopened);
    return reopened;
  };
  return { storage, objects, faults, reopen };
}

describe('Vault sync mutation boundary', () => {
  it('waits for admitted writes and snapshots the saved large note', async () => {
    const { storage, faults } = await isolatedStorage();
    const note = await storage.createFile('Large.md', 'before');
    const started = deferred<void>();
    const release = deferred<void>();
    faults.beforeWrite = async name => {
      if (name === `${note.id}.ksv`) {
        started.resolve();
        await release.promise;
      }
    };
    const content = '# Saved edit\n' + '新しい text\n'.repeat(25_000);
    expect(new TextEncoder().encode(content).length).toBeGreaterThan(200_000);
    const write = storage.writeFile(note.id, content);
    await started.promise;
    let exchanged = false;
    const sync = storage.synchronize(async snapshot => {
      exchanged = true;
      expect(snapshot.files[0].content).toBe(content);
      return { ...snapshot, conflictRecords: [] };
    });
    expect(exchanged).toBe(false);
    await expect(storage.writeFile(note.id, 'racing edit')).rejects.toThrow('read-only');
    release.resolve();
    await write;
    await sync;
    expect((await storage.readFile(note.id)).content).toBe(content);
  });

  it('blocks every mutation entrypoint and overlapping sync until replacement completes', async () => {
    const { storage } = await isolatedStorage();
    const note = await storage.createFile('Note.md', 'local');
    const started = deferred<void>();
    const release = deferred<void>();
    const sync = storage.synchronize(async snapshot => {
      started.resolve();
      await release.promise;
      return { ...snapshot, conflictRecords: [] };
    });
    await started.promise;
    const attempts = [
      storage.createFile('New.md'), storage.importFiles([]), storage.writeFile(note.id, 'edit'),
      storage.setMetadata(note.id, { tags: ['tag'] }), storage.renameFile(note.id, 'Renamed.md'),
      storage.deleteFile(note.id), storage.writeAttachment({ path: 'asset.png', bytes: new Uint8Array(), mimeType: 'image/png', contentDigest: 'digest' }),
      storage.replaceAttachments([]), storage.writeLocalRecord('undo', 'id', {}, Date.now() + 1000),
      storage.deleteLocalRecord('undo', 'id'), storage.replaceFiles([]), storage.appendConflicts([]),
      storage.resolveConflict('missing', { resolvedAt: 0, strategy: 'local', resultFileId: note.id }),
    ];
    await Promise.all(attempts.map(attempt => expect(attempt).rejects.toThrow('read-only')));
    await expect(storage.synchronize(async snapshot => ({ ...snapshot, conflictRecords: [] }))).rejects.toThrow('already syncing');
    release.resolve();
    await sync;
    await storage.setMetadata(note.id, { tags: ['after'] });
    expect((await storage.readFile(note.id)).metadata.tags).toEqual(['after']);
  });

  it('unlocks on timeout and cannot apply a late result over later edits or a retry', async () => {
    const { storage } = await isolatedStorage();
    const note = await storage.createFile('Note.md', 'old snapshot');
    const started = deferred<void>();
    const release = deferred<void>();
    let signal: AbortSignal | undefined;
    const sync = storage.synchronize(async (snapshot, cancellation) => {
      signal = cancellation;
      started.resolve();
      await release.promise;
      return { ...snapshot, conflictRecords: [] };
    }, 10);
    const failed = expect(sync).rejects.toThrow('timed out');
    await started.promise;
    await failed;
    expect(signal?.aborted).toBe(true);
    await storage.writeFile(note.id, 'new text after timeout');
    await storage.synchronize(async snapshot => ({ ...snapshot, conflictRecords: [] }));
    release.resolve();
    await new Promise(resolve => setTimeout(resolve, 0));
    expect((await storage.readFile(note.id)).content).toBe('new text after timeout');
  });

  it('keeps mutations blocked until an already-started local commit settles', async () => {
    const { storage, faults } = await isolatedStorage();
    const note = await storage.createFile('Note.md', 'before');
    const started = deferred<void>();
    const release = deferred<void>();
    faults.beforeWrite = async name => {
      if (name === `${note.id}.ksv`) {
        started.resolve();
        await release.promise;
      }
    };
    const sync = storage.synchronize(async snapshot => ({
      ...snapshot,
      files: snapshot.files.map(file => ({ ...file, content: 'remote update' })),
      conflictRecords: [],
    }), 10);
    await started.promise;
    await new Promise(resolve => setTimeout(resolve, 20));
    await expect(storage.writeFile(note.id, 'racing edit')).rejects.toThrow('read-only');
    release.resolve();
    await sync;
    expect((await storage.readFile(note.id)).content).toBe('remote update');
    await storage.writeFile(note.id, 'after commit');
  });

  it('unlocks after a failed exchange without replacing local data', async () => {
    const { storage } = await isolatedStorage();
    const note = await storage.createFile('Note.md', 'saved');
    await expect(storage.synchronize(async () => { throw new Error('Offline'); })).rejects.toThrow('Offline');
    expect((await storage.readFile(note.id)).content).toBe('saved');
    await storage.writeFile(note.id, 'editable');
    expect((await storage.readFile(note.id)).content).toBe('editable');
  });

  it('finishes a committed replacement even when orphan cleanup fails', async () => {
    const { storage, objects, faults } = await isolatedStorage();
    const note = await storage.createFile('Removed.md', 'removed');
    faults.failCleanup = true;
    await expect(storage.replaceFiles([])).resolves.toEqual([]);
    expect(storage.listFiles()).toEqual([]);
    expect(objects.has(`${note.id}.ksv`)).toBe(true);
    await storage.createFile('Next.md', 'still editable');
  });

  it('keeps removed attachments readable when the manifest commit fails', async () => {
    const { storage, faults } = await isolatedStorage();
    const attachment = await storage.writeAttachment({
      path: 'Assets/photo.png', bytes: new Uint8Array([1, 2, 3]), mimeType: 'image/png', contentDigest: 'digest',
    });
    faults.failManifest = true;
    await expect(storage.replaceAttachments([])).rejects.toThrow('Disk full');
    expect((await storage.readAttachment(attachment.id)).bytes).toEqual(attachment.bytes);
    faults.failManifest = false;
    faults.failCleanup = true;
    await expect(storage.replaceAttachments([])).resolves.toEqual([]);
    expect(storage.listAllFiles()).toEqual([]);
  });
});

describe('Vault replacement recovery', () => {
  it('restores large same-ID note bytes and metadata if the manifest fails', async () => {
    const { storage, faults } = await isolatedStorage();
    const original = '# Original\n' + 'original text '.repeat(25_000);
    const note = await storage.createFile('Original.md', original);
    const manifest = storage.workspace();
    faults.failManifest = true;
    await expect(storage.replaceFiles([{
      ...note, path: 'Renamed.md', content: 'remote bytes', modifiedAt: 100,
    }])).rejects.toThrow('Disk full');
    expect(storage.workspace()).toEqual(manifest);
    expect((await storage.readFile(note.id)).content).toBe(original);
  });

  it('restores existing attachment bytes and digest if the manifest fails', async () => {
    const { storage, faults } = await isolatedStorage();
    const attachment = await storage.writeAttachment({
      path: 'Assets/a.png', bytes: new Uint8Array([1, 2, 3]), mimeType: 'image/png', contentDigest: 'original',
    });
    faults.failManifest = true;
    await expect(storage.replaceAttachments([{
      ...attachment, path: 'Assets/b.png', bytes: new Uint8Array([4, 5]), contentDigest: 'remote',
    }])).rejects.toThrow('Disk full');
    expect(await storage.readAttachment(attachment.id)).toEqual(attachment);
  });

  it('restores earlier overwritten objects when a later object write fails', async () => {
    const { storage, faults } = await isolatedStorage();
    const first = await storage.createFile('First.md', 'first original');
    const second = await storage.createFile('Second.md', 'second original');
    let failed = false;
    faults.beforeWrite = async name => {
      if (name === `${second.id}.ksv` && !failed) {
        failed = true;
        throw new Error('Object write failed');
      }
    };
    await expect(storage.replaceFiles([first, second].map(file => ({ ...file, content: 'remote' })))).rejects.toThrow('Object write failed');
    expect((await storage.readFile(first.id)).content).toBe(first.content);
    expect((await storage.readFile(second.id)).content).toBe(second.content);
  });

  it('aborts a failed OPFS stream before recovering original content', async () => {
    const { storage, faults } = await isolatedStorage();
    const note = await storage.createFile('Note.md', 'original');
    let failed = false;
    faults.beforeClose = async name => {
      if (name === `${note.id}.ksv` && !failed) {
        failed = true;
        throw new Error('Close failed');
      }
    };
    await expect(storage.replaceFiles([{ ...note, content: 'remote' }])).rejects.toThrow('Close failed');
    expect(faults.aborts).toBe(1);
    expect((await storage.readFile(note.id)).content).toBe('original');
  });

  it('keeps the durable preimage and blocks writes until failed rollback can recover after reopen', async () => {
    const { storage, objects, faults, reopen } = await isolatedStorage();
    const note = await storage.createFile('Original.md', 'original bytes');
    const originalObject = objects.get(`${note.id}.ksv`);
    let writes = 0;
    faults.beforeWrite = async name => {
      if (name === `${note.id}.ksv` && ++writes > 1) throw new Error('Restore unavailable');
    };
    faults.failManifest = true;
    await expect(storage.replaceFiles([{ ...note, content: 'remote bytes' }])).rejects.toThrow('Sync recovery is pending');
    expect(new Uint8Array(objects.get(`${note.id}.ksv`)!)).not.toEqual(new Uint8Array(originalObject!));
    expect(objects.has('sync-recovery.ksv')).toBe(true);
    await expect(storage.createFile('Forbidden.md')).rejects.toThrow('could not yet be restored');
    expect(storage.listFiles().some(file => file.path === 'Forbidden.md')).toBe(false);
    faults.beforeWrite = async () => {};
    faults.failManifest = false;
    const recovered = await reopen();
    expect((await recovered.readFile(note.id)).content).toBe('original bytes');
    expect(new Uint8Array(objects.get(`${note.id}.ksv`)!)).toEqual(new Uint8Array(originalObject!));
    await recovered.createFile('Recovered.md');
  });

  it('recovers a persisted snapshot interrupted between object writes', async () => {
    const { storage, objects, faults, reopen } = await isolatedStorage();
    const first = await storage.createFile('First.md', 'first original');
    const second = await storage.createFile('Second.md', 'second original');
    let interrupted: Map<string, ArrayBuffer> | undefined;
    faults.beforeWrite = async name => {
      if (name === `${second.id}.ksv` && !interrupted) {
        interrupted = new Map(objects);
        throw new Error('Interrupted');
      }
    };
    await expect(storage.replaceFiles([first, second].map(file => ({ ...file, content: 'remote' })))).rejects.toThrow('Interrupted');
    expect(interrupted).toBeDefined();
    objects.clear();
    for (const [name, bytes] of interrupted!) objects.set(name, bytes);
    const recovered = await reopen();
    expect((await recovered.readFile(first.id)).content).toBe(first.content);
    expect((await recovered.readFile(second.id)).content).toBe(second.content);
  });

  it('preserves committed data when journal cleanup fails and recovery reopens it', async () => {
    const { storage, faults, reopen } = await isolatedStorage();
    const note = await storage.createFile('Original.md', 'original');
    let journalWrites = 0;
    faults.beforeWrite = async name => {
      if (name === 'sync-recovery.ksv' && ++journalWrites > 1) throw new Error('Journal cleanup failed');
    };
    await expect(storage.replaceFiles([{ ...note, path: 'Committed.md', content: 'committed' }])).rejects.toThrow('Journal cleanup failed');
    await expect(storage.writeFile(note.id, 'must not overwrite recovery')).rejects.toThrow('Journal cleanup failed');
    faults.beforeWrite = async () => {};
    const recovered = await reopen();
    expect((await recovered.readFile(note.id)).path).toBe('Committed.md');
    expect((await recovered.readFile(note.id)).content).toBe('committed');
  });

  it('advances sync state only after local replacement succeeds', async () => {
    const { storage, faults } = await isolatedStorage();
    const note = await storage.createFile('Original.md', 'original');
    let commits = 0;
    const exchange = async () => ({
      files: [{ ...note, content: 'remote' }], attachments: [], conflictRecords: [],
      commitSyncState: async () => { commits += 1; },
    });
    faults.failManifest = true;
    await expect(storage.synchronize(exchange)).rejects.toThrow('Disk full');
    expect(commits).toBe(0);
    faults.failManifest = false;
    await storage.synchronize(exchange);
    expect(commits).toBe(1);
    expect((await storage.readFile(note.id)).content).toBe('remote');
  });

  it('refuses replacement when the original encrypted bytes cannot be read', async () => {
    const { storage, objects, faults } = await isolatedStorage();
    const note = await storage.createFile('Original.md', 'original');
    const before = new Map(objects);
    faults.beforeRead = async name => {
      if (name === `${note.id}.ksv`) throw new DOMException('Read denied', 'NotAllowedError');
    };
    await expect(storage.replaceFiles([{ ...note, content: 'remote' }])).rejects.toThrow('Read denied');
    expect(objects).toEqual(before);
  });

  it('does not bypass an unreadable recovery journal', async () => {
    const { storage, faults, reopen } = await isolatedStorage();
    const note = await storage.createFile('Original.md', 'original');
    let journalWrites = 0;
    faults.beforeWrite = async name => {
      if (name === 'sync-recovery.ksv' && ++journalWrites > 1) throw new Error('Cleanup unavailable');
    };
    await expect(storage.replaceFiles([{ ...note, content: 'committed' }])).rejects.toThrow('Cleanup unavailable');
    faults.beforeWrite = async () => {};
    faults.beforeRead = async name => {
      if (name === 'sync-recovery.ksv') throw new DOMException('Journal read denied', 'NotAllowedError');
    };
    await expect(storage.writeFile(note.id, 'unsafe')).rejects.toThrow('Journal read denied');
    await expect(reopen()).rejects.toThrow('Journal read denied');
    faults.beforeRead = async () => {};
    const recovered = await reopen();
    expect((await recovered.readFile(note.id)).content).toBe('committed');
  });
});
