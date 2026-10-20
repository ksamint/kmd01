import {
  createVault,
  latestManifest,
  listVaults,
  listVaultObjects,
  registerObject,
  requestTemporaryCosGrant,
  uploadManifest,
  type LatestManifest,
  type TemporaryCosGrant,
  type VaultObjectSummary,
} from '../api/client';
import { parseMetadata } from '../markdown/metadata';
import type { AttachmentFile, ConflictRecord, NoteFile } from '../types';
import {
  decodeAndVerifySignedManifest,
  decodeVaultObject,
  encodeVaultObject,
  hex,
  openVaultObject,
  openVaultPath,
  sealVaultObject,
  sealVaultPath,
  signVaultManifest,
  unhex,
  type VaultManifestEntry,
  type VaultTombstone,
} from './vaultProtocol';
import {
  loadOrCreateVaultIdentity,
  loadVaultSyncState,
  saveVaultSyncState,
  type VaultSyncState,
} from './VaultKeyStore';
import { ensureVaultDeviceSession } from './VaultEnrollment';
import { prepareRecoveryPackage, VaultRecoverySetupRequiredError } from './VaultRecovery';
import { mergeWorkspaceFiles } from './VaultMerge';

export type VaultSyncReport = {
  vaultId: string;
  sequence: number;
  uploadedObjects: number;
  downloadedObjects: number;
  unchangedObjects: number;
  tombstones: number;
  conflicts: number;
  conflictRecords: ConflictRecord[];
  files: NoteFile[];
  attachments: AttachmentFile[];
  commitSyncState: () => Promise<void>;
};

export async function syncWorkspaceToPrivateCloud({
  workspaceId,
  workspaceName,
  files,
  attachments = [],
  signal,
}: {
  workspaceId: string;
  workspaceName: string;
  files: NoteFile[];
  attachments?: AttachmentFile[];
  signal?: AbortSignal;
}): Promise<VaultSyncReport> {
  signal?.throwIfAborted();
  const identity = await loadOrCreateVaultIdentity(workspaceId);
  try {
    signal?.throwIfAborted();
    const state = await loadVaultSyncState(workspaceId);
    signal?.throwIfAborted();
    const vaultId = await resolveVaultID(state, workspaceName);
    signal?.throwIfAborted();
    state.vaultId = vaultId;
    await saveVaultSyncState(workspaceId, state);
    signal?.throwIfAborted();
    const deviceSession = await ensureVaultDeviceSession({ workspaceId, vaultId });
    signal?.throwIfAborted();
    const remoteManifest = await latestManifest(vaultId, deviceSession.token);
    signal?.throwIfAborted();
    if (!remoteManifest && !state.recoveryConfigured) {
      const setup = await prepareRecoveryPackage(workspaceId, vaultId);
      signal?.throwIfAborted();
      throw new VaultRecoverySetupRequiredError(
        setup.recoveryPackage,
        setup.challenge,
        deviceSession.token,
      );
    }

    if (!remoteManifest && state.previousDigest) {
      throw new Error('The remote Vault history is unavailable; upload was stopped');
    }
    let workingFiles = files;
    let workingAttachments = attachments;
    let parentState = state;
    let downloadedObjects = 0;
    let conflicts = 0;
    let conflictRecords: ConflictRecord[] = [];
    let grant: TemporaryCosGrant | undefined;
    if (remoteManifest && remoteManifest.digest !== state.previousDigest) {
      grant = await requestTemporaryCosGrant(vaultId, deviceSession.token);
      signal?.throwIfAborted();
      const catalog = await listVaultObjects(vaultId, deviceSession.token);
      signal?.throwIfAborted();
      const remote = await loadRemoteSnapshot({
        vaultId,
        manifest: remoteManifest,
        catalog,
        grant,
        masterKey: identity.masterKey,
        localFiles: files,
        localAttachments: attachments,
        localState: state,
      });
      signal?.throwIfAborted();
      const base = await loadBaseSnapshot({
        state,
        localFiles: files,
        remoteFiles: remote.files,
        catalog,
        grant,
        masterKey: identity.masterKey,
      });
      signal?.throwIfAborted();
      downloadedObjects = remote.downloadedObjects + base.downloadedObjects;
      const merged = mergeWorkspaceFiles({
        base: base.files,
        local: files,
        remote: remote.files,
        remoteLabel: `Remote manifest #${remoteManifest.sequence}`,
      });
      workingFiles = merged.files;
      workingAttachments = mergeAttachments(attachments, remote.attachments);
      conflicts = merged.conflicts;
      conflictRecords = merged.conflictRecords;
      parentState = remote.state;
      if (
        sameWorkspace(workingFiles, remote.files)
        && sameAttachments(workingAttachments, remote.attachments)
      ) {
        return {
          commitSyncState: () => saveVaultSyncState(workspaceId, remote.state),
          vaultId,
          sequence: remoteManifest.sequence,
          uploadedObjects: 0,
          downloadedObjects,
          unchangedObjects: workingFiles.length + workingAttachments.length,
          tombstones: 0,
          conflicts,
          conflictRecords,
          files: workingFiles,
          attachments: workingAttachments,
        };
      }
    }

    const sequence = (remoteManifest?.sequence ?? 0) + 1;
    const previousDigest = remoteManifest?.digest;
    grant ??= await requestTemporaryCosGrant(vaultId, deviceSession.token);
    signal?.throwIfAborted();
    const nextState: VaultSyncState = {
      vaultId,
      sequence,
      previousDigest,
      files: { ...parentState.files },
    };
    const sortedFiles = [...workingFiles, ...workingAttachments].sort((left, right) => (
      left.path.localeCompare(right.path)
    ));
    const prepared = await mapConcurrent(sortedFiles, 4, async file => (
      prepareFile(identity.masterKey, file, parentState)
    ));
    signal?.throwIfAborted();
    let uploadedObjects = 0;
    const entries: VaultManifestEntry[] = [];
    for (const item of prepared) {
      if (item.object) {
        const objectKey = `vaults/${vaultId}/objects/${item.versionId}`;
        await uploadCosObject(grant, objectKey, item.object);
        signal?.throwIfAborted();
        await registerObject({
          vaultId,
          objectId: item.versionId,
          kind: item.kind,
          cipherSize: item.object.length,
          digest: item.objectDigest,
          deviceToken: deviceSession.token,
        });
        signal?.throwIfAborted();
        uploadedObjects += 1;
      }
      const encryptedPath = await sealVaultPath({
        masterKey: identity.masterKey,
        fileId: item.file.id,
        path: item.file.path,
      });
      signal?.throwIfAborted();
      entries.push({
        fileId: item.file.id,
        currentVersionId: item.versionId,
        encryptedPath,
        objectDigest: unhex(item.objectDigest),
        byteSize: item.byteSize,
        modifiedUnixMs: Math.max(0, Math.floor(item.file.modifiedAt)),
      });
      nextState.files[item.file.id] = {
        versionId: item.versionId,
        parentVersionId: item.parentVersionId,
        contentDigest: item.contentDigest,
        objectDigest: item.objectDigest,
        byteSize: item.byteSize,
        path: item.file.path,
        kind: item.kind,
        mimeType: item.mimeType,
      };
    }
    const activeFileIDs = new Set([...workingFiles, ...workingAttachments].map(file => file.id));
    const tombstones: VaultTombstone[] = Object.entries(parentState.files)
      .filter(([fileId]) => !activeFileIDs.has(fileId))
      .map(([fileId, value]) => ({
        fileId,
        deletedVersionId: value.versionId,
        deletedUnixMs: Date.now(),
      }));
    for (const tombstone of tombstones) {
      delete nextState.files[tombstone.fileId];
    }
    const signedManifest = await signVaultManifest(
      {
        vaultId,
        sequence,
        previousManifestDigest: previousDigest ? unhex(previousDigest) : undefined,
        entries,
        tombstones,
      },
      identity.signingPrivateKey,
      identity.signingPublicKey,
    );
    signal?.throwIfAborted();
    const digest = await sha256Hex(signedManifest);
    signal?.throwIfAborted();
    await uploadCosObject(
      grant,
      `vaults/${vaultId}/manifests/${sequence}.cbor`,
      signedManifest,
    );
    signal?.throwIfAborted();
    await uploadManifest({
      vaultId,
      sequence,
      previousDigest,
      digest,
      signedCbor: base64(signedManifest),
      deviceToken: deviceSession.token,
    });
    signal?.throwIfAborted();
    nextState.previousDigest = digest;
    return {
      commitSyncState: () => saveVaultSyncState(workspaceId, nextState),
      vaultId,
      sequence,
      uploadedObjects,
      downloadedObjects,
      unchangedObjects: workingFiles.length + workingAttachments.length - uploadedObjects,
      tombstones: tombstones.length,
      conflicts,
      conflictRecords,
      files: workingFiles,
      attachments: workingAttachments,
    };
  } finally {
    identity.masterKey.fill(0);
  }
}

export function assertDeviceAuthorized(
  syncAuthorized: boolean,
  remoteManifest: LatestManifest | undefined,
) {
  if (!syncAuthorized && remoteManifest) {
    throw new Error(
      'This Vault already contains encrypted data. Authorize this device from an existing device or restore its Vault key before syncing.',
    );
  }
}

type RemoteSnapshot = {
  files: NoteFile[];
  attachments: AttachmentFile[];
  state: VaultSyncState;
  downloadedObjects: number;
};

async function loadRemoteSnapshot({
  vaultId,
  manifest,
  catalog,
  grant,
  masterKey,
  localFiles,
  localAttachments,
  localState,
}: {
  vaultId: string;
  manifest: LatestManifest;
  catalog: VaultObjectSummary[];
  grant: TemporaryCosGrant;
  masterKey: Uint8Array;
  localFiles: NoteFile[];
  localAttachments: AttachmentFile[];
  localState: VaultSyncState;
}): Promise<RemoteSnapshot> {
  const signedBytes = unbase64(manifest.signedCbor);
  if (await sha256Hex(signedBytes) !== manifest.digest) {
    throw new Error('Remote manifest digest verification failed');
  }
  const signed = await decodeAndVerifySignedManifest(signedBytes);
  if (
    signed.manifest.vaultId !== vaultId
    || signed.manifest.sequence !== manifest.sequence
    || optionalDigest(signed.manifest.previousManifestDigest) !== manifest.previousDigest
  ) {
    throw new Error('Remote manifest identity or parent is invalid');
  }
  const objectByID = new Map(catalog.map(object => [object.objectId, object]));
  const localByID = new Map([...localFiles, ...localAttachments].map(file => [file.id, file]));
  const loaded = await mapConcurrent(signed.manifest.entries, 4, async entry => {
    const path = await openVaultPath({
      masterKey,
      fileId: entry.fileId,
      value: entry.encryptedPath,
    });
    const previous = localState.files[entry.fileId];
    const local = localByID.get(entry.fileId);
    const metadata = objectByID.get(entry.currentVersionId);
    if (!metadata) {
      throw new Error(`Remote object ${entry.currentVersionId} is missing from the catalog`);
    }
    if (metadata.kind !== 'markdown' && metadata.kind !== 'attachment') {
      throw new Error(`Remote object ${entry.currentVersionId} has an unsupported workspace kind`);
    }
    let parentVersionId: string | undefined;
    let downloaded = false;
    let file: NoteFile | AttachmentFile;
    let contentDigest: string;
    if (metadata.kind === 'attachment') {
      const localAttachment = local?.kind === 'attachment' ? local as AttachmentFile : undefined;
      let bytes: Uint8Array;
      let mimeType = previous?.mimeType ?? localAttachment?.mimeType ?? 'application/octet-stream';
      if (
        localAttachment
        && previous?.versionId === entry.currentVersionId
        && await sha256Hex(localAttachment.bytes) === previous.contentDigest
      ) {
        bytes = localAttachment.bytes;
        parentVersionId = previous.parentVersionId;
      } else {
        const opened = await downloadAttachment({ entry, metadata, grant, masterKey });
        bytes = opened.bytes;
        mimeType = opened.mimeType;
        parentVersionId = opened.parentVersionId;
        downloaded = true;
      }
      contentDigest = await sha256Hex(bytes);
      file = {
        id: entry.fileId,
        path,
        bytes,
        modifiedAt: entry.modifiedUnixMs,
        kind: 'attachment',
        mimeType,
        byteSize: bytes.length,
        contentDigest,
      };
    } else {
      const localNote = local?.kind !== 'attachment' ? local as NoteFile | undefined : undefined;
      let content: string;
      if (
        localNote
        && previous?.versionId === entry.currentVersionId
        && await sha256Text(localNote.content) === previous.contentDigest
      ) {
        content = localNote.content;
        parentVersionId = previous.parentVersionId;
      } else {
        const opened = await downloadMarkdown({ entry, metadata, grant, masterKey });
        content = opened.content;
        parentVersionId = opened.parentVersionId;
        downloaded = true;
      }
      contentDigest = await sha256Text(content);
      file = {
        id: entry.fileId,
        path,
        content,
        modifiedAt: entry.modifiedUnixMs,
        kind: 'markdown',
        mimeType: 'text/markdown',
        byteSize: new TextEncoder().encode(content).length,
        metadata: parseMetadata(content),
      };
    }
    return {
      file,
      version: {
        versionId: entry.currentVersionId,
        parentVersionId,
        path,
        contentDigest,
        objectDigest: hex(entry.objectDigest),
        byteSize: entry.byteSize,
        kind: metadata.kind,
        mimeType: file.mimeType,
      },
      downloaded,
    };
  });
  return {
    files: loaded.filter(value => value.file.kind !== 'attachment').map(value => value.file as NoteFile),
    attachments: loaded.filter(value => value.file.kind === 'attachment').map(value => value.file as AttachmentFile),
    state: {
      vaultId,
      sequence: manifest.sequence,
      previousDigest: manifest.digest,
      files: Object.fromEntries(loaded.map(value => [value.file.id, value.version])),
    },
    downloadedObjects: loaded.filter(value => value.downloaded).length,
  };
}

async function loadBaseSnapshot({
  state,
  localFiles,
  remoteFiles,
  catalog,
  grant,
  masterKey,
}: {
  state: VaultSyncState;
  localFiles: NoteFile[];
  remoteFiles: NoteFile[];
  catalog: VaultObjectSummary[];
  grant: TemporaryCosGrant;
  masterKey: Uint8Array;
}): Promise<{ files: NoteFile[]; downloadedObjects: number }> {
  const localByID = new Map(localFiles.map(file => [file.id, file]));
  const remoteByID = new Map(remoteFiles.map(file => [file.id, file]));
  const objectByID = new Map(catalog.map(object => [object.objectId, object]));
  const loaded = await mapConcurrent(Object.entries(state.files), 4, async ([fileId, version]) => {
    const catalogObject = objectByID.get(version.versionId);
    if (version.kind === 'attachment' || catalogObject?.kind === 'attachment') {
      return undefined;
    }
    const local = localByID.get(fileId);
    const remote = remoteByID.get(fileId);
    const path = version.path ?? local?.path ?? remote?.path;
    if (!path) {
      return undefined;
    }
    if (local && await sha256Text(local.content) === version.contentDigest) {
      return {
        file: { ...local, path, modifiedAt: 0 },
        downloaded: false,
      };
    }
    if (
      remote
      && remote.id === fileId
      && await sha256Text(remote.content) === version.contentDigest
    ) {
      return {
        file: { ...remote, path, modifiedAt: 0 },
        downloaded: false,
      };
    }
    const metadata = catalogObject;
    if (!metadata || metadata.digest !== version.objectDigest) {
      return undefined;
    }
    const opened = await openMarkdownObject({
      encrypted: await downloadCosObject(grant, metadata.objectKey),
      metadata,
      masterKey,
      fileId,
      versionId: version.versionId,
      byteSize: version.byteSize,
      expectedDigest: version.objectDigest,
    });
    return {
      file: {
        id: fileId,
        path,
        content: opened.content,
        modifiedAt: 0,
        metadata: parseMetadata(opened.content),
      } satisfies NoteFile,
      downloaded: true,
    };
  });
  const present = loaded.filter(value => value !== undefined);
  return {
    files: present.map(value => value.file),
    downloadedObjects: present.filter(value => value.downloaded).length,
  };
}

async function downloadMarkdown({
  entry,
  metadata,
  grant,
  masterKey,
}: {
  entry: VaultManifestEntry;
  metadata?: VaultObjectSummary;
  grant: TemporaryCosGrant;
  masterKey: Uint8Array;
}): Promise<{ content: string; parentVersionId?: string }> {
  if (!metadata) {
    throw new Error(`Remote object ${entry.currentVersionId} is missing from the catalog`);
  }
  return openMarkdownObject({
    encrypted: await downloadCosObject(grant, metadata.objectKey),
    metadata,
    masterKey,
    fileId: entry.fileId,
    versionId: entry.currentVersionId,
    byteSize: entry.byteSize,
    expectedDigest: hex(entry.objectDigest),
  });
}

async function downloadAttachment({
  entry,
  metadata,
  grant,
  masterKey,
}: {
  entry: VaultManifestEntry;
  metadata: VaultObjectSummary;
  grant: TemporaryCosGrant;
  masterKey: Uint8Array;
}): Promise<{ bytes: Uint8Array; mimeType: string; parentVersionId?: string }> {
  const encrypted = await downloadCosObject(grant, metadata.objectKey);
  if (
    metadata.kind !== 'attachment'
    || metadata.cipherSize !== encrypted.length
    || metadata.digest !== hex(entry.objectDigest)
    || await sha256Hex(encrypted) !== metadata.digest
  ) {
    throw new Error(`Encrypted attachment ${entry.currentVersionId} failed integrity checks`);
  }
  const object = decodeVaultObject(encrypted);
  if (
    object.fileId !== entry.fileId
    || object.versionId !== entry.currentVersionId
    || object.kind !== 'attachment'
  ) {
    throw new Error(`Encrypted attachment ${entry.currentVersionId} has an invalid identity`);
  }
  const mimeType = object.mimeType ?? 'application/octet-stream';
  const bytes = await openVaultObject({
    value: object,
    plaintextSize: entry.byteSize,
    masterKey,
    fileId: entry.fileId,
    versionId: entry.currentVersionId,
    parentVersionId: object.parentVersionId,
    kind: object.kind,
    mimeType,
  });
  return { bytes, mimeType, parentVersionId: object.parentVersionId };
}

async function openMarkdownObject({
  encrypted,
  metadata,
  masterKey,
  fileId,
  versionId,
  byteSize,
  expectedDigest,
}: {
  encrypted: Uint8Array;
  metadata: VaultObjectSummary;
  masterKey: Uint8Array;
  fileId: string;
  versionId: string;
  byteSize: number;
  expectedDigest: string;
}): Promise<{ content: string; parentVersionId?: string }> {
  if (
    metadata.kind !== 'markdown'
    || metadata.cipherSize !== encrypted.length
    || metadata.digest !== expectedDigest
    || await sha256Hex(encrypted) !== expectedDigest
  ) {
    throw new Error(`Encrypted object ${versionId} failed integrity checks`);
  }
  const object = decodeVaultObject(encrypted);
  if (object.fileId !== fileId || object.versionId !== versionId || object.kind !== 'markdown') {
    throw new Error(`Encrypted object ${versionId} has an invalid identity`);
  }
  const plaintext = await openVaultObject({
    value: object,
    plaintextSize: byteSize,
    masterKey,
    fileId,
    versionId,
    parentVersionId: object.parentVersionId,
    kind: object.kind,
    mimeType: object.mimeType,
  });
  return {
    content: new TextDecoder('utf-8', { fatal: true }).decode(plaintext),
    parentVersionId: object.parentVersionId,
  };
}

async function resolveVaultID(state: VaultSyncState, workspaceName: string): Promise<string> {
  if (state.vaultId) {
    return state.vaultId;
  }
  const vaults = await listVaults();
  const vault = vaults[0] ?? await createVault(workspaceName);
  state.vaultId = vault.id;
  return vault.id;
}

async function prepareFile(
  masterKey: Uint8Array,
  file: NoteFile | AttachmentFile,
  state: VaultSyncState,
): Promise<{
  file: NoteFile | AttachmentFile;
  versionId: string;
  parentVersionId?: string;
  contentDigest: string;
  objectDigest: string;
  byteSize: number;
  kind: 'markdown' | 'attachment';
  mimeType: string;
  object?: Uint8Array;
}> {
  const kind = file.kind === 'attachment' ? 'attachment' : 'markdown';
  const mimeType = kind === 'attachment'
    ? file.mimeType ?? 'application/octet-stream'
    : 'text/markdown';
  const plaintext = kind === 'attachment'
    ? (file as AttachmentFile).bytes
    : new TextEncoder().encode((file as NoteFile).content);
  const contentDigest = await sha256Hex(plaintext);
  const previous = state.files[file.id];
  const previousKind = previous?.kind ?? 'markdown';
  const previousMimeType = previous?.mimeType ?? (previousKind === 'markdown' ? 'text/markdown' : undefined);
  if (
    previous?.contentDigest === contentDigest
    && previousKind === kind
    && previousMimeType === mimeType
  ) {
    return {
      file,
      versionId: previous.versionId,
      parentVersionId: previous.parentVersionId,
      contentDigest,
      objectDigest: previous.objectDigest,
      byteSize: previous.byteSize,
      kind,
      mimeType,
    };
  }
  const versionId = crypto.randomUUID();
  const sealed = await sealVaultObject({
    plaintext,
    masterKey,
    fileId: file.id,
    versionId,
    parentVersionId: previous?.versionId,
    kind,
    mimeType,
  });
  const object = encodeVaultObject({
    ...sealed,
    fileId: file.id,
    versionId,
    parentVersionId: previous?.versionId,
    kind,
    mimeType,
  });
  return {
    file,
    versionId,
    parentVersionId: previous?.versionId,
    contentDigest,
    objectDigest: await sha256Hex(object),
    byteSize: plaintext.length,
    kind,
    mimeType,
    object,
  };
}

async function uploadCosObject(
  grant: TemporaryCosGrant,
  objectKey: string,
  bytes: Uint8Array,
): Promise<void> {
  if (!objectKey.startsWith(grant.prefix) || objectKey.split('/').includes('..')) {
    throw new Error('COS object key is outside the granted Vault prefix');
  }
  const host = `${grant.bucket}.cos.${grant.region}.myqcloud.com`;
  const path = `/${objectKey.split('/').map(percentEncode).join('/')}`;
  const authorization = await cosAuthorization({
    method: 'put',
    host,
    path,
    token: grant.credentials.Token,
    secretId: grant.credentials.TmpSecretId,
    secretKey: grant.credentials.TmpSecretKey,
  });
  const response = await fetch(`https://${host}${path}`, {
    method: 'PUT',
    headers: {
      Authorization: authorization,
      'Content-Type': 'application/octet-stream',
      'x-cos-security-token': grant.credentials.Token,
    },
    body: copyBuffer(bytes),
  });
  if (!response.ok) {
    throw new Error(`COS upload failed with ${response.status}`);
  }
}

async function downloadCosObject(
  grant: TemporaryCosGrant,
  objectKey: string,
): Promise<Uint8Array> {
  if (!objectKey.startsWith(grant.prefix) || objectKey.split('/').includes('..')) {
    throw new Error('COS object key is outside the granted Vault prefix');
  }
  const host = `${grant.bucket}.cos.${grant.region}.myqcloud.com`;
  const path = `/${objectKey.split('/').map(percentEncode).join('/')}`;
  const authorization = await cosAuthorization({
    method: 'get',
    host,
    path,
    token: grant.credentials.Token,
    secretId: grant.credentials.TmpSecretId,
    secretKey: grant.credentials.TmpSecretKey,
  });
  const response = await fetch(`https://${host}${path}`, {
    headers: {
      Authorization: authorization,
      'x-cos-security-token': grant.credentials.Token,
    },
  });
  if (!response.ok) {
    throw new Error(`COS download failed with ${response.status}`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

export async function cosAuthorization({
  method,
  host,
  path,
  token,
  secretId,
  secretKey,
}: {
  method: string;
  host: string;
  path: string;
  token: string;
  secretId: string;
  secretKey: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1_000);
  const keyTime = `${now};${now + 600}`;
  const headerList = 'host;x-cos-security-token';
  const canonicalHeaders = `host=${percentEncode(host.toLowerCase())}`
    + `&x-cos-security-token=${percentEncode(token)}`;
  const httpString = `${method.toLowerCase()}\n${path}\n\n${canonicalHeaders}\n`;
  const stringToSign = `sha1\n${keyTime}\n${await sha1Hex(new TextEncoder().encode(httpString))}\n`;
  const signKey = hex(await hmacSha1(new TextEncoder().encode(secretKey), keyTime));
  const signature = hex(await hmacSha1(new TextEncoder().encode(signKey), stringToSign));
  return `q-sign-algorithm=sha1&q-ak=${percentEncode(secretId)}`
    + `&q-sign-time=${keyTime}&q-key-time=${keyTime}`
    + `&q-header-list=${headerList}&q-url-param-list=&q-signature=${signature}`;
}

async function hmacSha1(key: Uint8Array, value: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    copyBuffer(key),
    { name: 'HMAC', hash: 'SHA-1' },
    false,
    ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign(
    'HMAC',
    cryptoKey,
    new TextEncoder().encode(value),
  ));
}

async function sha1Hex(value: Uint8Array): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-1', copyBuffer(value))));
}

async function sha256Hex(value: Uint8Array): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', copyBuffer(value))));
}

async function sha256Text(value: string): Promise<string> {
  return sha256Hex(new TextEncoder().encode(value));
}

function base64(value: Uint8Array): string {
  let binary = '';
  for (let offset = 0; offset < value.length; offset += 0x8000) {
    binary += String.fromCharCode(...value.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function unbase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), character => character.charCodeAt(0));
}

function optionalDigest(value?: Uint8Array): string | undefined {
  return value ? hex(value) : undefined;
}

function sameWorkspace(left: NoteFile[], right: NoteFile[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  const rightByID = new Map(right.map(file => [file.id, file]));
  return left.every(file => {
    const other = rightByID.get(file.id);
    return other?.path === file.path && other.content === file.content;
  });
}

function mergeAttachments(local: AttachmentFile[], remote: AttachmentFile[]): AttachmentFile[] {
  const merged = new Map<string, AttachmentFile>();
  for (const attachment of [...local, ...remote]) {
    const existing = merged.get(attachment.path);
    if (existing && existing.contentDigest !== attachment.contentDigest) {
      throw new Error(`Immutable attachment conflict at ${attachment.path}`);
    }
    if (!existing || attachment.modifiedAt > existing.modifiedAt) {
      merged.set(attachment.path, attachment);
    }
  }
  return [...merged.values()].sort((left, right) => left.path.localeCompare(right.path));
}

function sameAttachments(left: AttachmentFile[], right: AttachmentFile[]): boolean {
  if (left.length !== right.length) return false;
  const rightByPath = new Map(right.map(file => [file.path, file]));
  return left.every(file => {
    const other = rightByPath.get(file.path);
    return other?.contentDigest === file.contentDigest && other?.byteSize === file.byteSize;
  });
}

function percentEncode(value: string): string {
  return [...new TextEncoder().encode(value)]
    .map(byte => (
      isUnreserved(byte)
        ? String.fromCharCode(byte)
        : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`
    ))
    .join('');
}

function isUnreserved(byte: number): boolean {
  return (byte >= 0x41 && byte <= 0x5a)
    || (byte >= 0x61 && byte <= 0x7a)
    || (byte >= 0x30 && byte <= 0x39)
    || [0x2d, 0x2e, 0x5f, 0x7e].includes(byte);
}

async function mapConcurrent<Input, Output>(
  values: Input[],
  concurrency: number,
  operation: (value: Input) => Promise<Output>,
): Promise<Output[]> {
  const output = new Array<Output>(values.length);
  let nextIndex = 0;
  const workers = Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (nextIndex < values.length) {
      const index = nextIndex;
      nextIndex += 1;
      output[index] = await operation(values[index]);
    }
  });
  await Promise.all(workers);
  return output;
}

function copyBuffer(value: Uint8Array): ArrayBuffer {
  return value.slice().buffer as ArrayBuffer;
}
