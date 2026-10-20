import { describe, expect, it, vi } from 'vitest';
import { syncWorkspaceToPrivateCloud } from './VaultSyncClient';
import { latestManifest } from '../api/client';
import { ensureVaultDeviceSession } from './VaultEnrollment';
import { loadOrCreateVaultIdentity, saveVaultSyncState } from './VaultKeyStore';

vi.mock('../api/client', () => ({ latestManifest: vi.fn() }));
vi.mock('./VaultEnrollment', () => ({ ensureVaultDeviceSession: vi.fn() }));
vi.mock('./VaultKeyStore', () => ({
  loadOrCreateVaultIdentity: vi.fn(),
  loadVaultSyncState: vi.fn(async () => ({ vaultId: 'vault', files: {} })),
  saveVaultSyncState: vi.fn(async () => {}),
}));

describe('Vault sync cancellation', () => {
  it('stops after an outstanding request returns and clears the working key', async () => {
    const masterKey = new Uint8Array(32).fill(7);
    vi.mocked(loadOrCreateVaultIdentity).mockResolvedValue({ masterKey } as Awaited<ReturnType<typeof loadOrCreateVaultIdentity>>);
    let finish!: (value: Awaited<ReturnType<typeof ensureVaultDeviceSession>>) => void;
    let started!: () => void;
    const waiting = new Promise<void>(resolve => { started = resolve; });
    vi.mocked(ensureVaultDeviceSession).mockImplementation(() => {
      started();
      return new Promise(resolve => { finish = resolve; });
    });
    const controller = new AbortController();
    const sync = syncWorkspaceToPrivateCloud({
      workspaceId: 'test', workspaceName: 'Test', files: [], signal: controller.signal,
    });
    const stopped = expect(sync).rejects.toThrow('cancelled');
    await waiting;
    controller.abort(new Error('cancelled'));
    finish({ token: 'token' } as Awaited<ReturnType<typeof ensureVaultDeviceSession>>);
    await stopped;
    expect(latestManifest).not.toHaveBeenCalled();
    expect(saveVaultSyncState).toHaveBeenCalledTimes(1);
    expect(masterKey.every(byte => byte === 0)).toBe(true);
  });
});
