import { applyMetadata, parseMetadata } from '../markdown/metadata';
import type {
  ConflictRecord,
  ConflictResolution,
  AttachmentFile,
  NoteFile,
  NoteMetadata,
  VaultFile,
  VaultManifest,
} from '../types';

const MAGIC = new TextEncoder().encode('KSV1');
const MANIFEST_FILE = 'manifest.ksv';
const CONFLICTS_FILE = 'conflicts.ksv';
const DATABASE_NAME = 'ksamint-device-v1';
const KEY_STORE = 'device-keys';
const FALLBACK_STORE = 'vault-objects';
const LOCAL_RECORD_DIRECTORY = 'local-records';

type LocalRecord = { expiresAt: number; value: unknown };

type LegacyVaultFile = Pick<VaultFile, 'id' | 'path' | 'modifiedAt'>;
type LegacyVaultManifest = Omit<VaultManifest, 'version' | 'files'> & {
  version: 1;
  files: LegacyVaultFile[];
};

type EncryptedPayload = {
  nonce: Uint8Array;
  ciphertext: ArrayBuffer;
};

export class VaultStorage {
  private constructor(
    private readonly workspaceId: string,
    private readonly key: CryptoKey,
    private manifest: VaultManifest,
    private readonly opfsRoot?: FileSystemDirectoryHandle,
  ) {}

  static async open(workspaceId = 'offline'): Promise<VaultStorage> {
    const key = await deviceKey(workspaceId);
    const opfsRoot = await workspaceDirectory(workspaceId);
    const encryptedManifest = await readObject(opfsRoot, workspaceId, MANIFEST_FILE);
    let manifest: VaultManifest;
    let migrated = false;

    if (encryptedManifest) {
      const decoded = JSON.parse(await decryptText(key, encryptedManifest)) as VaultManifest | LegacyVaultManifest;
      migrated = decoded.version === 1;
      manifest = migrateVaultManifest(decoded);
    } else {
      manifest = {
        version: 2,
        id: workspaceId,
        name: 'Personal Workspace',
        files: [],
        updatedAt: Date.now(),
      };
    }

    const storage = new VaultStorage(workspaceId, key, manifest, opfsRoot);
    if (migrated) {
      await storage.refreshLegacyFileSizes();
      await storage.persistManifest();
    }
    if (manifest.files.length === 0) {
      await storage.createFile(
        'Welcome.md',
        '# Welcome to kmd\n\nYour Markdown stays local until you enable encrypted sync.\n',
      );
    }
    return storage;
  }

  workspace(): VaultManifest {
    return structuredClone(this.manifest);
  }

  listFiles(): VaultFile[] {
    return this.manifest.files
      .filter(file => file.kind !== 'attachment')
      .sort((left, right) => left.path.localeCompare(right.path));
  }

  listAllFiles(): VaultFile[] {
    return [...this.manifest.files].sort((left, right) => left.path.localeCompare(right.path));
  }

  async readFile(id: string): Promise<NoteFile> {
    const file = this.manifest.files.find(candidate => candidate.id === id);
    if (!file) {
      throw new Error('File not found');
    }
    if (file.kind === 'attachment') {
      throw new Error('Attachment cannot be opened as Markdown');
    }
    const payload = await readObject(this.opfsRoot, this.workspaceId, objectName(file.id));
    if (!payload) {
      throw new Error('Encrypted file object is missing');
    }
    const content = await decryptText(this.key, payload);
    return { ...file, kind: 'markdown', content, metadata: parseMetadata(content) };
  }

  async createFile(path: string, content = ''): Promise<NoteFile> {
    const normalizedPath = normalizePath(path);
    if (this.manifest.files.some(file => file.path === normalizedPath)) {
      throw new Error('A file already exists at that path');
    }
    const file: VaultFile = {
      id: crypto.randomUUID(),
      path: normalizedPath,
      modifiedAt: Date.now(),
      kind: 'markdown',
      mimeType: 'text/markdown',
      byteSize: new TextEncoder().encode(content).length,
    };
    this.manifest.files.push(file);
    await this.writeContent(file, content);
    await this.persistManifest();
    return { ...file, kind: 'markdown', content, metadata: parseMetadata(content) };
  }

  async importFiles(
    documents: Array<{ path: string; content: string; modifiedAt: number }>,
  ): Promise<NoteFile[]> {
    if (!documents.length) {
      return [];
    }
    const originalFiles = this.manifest.files.map(file => ({ ...file }));
    const paths = new Set(this.manifest.files.map(file => file.path));
    const imported: NoteFile[] = [];
    try {
      for (const document of documents) {
        const path = normalizePath(document.path);
        if (paths.has(path)) {
          throw new Error(`A file already exists at ${path}`);
        }
        paths.add(path);
        const file: VaultFile = {
          id: crypto.randomUUID(),
          path,
          modifiedAt: Math.max(0, Math.floor(document.modifiedAt)),
          kind: 'markdown',
          mimeType: 'text/markdown',
          byteSize: new TextEncoder().encode(document.content).length,
        };
        this.manifest.files.push(file);
        await this.writeContent(file, document.content);
        imported.push({ ...file, kind: 'markdown', content: document.content, metadata: parseMetadata(document.content) });
      }
      await this.persistManifest();
      return imported;
    } catch (error) {
      this.manifest.files = originalFiles;
      throw error;
    }
  }

  async writeFile(id: string, content: string): Promise<NoteFile> {
    const file = this.manifest.files.find(candidate => candidate.id === id);
    if (!file || file.kind === 'attachment') {
      throw new Error('File not found');
    }
    file.modifiedAt = Date.now();
    file.byteSize = new TextEncoder().encode(content).length;
    await this.writeContent(file, content);
    await this.persistManifest();
    return { ...file, kind: 'markdown', content, metadata: parseMetadata(content) };
  }

  async setMetadata(id: string, metadata: NoteMetadata): Promise<NoteFile> {
    const file = await this.readFile(id);
    return this.writeFile(id, applyMetadata(file.content, metadata));
  }

  async renameFile(id: string, path: string): Promise<void> {
    const normalizedPath = normalizePath(path);
    if (this.manifest.files.some(file => file.id !== id && file.path === normalizedPath)) {
      throw new Error('A file already exists at that path');
    }
    const file = this.manifest.files.find(candidate => candidate.id === id);
    if (!file) {
      throw new Error('File not found');
    }
    file.path = normalizedPath;
    file.modifiedAt = Date.now();
    await this.persistManifest();
  }

  async deleteFile(id: string): Promise<void> {
    const index = this.manifest.files.findIndex(file => file.id === id);
    if (index < 0) {
      throw new Error('File not found');
    }
    this.manifest.files.splice(index, 1);
    await deleteObject(this.opfsRoot, this.workspaceId, objectName(id));
    await this.persistManifest();
  }

  async writeAttachment(input: {
    path: string;
    bytes: Uint8Array;
    mimeType: string;
    contentDigest: string;
    modifiedAt?: number;
  }): Promise<AttachmentFile> {
    const path = normalizeAssetPath(input.path);
    const existing = this.manifest.files.find(file => file.path === path);
    if (existing && existing.kind !== 'attachment') {
      throw new Error(`A Markdown file already exists at ${path}`);
    }
    if (existing?.contentDigest === input.contentDigest) {
      return { ...existing, kind: 'attachment', bytes: input.bytes.slice() };
    }
    const file: VaultFile = existing ?? {
      id: crypto.randomUUID(),
      path,
      modifiedAt: input.modifiedAt ?? Date.now(),
      kind: 'attachment',
      mimeType: input.mimeType || 'application/octet-stream',
      byteSize: input.bytes.length,
    };
    file.modifiedAt = input.modifiedAt ?? Date.now();
    file.mimeType = input.mimeType || 'application/octet-stream';
    file.byteSize = input.bytes.length;
    file.contentDigest = input.contentDigest;
    if (!existing) this.manifest.files.push(file);
    await writeObject(
      this.opfsRoot,
      this.workspaceId,
      objectName(file.id),
      await encryptBytes(this.key, input.bytes),
    );
    await this.persistManifest();
    return { ...file, kind: 'attachment', bytes: input.bytes.slice() };
  }

  async readAttachment(id: string): Promise<AttachmentFile> {
    const file = this.manifest.files.find(candidate => candidate.id === id);
    if (!file || file.kind !== 'attachment') {
      throw new Error('Attachment not found');
    }
    const payload = await readObject(this.opfsRoot, this.workspaceId, objectName(file.id));
    if (!payload) throw new Error('Encrypted attachment object is missing');
    return { ...file, kind: 'attachment', bytes: await decryptBytes(this.key, payload) };
  }

  async replaceAttachments(attachments: AttachmentFile[]): Promise<AttachmentFile[]> {
    const expected = new Set(attachments.map(attachment => attachment.id));
    const removed = this.manifest.files.filter(file => file.kind === 'attachment' && !expected.has(file.id));
    for (const file of removed) {
      await deleteObject(this.opfsRoot, this.workspaceId, objectName(file.id));
    }
    this.manifest.files = this.manifest.files.filter(file => file.kind !== 'attachment');
    for (const attachment of attachments) {
      const path = normalizeAssetPath(attachment.path);
      const metadata: VaultFile = {
        id: attachment.id,
        path,
        modifiedAt: attachment.modifiedAt,
        kind: 'attachment',
        mimeType: attachment.mimeType ?? 'application/octet-stream',
        byteSize: attachment.bytes.length,
        contentDigest: attachment.contentDigest,
      };
      this.manifest.files.push(metadata);
      await writeObject(
        this.opfsRoot,
        this.workspaceId,
        objectName(metadata.id),
        await encryptBytes(this.key, attachment.bytes),
      );
    }
    await this.persistManifest();
    return structuredClone(attachments);
  }

  async writeLocalRecord(
    namespace: string,
    id: string,
    value: unknown,
    expiresAt: number,
  ): Promise<void> {
    const records = await this.readLocalRecords(namespace);
    records[id] = { expiresAt, value };
    await this.writeLocalRecords(namespace, records);
  }

  async readLocalRecord<T>(namespace: string, id: string): Promise<T | undefined> {
    const records = await this.readLocalRecords(namespace);
    const record = records[id];
    if (!record || record.expiresAt <= Date.now()) return undefined;
    return structuredClone(record.value as T);
  }

  async deleteLocalRecord(namespace: string, id: string): Promise<void> {
    const records = await this.readLocalRecords(namespace);
    delete records[id];
    await this.writeLocalRecords(namespace, records);
  }

  async replaceFiles(files: NoteFile[]): Promise<NoteFile[]> {
    const ids = new Set<string>();
    const paths = new Set<string>();
    const normalized = files.map(file => {
      const path = normalizePath(file.path);
      if (ids.has(file.id) || paths.has(path)) {
        throw new Error('Remote workspace contains duplicate file identities or paths');
      }
      ids.add(file.id);
      paths.add(path);
      return {
        ...file,
        path,
        modifiedAt: Math.max(0, Math.floor(file.modifiedAt)),
        kind: 'markdown' as const,
        mimeType: 'text/markdown',
        byteSize: new TextEncoder().encode(file.content).length,
        metadata: parseMetadata(file.content),
      };
    });
    // Re-encrypting every note on every sync and leaving replaced objects
    // behind made each sync O(workspace) in crypto and grew OPFS forever.
    const previousNotes = new Map(
      this.manifest.files
        .filter(file => file.kind !== 'attachment')
        .map(file => [file.id, file] as const),
    );
    for (const file of normalized) {
      const previous = previousNotes.get(file.id);
      const unchanged = previous !== undefined
        && typeof previous.contentDigest === 'string'
        && previous.contentDigest.length > 0
        && previous.contentDigest === file.contentDigest
        && previous.byteSize === file.byteSize;
      if (!unchanged) {
        await this.writeContent(file, file.content);
      }
    }
    for (const id of previousNotes.keys()) {
      if (!ids.has(id)) {
        await deleteObject(this.opfsRoot, this.workspaceId, objectName(id));
      }
    }
    const attachments = this.manifest.files.filter(file => file.kind === 'attachment');
    this.manifest.files = [
      ...normalized.map(({ id, path, modifiedAt, kind, mimeType, byteSize, contentDigest }) => ({
        id,
        path,
        modifiedAt,
        kind,
        mimeType,
        byteSize,
        contentDigest,
      })),
      ...attachments,
    ];
    await this.persistManifest();
    return structuredClone(normalized);
  }

  async listConflicts(): Promise<ConflictRecord[]> {
    const payload = await readObject(this.opfsRoot, this.workspaceId, CONFLICTS_FILE);
    if (!payload) {
      return [];
    }
    const parsed = JSON.parse(await decryptText(this.key, payload)) as unknown;
    if (!Array.isArray(parsed)) {
      throw new Error('The local conflict history is damaged');
    }
    return structuredClone(parsed as ConflictRecord[]);
  }

  async appendConflicts(records: ConflictRecord[]): Promise<ConflictRecord[]> {
    if (!records.length) {
      return this.listConflicts();
    }
    const existing = await this.listConflicts();
    const known = new Set(existing.map(record => record.id));
    const next = [...existing, ...records.filter(record => !known.has(record.id))];
    await this.persistConflicts(next);
    return structuredClone(next);
  }

  async resolveConflict(
    id: string,
    resolution: ConflictResolution,
  ): Promise<ConflictRecord[]> {
    const records = await this.listConflicts();
    const record = records.find(candidate => candidate.id === id);
    if (!record) {
      throw new Error('Conflict record not found');
    }
    record.resolution = structuredClone(resolution);
    await this.persistConflicts(records);
    return structuredClone(records);
  }

  private async writeContent(file: VaultFile, content: string): Promise<void> {
    const payload = await encryptText(this.key, content);
    await writeObject(this.opfsRoot, this.workspaceId, objectName(file.id), payload);
  }

  private async refreshLegacyFileSizes(): Promise<void> {
    for (const file of this.manifest.files) {
      const payload = await readObject(this.opfsRoot, this.workspaceId, objectName(file.id));
      if (!payload) continue;
      const bytes = await decryptBytes(this.key, payload);
      file.byteSize = bytes.length;
    }
  }

  private async readLocalRecords(namespace: string): Promise<Record<string, LocalRecord>> {
    const path = localRecordPath(namespace);
    const payload = await readObject(this.opfsRoot, this.workspaceId, path);
    if (!payload) return {};
    const decoded = JSON.parse(await decryptText(this.key, payload)) as Record<string, LocalRecord>;
    const now = Date.now();
    return Object.fromEntries(Object.entries(decoded).filter(([, record]) => record.expiresAt > now));
  }

  private async writeLocalRecords(namespace: string, records: Record<string, LocalRecord>): Promise<void> {
    const path = localRecordPath(namespace);
    await writeObject(
      this.opfsRoot,
      this.workspaceId,
      path,
      await encryptText(this.key, JSON.stringify(records)),
    );
  }

  private async persistManifest(): Promise<void> {
    this.manifest.updatedAt = Date.now();
    const payload = await encryptText(this.key, JSON.stringify(this.manifest));
    await writeObject(this.opfsRoot, this.workspaceId, MANIFEST_FILE, payload);
  }

  private async persistConflicts(records: ConflictRecord[]): Promise<void> {
    const payload = await encryptText(this.key, JSON.stringify(records));
    await writeObject(this.opfsRoot, this.workspaceId, CONFLICTS_FILE, payload);
  }
}

export function migrateVaultManifest(value: VaultManifest | LegacyVaultManifest): VaultManifest {
  if (value.version === 2) return structuredClone(value);
  return {
    ...value,
    version: 2,
    files: value.files.map(file => ({
      ...file,
      kind: 'markdown',
      mimeType: 'text/markdown',
      byteSize: 0,
    })),
  };
}

function objectName(id: string): string {
  return `objects/${id}.ksv`;
}

function localRecordPath(namespace: string): string {
  if (!/^[a-z0-9-]{1,64}$/u.test(namespace)) throw new Error('Invalid local record namespace');
  return `${LOCAL_RECORD_DIRECTORY}/${namespace}.ksv`;
}

function normalizePath(path: string): string {
  const segments = path.replaceAll('\\', '/').split('/').filter(Boolean);
  if (!segments.length || segments.some(segment => segment === '..' || segment === '.')) {
    throw new Error('Invalid workspace path');
  }
  const normalized = segments.join('/');
  return /\.[a-z0-9]+$/i.test(normalized) ? normalized : `${normalized}.md`;
}

function normalizeAssetPath(path: string): string {
  const segments = path.normalize('NFC').replaceAll('\\', '/').split('/').filter(Boolean);
  if (
    !segments.length
    || segments.some(segment => segment === '..' || segment === '.' || segment.includes('\0'))
    || path.startsWith('/')
  ) {
    throw new Error('Invalid attachment path');
  }
  return segments.join('/');
}

async function encryptText(key: CryptoKey, value: string): Promise<ArrayBuffer> {
  return encryptBytes(key, new TextEncoder().encode(value));
}

async function encryptBytes(key: CryptoKey, value: Uint8Array): Promise<ArrayBuffer> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: 'AES-GCM',
      iv: nonce.buffer as ArrayBuffer,
      additionalData: MAGIC.buffer as ArrayBuffer,
    },
    key,
    value.slice().buffer,
  );
  const output = new Uint8Array(MAGIC.length + nonce.length + ciphertext.byteLength);
  output.set(MAGIC, 0);
  output.set(nonce, MAGIC.length);
  output.set(new Uint8Array(ciphertext), MAGIC.length + nonce.length);
  return output.buffer;
}

async function decryptText(key: CryptoKey, value: ArrayBuffer): Promise<string> {
  return new TextDecoder().decode(await decryptBytes(key, value));
}

async function decryptBytes(key: CryptoKey, value: ArrayBuffer): Promise<Uint8Array> {
  const payload = splitPayload(value);
  const plaintext = await crypto.subtle.decrypt(
    {
      name: 'AES-GCM',
      iv: payload.nonce.buffer as ArrayBuffer,
      additionalData: MAGIC.buffer as ArrayBuffer,
    },
    key,
    payload.ciphertext,
  );
  return new Uint8Array(plaintext);
}

function splitPayload(value: ArrayBuffer): EncryptedPayload {
  const bytes = new Uint8Array(value);
  if (bytes.length < 32 || !MAGIC.every((byte, index) => bytes[index] === byte)) {
    throw new Error('Invalid encrypted vault object');
  }
  return {
    nonce: bytes.slice(MAGIC.length, MAGIC.length + 12),
    ciphertext: bytes.slice(MAGIC.length + 12).buffer,
  };
}

async function workspaceDirectory(
  workspaceId: string,
): Promise<FileSystemDirectoryHandle | undefined> {
  try {
    const root = await navigator.storage.getDirectory();
    const workspaces = await root.getDirectoryHandle('workspaces', { create: true });
    return workspaces.getDirectoryHandle(workspaceId, { create: true });
  } catch {
    return undefined;
  }
}

async function readObject(
  root: FileSystemDirectoryHandle | undefined,
  workspaceId: string,
  path: string,
): Promise<ArrayBuffer | undefined> {
  if (root) {
    try {
      const handle = await nestedFile(root, path, false);
      return (await handle.getFile()).arrayBuffer();
    } catch {
      return undefined;
    }
  }
  const value = await idbGet(FALLBACK_STORE, `${workspaceId}/${path}`);
  return value instanceof ArrayBuffer ? value : undefined;
}

async function writeObject(
  root: FileSystemDirectoryHandle | undefined,
  workspaceId: string,
  path: string,
  payload: ArrayBuffer,
): Promise<void> {
  if (root) {
    const handle = await nestedFile(root, path, true);
    const writable = await handle.createWritable();
    await writable.write(payload);
    await writable.close();
    return;
  }
  await idbPut(FALLBACK_STORE, `${workspaceId}/${path}`, payload);
}

async function deleteObject(
  root: FileSystemDirectoryHandle | undefined,
  workspaceId: string,
  path: string,
): Promise<void> {
  if (root) {
    const segments = path.split('/');
    let directory = root;
    try {
      for (const segment of segments.slice(0, -1)) {
        directory = await directory.getDirectoryHandle(segment);
      }
      await directory.removeEntry(segments.at(-1) ?? path);
    } catch {
      // Missing objects are already deleted from the logical Vault.
    }
    return;
  }
  await idbDelete(FALLBACK_STORE, `${workspaceId}/${path}`);
}

async function nestedFile(
  root: FileSystemDirectoryHandle,
  path: string,
  create: boolean,
): Promise<FileSystemFileHandle> {
  const segments = path.split('/');
  let directory = root;
  for (const segment of segments.slice(0, -1)) {
    directory = await directory.getDirectoryHandle(segment, { create });
  }
  return directory.getFileHandle(segments.at(-1) ?? path, { create });
}

async function deviceKey(workspaceId: string): Promise<CryptoKey> {
  const existing = await idbGet(KEY_STORE, workspaceId);
  if (existing instanceof CryptoKey) {
    return existing;
  }
  const key = await crypto.subtle.generateKey(
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
  await idbPut(KEY_STORE, workspaceId, key);
  return key;
}

async function idbGet(store: string, key: string): Promise<unknown> {
  const database = await openDatabase();
  return new Promise((resolve, reject) => {
    const request = database.transaction(store).objectStore(store).get(key);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function idbPut(store: string, key: string, value: unknown): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const request = database.transaction(store, 'readwrite').objectStore(store).put(value, key);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

async function idbDelete(store: string, key: string): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const request = database.transaction(store, 'readwrite').objectStore(store).delete(key);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

let databaseConnection: Promise<IDBDatabase> | undefined;

async function openDatabase(): Promise<IDBDatabase> {
  if (databaseConnection === undefined) {
    databaseConnection = new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open(DATABASE_NAME, 1);
      request.onupgradeneeded = () => {
        const database = request.result;
        if (!database.objectStoreNames.contains(KEY_STORE)) {
          database.createObjectStore(KEY_STORE);
        }
        if (!database.objectStoreNames.contains(FALLBACK_STORE)) {
          database.createObjectStore(FALLBACK_STORE);
        }
      };
      request.onsuccess = () => {
        const database = request.result;
        const forget = () => {
          databaseConnection = undefined;
        };
        database.onversionchange = () => {
          database.close();
          forget();
        };
        database.onclose = forget;
        resolve(database);
      };
      request.onerror = () => reject(request.error);
    });
    databaseConnection.catch(() => {
      databaseConnection = undefined;
    });
  }
  return databaseConnection;
}
