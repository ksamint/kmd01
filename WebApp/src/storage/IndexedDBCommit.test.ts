import { afterEach, describe, expect, it, vi } from 'vitest';
import { VaultStorage } from './VaultStorage';
import { saveVaultSyncState } from '../security/VaultKeyStore';

// Request success is not durable: the transaction may still abort afterward.
function abortedDatabase() {
  const puts: string[] = [];
  const database = {
    transaction: () => {
      const transaction = {
        error: new Error('Transaction aborted after request success'),
        oncomplete: undefined as (() => void) | undefined,
        onerror: undefined as (() => void) | undefined,
        onabort: undefined as (() => void) | undefined,
        objectStore: () => ({
          put: (_value: unknown, key: string) => {
            puts.push(key);
            const request = { onsuccess: undefined as (() => void) | undefined };
            queueMicrotask(() => {
              request.onsuccess?.();
              transaction.onabort?.();
            });
            return request;
          },
        }),
      };
      return transaction;
    },
  };
  vi.stubGlobal('indexedDB', {
    open: () => {
      const request = { result: database, onsuccess: undefined as (() => void) | undefined };
      queueMicrotask(() => request.onsuccess?.());
      return request;
    },
  });
  return puts;
}

afterEach(() => vi.unstubAllGlobals());

describe('IndexedDB commit boundary', () => {
  it('rejects aborted object writes before attempting the manifest', async () => {
    const puts = abortedDatabase();
    const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    const storage: VaultStorage = Reflect.construct(VaultStorage, [
      'test', key, { version: 2, id: 'test', name: 'Test', files: [], updatedAt: 0 },
    ]);
    await expect(storage.createFile('Note.md', 'unsaved')).rejects.toThrow('Transaction aborted');
    expect(puts).toHaveLength(1);
    expect(puts[0]).not.toContain('manifest.ksv');
  });

  it('does not acknowledge a sync checkpoint whose transaction aborts', async () => {
    abortedDatabase();
    await expect(saveVaultSyncState('test', { sequence: 1, files: {} })).rejects.toThrow('Transaction aborted');
  });
});
