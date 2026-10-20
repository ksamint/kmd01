import {
  lazy,
  Suspense,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  AccountServiceError,
  createPasskey,
  signInWithPasskey,
} from './api/client';
import { buildGraph } from './graph/buildGraph';
import {
  importDocumentFromURL,
  prepareBrowserImport,
  uniqueImportPath,
} from './import/BrowserImport';
import { t } from './i18n';
import {
  clipboardKnowledgeTitle,
  isClipboardKnowledgeRecord,
  isFavoriteClipboardRecord,
} from './clipboard/knowledge';
import { canonicalTag } from './markdown/metadata';
import { renderMarkdown } from './markdown/preview';
import {
  planWorkspaceReplace,
  type ReplaceOptions,
  type ReplaceScope,
  type WorkspaceReplacePlan,
} from './search/replace';
import { searchNotes } from './search/search';
import {
  combineConflictContent,
  suggestedConflictContent,
} from './security/VaultMerge';
import { VaultStorage } from './storage/VaultStorage';
import { PendingFileSave } from './storage/PendingFileSave';
import type { ConversationInbox as ConversationInboxModule } from './conversation/ConversationInbox';
import type {
  ConversationImportDecision,
  ConversationImportPlan,
  ConversationImportSource,
} from './conversation/types';
import type {
  ConflictRecord,
  ConflictResolution,
  NoteFile,
  SearchHit,
} from './types';
import type { RecoveryChallenge, RecoveryPackageV2 } from './security/VaultRecovery';
import { VaultRecoveryDialog } from './security/VaultRecoveryDialog';
import { VaultDevicesDialog } from './security/VaultDevicesDialog';
import { BackupHistoryDialog, type BackupRestoreChoice } from './security/BackupHistoryDialog';

type Route = 'hub' | 'editor' | 'mindmap';
type SidebarMode = 'files' | 'search' | 'tags' | 'preview';
type TaxonomyKind = 'tag' | 'category';
type TaxonomyAction = 'rename' | 'merge' | 'delete';

const accountFeatureEnabled = import.meta.env.VITE_ACCOUNT_ENABLED === 'true';
const CoreEditor = lazy(() => import('./editor/CoreEditor').then(module => ({
  default: module.CoreEditor,
})));
const MindmapStation = lazy(() => import('./graph/MindmapStation').then(module => ({
  default: module.MindmapStation,
})));
const ConversationImportDialog = lazy(() => import('./conversation/ConversationImportDialog').then(module => ({
  default: module.ConversationImportDialog,
})));
const DeepSearchPanel = lazy(() => import('./search/DeepSearchPanel').then(module => ({
  default: module.DeepSearchPanel,
})));

export default function App() {
  const [storage, setStorage] = useState<VaultStorage>();
  const [files, setFiles] = useState<NoteFile[]>([]);
  const [selectedId, setSelectedId] = useState<string>();
  const [route, setRoute] = useState<Route>('hub');
  const [sidebar, setSidebar] = useState<SidebarMode>('files');
  const [query, setQuery] = useState('');
  const [replacePlan, setReplacePlan] = useState<WorkspaceReplacePlan>();
  const [replaceUndo, setReplaceUndo] = useState<NoteFile[]>();
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState<string>();
  const [tagManagerOpen, setTagManagerOpen] = useState(false);
  const [taxonomyUndo, setTaxonomyUndo] = useState<NoteFile[]>();
  const [cloudEnabled, setCloudEnabled] = useState(
    accountFeatureEnabled || localStorage.getItem('ksamint-cloud-enabled') === 'true',
  );
  const [syncing, setSyncing] = useState(false);
  const [importing, setImporting] = useState(false);
  const [conflicts, setConflicts] = useState<ConflictRecord[]>([]);
  const [conflictManagerOpen, setConflictManagerOpen] = useState(false);
  const [conversationPlan, setConversationPlan] = useState<ConversationImportPlan>();
  const [conversationUndo, setConversationUndo] = useState<string>();
  const [recoverySetup, setRecoverySetup] = useState<{
    recoveryPackage: RecoveryPackageV2;
    challenge: RecoveryChallenge[];
    deviceToken: string;
  }>();
  const [devicesOpen, setDevicesOpen] = useState(false);
  const [backupOpen, setBackupOpen] = useState(false);
  const conversationInbox = useRef<ConversationInboxModule | undefined>(undefined);
  const pendingFileSave = useRef<PendingFileSave<NoteFile> | undefined>(undefined);
  const openFileRequest = useRef(0);
  const selected = files.find(file => file.id === selectedId);
  const graph = useMemo(() => buildGraph(files), [files]);
  // Folding every note for the search list is expensive; skip it while the
  // search sidebar is closed.
  const hits = useMemo(
    () => (sidebar === 'search' ? searchNotes(files, query) : []),
    [files, query, sidebar],
  );

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (!event.metaKey) {
        return;
      }
      if (event.shiftKey && event.key.toLowerCase() === 'e') {
        event.preventDefault();
        setSidebar(current => current === 'files' ? current : 'files');
      } else if (event.shiftKey && event.key.toLowerCase() === 'f') {
        event.preventDefault();
        setSidebar('search');
      } else if (event.shiftKey && event.key.toLowerCase() === 't') {
        event.preventDefault();
        setSidebar('tags');
      } else if (event.shiftKey && event.key.toLowerCase() === 'h') {
        event.preventDefault();
        setRoute('hub');
      } else if (event.altKey && event.key.toLowerCase() === 'p') {
        event.preventDefault();
        setSidebar('preview');
      } else if (event.altKey && event.key.toLowerCase() === 'm') {
        event.preventDefault();
        setRoute('mindmap');
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);

  useEffect(() => {
    if ('serviceWorker' in navigator && import.meta.env.PROD) {
      navigator.serviceWorker.register(`${import.meta.env.BASE_URL}sw.js`).catch(() => undefined);
    }
  }, []);

  useEffect(() => {
    if (!storage) return;
    const coordinator = new PendingFileSave(
      (fileId, content) => storage.writeFile(fileId, content),
      (saved, edit) => {
        setFiles(current => current.map(file => (
          file.id === saved.id && file.content === edit.content ? saved : file
        )));
      },
      setSaving,
      error => setNotice(error instanceof Error ? error.message : String(error)),
    );
    pendingFileSave.current = coordinator;
    return () => {
      if (pendingFileSave.current === coordinator) pendingFileSave.current = undefined;
    };
  }, [storage]);

  async function continueOffline() {
    try {
      const opened = await VaultStorage.open();
      const loaded = await Promise.all(opened.listFiles().map(file => opened.readFile(file.id)));
      const conflictHistory = await opened.listConflicts();
      setStorage(opened);
      setFiles(loaded);
      setConflicts(conflictHistory);
      setSelectedId(loaded[0]?.id);
      setRoute(loaded.length ? 'editor' : 'hub');
      setNotice(undefined);
    } catch (error) {
      if (
        error instanceof Error
        && error.name === 'VaultRecoverySetupRequiredError'
        && 'recoveryPackage' in error
      ) {
        const setup = error as Error & {
          recoveryPackage: RecoveryPackageV2;
          challenge: RecoveryChallenge[];
          deviceToken: string;
        };
        setRecoverySetup({
          recoveryPackage: setup.recoveryPackage,
          challenge: setup.challenge,
          deviceToken: setup.deviceToken,
        });
        setNotice(undefined);
        return;
      }
      setNotice(error instanceof Error ? error.message : String(error));
    }
  }

  async function syncNow() {
    if (!storage || syncing) {
      return;
    }
    setSyncing(true);
    try {
      await flushPendingEdit();
      const { syncWorkspaceToPrivateCloud } = await import('./security/VaultSyncClient');
      const attachments = await Promise.all(
        storage.listAllFiles()
          .filter(file => file.kind === 'attachment')
          .map(file => storage.readAttachment(file.id)),
      );
      const report = await syncWorkspaceToPrivateCloud({
        workspaceId: storage.workspace().id,
        workspaceName: storage.workspace().name,
        files,
        attachments,
      });
      const synchronized = await storage.replaceFiles(report.files);
      await storage.replaceAttachments(report.attachments);
      const conflictHistory = await storage.appendConflicts(report.conflictRecords);
      setFiles(synchronized);
      setConflicts(conflictHistory);
      setSelectedId(current => (
        current && synchronized.some(file => file.id === current)
          ? current
          : synchronized[0]?.id
      ));
      setNotice(
        `${t('syncComplete')} · ↑${report.uploadedObjects} ↓${report.downloadedObjects}`
        + (report.conflicts ? ` · ${report.conflicts} ${t('syncConflicts')}` : ''),
      );
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
    } finally {
      setSyncing(false);
    }
  }

  async function openFile(id: string) {
    const request = ++openFileRequest.current;
    await flushPendingEdit();
    if (request !== openFileRequest.current) return;
    setSelectedId(id);
    setRoute('editor');
  }

  async function restoreBackupChoices(choices: BackupRestoreChoice[]) {
    if (!storage) return;
    await flushPendingEdit();
    setSaving(true);
    try {
      for (const choice of choices) {
        if (choice.strategy === 'historical') {
          if (choice.current) {
            await storage.writeFile(choice.current.id, choice.historical.content);
            if (choice.current.path !== choice.historical.path) {
              await storage.renameFile(choice.current.id, choice.historical.path);
            }
          } else {
            await storage.createFile(choice.historical.path, choice.historical.content);
          }
        } else if (choice.strategy === 'both') {
          await storage.createFile(historyCopyPath(choice.historical.path), choice.historical.content);
        } else if (choice.strategy === 'combine' && choice.current) {
          const combined = choice.current.content === choice.historical.content
            ? choice.current.content
            : `${choice.current.content.trimEnd()}\n\n---\n\n${choice.historical.content.trimStart()}`;
          await storage.writeFile(choice.current.id, combined);
        }
      }
      const loaded = await Promise.all(storage.listFiles().map(file => storage.readFile(file.id)));
      setFiles(loaded);
      setBackupOpen(false);
      setNotice('Historical versions restored; the next sync will create new encrypted versions.');
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
    } finally {
      setSaving(false);
    }
  }

  async function flushPendingEdit() {
    await pendingFileSave.current?.flush();
  }

  function changeContent(content: string) {
    if (!selected || !storage) {
      return;
    }
    setFiles(current => current.map(file => (
      file.id === selected.id
        ? { ...file, content, metadata: parseMetadataLazy(content), modifiedAt: Date.now() }
        : file
    )));
    pendingFileSave.current?.queue(selected.id, content);
  }

  async function createNote() {
    if (!storage) {
      return;
    }
    const name = `Note ${files.length + 1}.md`;
    try {
      const file = await storage.createFile(name, `# Note ${files.length + 1}\n\n`);
      setFiles(current => [...current, file]);
      await openFile(file.id);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
    }
  }

  async function importSources(sources: File[]) {
    if (!storage || !sources.length || importing) {
      return;
    }
    setImporting(true);
    try {
      const prepared = await prepareBrowserImport(sources);
      const occupied = new Set(files.map(file => file.path));
      const documents = prepared.documents.map(document => ({
        ...document,
        path: uniqueImportPath(document.path, occupied),
      }));
      const imported = await storage.importFiles(documents);
      setFiles(current => [...current, ...imported].sort((a, b) => a.path.localeCompare(b.path)));
      if (imported[0]) {
        await openFile(imported[0].id);
      }
      setNotice(
        `${imported.length} ${t('filesImported')}`
        + (prepared.failures.length ? ` · ${prepared.failures.length} ${t('filesSkipped')}` : ''),
      );
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
    } finally {
      setImporting(false);
    }
  }

  function chooseImport(kind: 'files' | 'folder') {
    const input = document.createElement('input');
    input.type = 'file';
    input.multiple = true;
    input.accept = '.md,.markdown,.mdown,.mkd,.txt,.text,.html,.htm,text/plain,text/markdown,text/html';
    if (kind === 'folder') {
      input.setAttribute('webkitdirectory', '');
      input.setAttribute('directory', '');
    }
    input.addEventListener('change', () => void importSources([...input.files ?? []]), { once: true });
    input.click();
  }

  async function importURL(url: string) {
    if (!storage || importing) {
      return;
    }
    setImporting(true);
    try {
      const document = await importDocumentFromURL(url);
      const path = uniqueImportPath(document.path, new Set(files.map(file => file.path)));
      const [imported] = await storage.importFiles([{ ...document, path }]);
      if (imported) {
        setFiles(current => [...current, imported].sort((a, b) => a.path.localeCompare(b.path)));
        await openFile(imported.id);
      }
      setNotice(`1 ${t('filesImported')}`);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
    } finally {
      setImporting(false);
    }
  }

  async function planConversationImport(sources: ConversationImportSource[]) {
    if (!storage || !sources.length || importing) return;
    setImporting(true);
    try {
      const [{ ConversationInbox }, { VaultConversationWorkspace }] = await Promise.all([
        import('./conversation/ConversationInbox'),
        import('./conversation/VaultConversationWorkspace'),
      ]);
      const inbox = new ConversationInbox(new VaultConversationWorkspace(storage));
      conversationInbox.current = inbox;
      const plan = await inbox.plan(sources);
      if (!plan.items.length && plan.failures.length) {
        throw new Error(plan.failures.map(failure => `${failure.sourceName}: ${failure.reason}`).join('\n'));
      }
      setConversationPlan(plan);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
    } finally {
      setImporting(false);
    }
  }

  function chooseConversationImport(kind: 'files' | 'folder' = 'files') {
    const input = document.createElement('input');
    input.type = 'file';
    input.multiple = true;
    input.accept = '.zip,.json,.md,.markdown,.txt,.text,.html,.htm,.rtf,application/zip,application/json,text/plain,text/markdown,text/html,application/rtf';
    if (kind === 'folder') {
      input.setAttribute('webkitdirectory', '');
      input.setAttribute('directory', '');
    }
    input.addEventListener('change', () => {
      void planConversationImport(conversationSources([...input.files ?? []]));
    }, { once: true });
    input.click();
  }

  function conversationSources(files: File[]): ConversationImportSource[] {
    return files.map(file => ({
      kind: 'file',
      name: file.webkitRelativePath || file.name,
      mimeType: file.type,
      lastModified: file.lastModified,
      read: async () => new Uint8Array(await file.arrayBuffer()),
    }));
  }

  async function pasteConversation(text?: string) {
    try {
      const content = text ?? await navigator.clipboard.readText();
      if (!content.trim()) throw new Error(t('conversationClipboardEmpty'));
      const bytes = new TextEncoder().encode(content);
      await planConversationImport([{
        kind: 'clipboard',
        name: 'Clipboard.md',
        mimeType: 'text/markdown',
        read: async () => bytes,
      }]);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
    }
  }

  async function applyConversationImport(decisions: ConversationImportDecision[]) {
    if (!storage || !conversationPlan || !conversationInbox.current) return;
    await flushPendingEdit();
    const report = await conversationInbox.current.apply(conversationPlan, decisions);
    const loaded = await Promise.all(storage.listFiles().map(file => storage.readFile(file.id)));
    setFiles(loaded);
    setConversationPlan(undefined);
    setConversationUndo(report.transactionId);
    if (report.files[0]) {
      setSelectedId(report.files[0].id);
      setRoute('editor');
    }
    setNotice(`${report.created} ${t('conversationNew')} · ${report.updated} ${t('conversationUpdates')} · ${report.skipped} ${t('conversationDuplicates')}`);
  }

  async function undoConversationImport() {
    if (!storage || !conversationUndo || !conversationInbox.current) return;
    await flushPendingEdit();
    await conversationInbox.current.undo(conversationUndo);
    const loaded = await Promise.all(storage.listFiles().map(file => storage.readFile(file.id)));
    setFiles(loaded);
    setSelectedId(current => current && loaded.some(file => file.id === current) ? current : loaded[0]?.id);
    setConversationUndo(undefined);
    setNotice(t('conversationUndoComplete'));
  }

  async function resolveConflict(
    record: ConflictRecord,
    content: string,
    strategy: ConflictResolution['strategy'],
  ) {
    if (!storage) {
      return;
    }
    await flushPendingEdit();
    const target = files.find(file => file.id === record.fileId)
      ?? files.find(file => record.preservedFileIds.includes(file.id));
    if (!target) {
      throw new Error('A preserved conflict version could not be found');
    }
    const resolved = await storage.writeFile(target.id, content);
    setFiles(current => current.map(file => file.id === resolved.id ? resolved : file));
    const history = await storage.resolveConflict(record.id, {
      resolvedAt: Date.now(),
      strategy,
      resultFileId: resolved.id,
    });
    setConflicts(history);
    setNotice(t('conflictResolved'));
  }

  async function addTag(tag: string) {
    if (!storage || !selected || !tag.trim()) {
      return;
    }
    await flushPendingEdit();
    const tags = [...selected.metadata.tags, tag.trim()];
    const updated = await storage.setMetadata(selected.id, {
      ...selected.metadata,
      tags,
    });
    setFiles(current => current.map(file => file.id === updated.id ? updated : file));
  }

  async function removeTag(tag: string) {
    if (!storage || !selected) {
      return;
    }
    await flushPendingEdit();
    const identity = canonicalTag(tag);
    const updated = await storage.setMetadata(selected.id, {
      ...selected.metadata,
      tags: selected.metadata.tags.filter(value => canonicalTag(value) !== identity),
    });
    setFiles(current => current.map(file => file.id === updated.id ? updated : file));
  }

  async function setCategory(fileId: string, category?: string) {
    if (!storage) {
      return;
    }
    await flushPendingEdit();
    const file = files.find(value => value.id === fileId);
    if (!file) {
      return;
    }
    const updated = await storage.setMetadata(file.id, {
      ...file.metadata,
      category: category?.trim() || undefined,
    });
    setFiles(current => current.map(value => value.id === updated.id ? updated : value));
  }

  async function applyTaxonomyAction(
    kind: TaxonomyKind,
    action: TaxonomyAction,
    source: string,
    target: string,
    signal: AbortSignal,
    onProgress: (completed: number, total: number) => void,
  ) {
    if (!storage) {
      return;
    }
    await flushPendingEdit();
    const sourceIdentity = canonicalTag(source);
    const affected = files.filter(file => (
      kind === 'tag'
        ? file.metadata.tags.some(tag => canonicalTag(tag) === sourceIdentity)
        : file.metadata.category === source || file.metadata.category?.startsWith(`${source}/`)
    ));
    setTaxonomyUndo(affected.map(file => structuredClone(file)));
    const updatedFiles: NoteFile[] = [];
    setSaving(true);
    try {
      for (const [index, file] of affected.entries()) {
        if (signal.aborted) {
          throw new DOMException(t('batchCancelled'), 'AbortError');
        }
        const metadata = structuredClone(file.metadata);
        if (kind === 'tag') {
          metadata.tags = metadata.tags.flatMap(tag => {
            if (canonicalTag(tag) !== sourceIdentity) {
              return [tag];
            }
            return action === 'delete' ? [] : [target.trim()];
          });
        } else if (metadata.category) {
          metadata.category = action === 'delete'
            ? undefined
            : `${target.trim()}${metadata.category.slice(source.length)}`;
        }
        const updated = await storage.setMetadata(file.id, metadata);
        updatedFiles.push(updated);
        onProgress(index + 1, affected.length);
      }
      const byId = new Map(updatedFiles.map(file => [file.id, file]));
      setFiles(current => current.map(file => byId.get(file.id) ?? file));
    } catch (error) {
      for (const snapshot of affected) {
        await storage.writeFile(snapshot.id, snapshot.content);
      }
      setTaxonomyUndo(undefined);
      throw error;
    } finally {
      setSaving(false);
    }
  }

  async function undoTaxonomyAction() {
    if (!storage || !taxonomyUndo) {
      return;
    }
    await flushPendingEdit();
    const restored: NoteFile[] = [];
    setSaving(true);
    try {
      for (const snapshot of taxonomyUndo) {
        restored.push(await storage.writeFile(snapshot.id, snapshot.content));
      }
      const byId = new Map(restored.map(file => [file.id, file]));
      setFiles(current => current.map(file => byId.get(file.id) ?? file));
      setTaxonomyUndo(undefined);
    } finally {
      setSaving(false);
    }
  }

  function previewReplace(options: ReplaceOptions, scope: ReplaceScope) {
    try {
      const plan = planWorkspaceReplace(files, options, scope, selectedId);
      if (!plan.changes.length) {
        setNotice(t('noReplaceMatches'));
        return;
      }
      setReplacePlan(plan);
      setNotice(undefined);
    } catch {
      setNotice(t('replaceInvalid'));
    }
  }

  async function applyReplace(plan: WorkspaceReplacePlan, selectedFileIds: string[]) {
    if (!storage || !selectedFileIds.length) return;
    await flushPendingEdit();
    const selectedIds = new Set(selectedFileIds);
    const changes = plan.changes.filter(change => selectedIds.has(change.fileId));
    const originals = changes.map(change => files.find(file => file.id === change.fileId));
    if (originals.some(file => !file) || changes.some(change => (
      files.find(file => file.id === change.fileId)?.modifiedAt !== change.sourceModifiedAt
    ))) {
      setReplacePlan(undefined);
      setNotice(t('replacePlanStale'));
      return;
    }
    const snapshots = originals.filter((file): file is NoteFile => Boolean(file)).map(file => structuredClone(file));
    const updated: NoteFile[] = [];
    setSaving(true);
    try {
      for (const change of changes) {
        updated.push(await storage.writeFile(change.fileId, change.content));
      }
      const byId = new Map(updated.map(file => [file.id, file]));
      setFiles(current => current.map(file => byId.get(file.id) ?? file));
      setReplaceUndo(snapshots);
      setReplacePlan(undefined);
      const replacements = changes.reduce((total, change) => total + change.occurrences, 0);
      setNotice(`${replacements} ${t('replacementsApplied')} · ${changes.length} ${t('affectedFiles').toLocaleLowerCase()}`);
    } catch (error) {
      for (const snapshot of snapshots) {
        await storage.writeFile(snapshot.id, snapshot.content);
      }
      setNotice(error instanceof Error ? error.message : String(error));
    } finally {
      setSaving(false);
    }
  }

  async function undoReplace() {
    if (!storage || !replaceUndo) return;
    await flushPendingEdit();
    const restored: NoteFile[] = [];
    setSaving(true);
    try {
      for (const snapshot of replaceUndo) {
        restored.push(await storage.writeFile(snapshot.id, snapshot.content));
      }
      const byId = new Map(restored.map(file => [file.id, file]));
      setFiles(current => current.map(file => byId.get(file.id) ?? file));
      setReplaceUndo(undefined);
      setNotice(t('replaceUndoComplete'));
    } finally {
      setSaving(false);
    }
  }

  if (!storage) {
    return (
      <Welcome
        notice={notice}
        onContinue={continueOffline}
        onSignIn={async () => {
          setNotice(undefined);
          if (
            typeof window.PublicKeyCredential === 'undefined'
            || !window.navigator.credentials
          ) {
            setNotice(t('passkeyUnsupported'));
            return;
          }
          localStorage.setItem('ksamint-cloud-enabled', 'true');
          setCloudEnabled(true);
          try {
            await signInWithPasskey();
            await continueOffline();
          } catch (error) {
            if (error instanceof AccountServiceError && error.status === 404) {
              try {
                await createPasskey();
                await continueOffline();
                return;
              } catch (registrationError) {
                setNotice(
                  registrationError instanceof Error
                    ? registrationError.message
                    : String(registrationError),
                );
                return;
              }
            }
            setNotice(error instanceof Error ? error.message : String(error));
          }
        }}
      />
    );
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <button className="brand-button" type="button" onClick={() => setRoute('hub')}>
          <span className="brand-mark" aria-hidden="true">K</span>
          <span>kmd</span>
        </button>
        <button className="workspace-switcher" type="button" onClick={() => setRoute('hub')}>
          <span>{storage.workspace().name}</span>
          <small>{t('localEncrypted')}</small>
        </button>
        <div className="topbar-spacer" />
        <span className="save-indicator" role="status">{saving ? t('saving') : t('saveState')}</span>
        {cloudEnabled && (
          <button className="quiet-button" type="button" disabled={syncing} onClick={syncNow}>
            {syncing ? t('syncing') : t('syncNow')}
          </button>
        )}
        {cloudEnabled && (
          <button className="quiet-button" type="button" onClick={() => setDevicesOpen(true)}>
            Devices
          </button>
        )}
        {cloudEnabled && (
          <button className="quiet-button" type="button" onClick={() => setBackupOpen(true)}>
            Backup
          </button>
        )}
        <button className="quiet-button" type="button" onClick={() => setRoute('mindmap')}>
          {t('mindmap')}
        </button>
        <button className="quiet-button conflict-button" type="button" onClick={() => setConflictManagerOpen(true)}>
          {t('conflicts')}{conflicts.filter(record => !record.resolution).length
            ? ` · ${conflicts.filter(record => !record.resolution).length}`
            : ''}
        </button>
      </header>

      <div
        className="workspace-layout"
        onDragOver={event => {
          if (event.dataTransfer.types.includes('Files')) {
            event.preventDefault();
          }
        }}
        onDrop={event => {
          if (event.dataTransfer.files.length) {
            event.preventDefault();
            void importSources([...event.dataTransfer.files]);
          }
        }}
      >
        <nav className="rail" aria-label={t('workspace')}>
          <RailButton label={t('files')} symbol="F" active={sidebar === 'files'} onClick={() => {
            setSidebar('files');
            setRoute('editor');
          }} />
          <RailButton label={t('search')} symbol="S" active={sidebar === 'search'} onClick={() => {
            setSidebar('search');
            setRoute('editor');
          }} />
          <RailButton label={t('tags')} symbol="T" active={sidebar === 'tags'} onClick={() => {
            setSidebar('tags');
            setRoute('editor');
          }} />
          <RailButton label={t('preview')} symbol="P" active={sidebar === 'preview'} onClick={() => {
            setSidebar('preview');
            setRoute('editor');
          }} />
          <div className="rail-spacer" />
          <RailButton label={t('hub')} symbol="H" active={route === 'hub'} onClick={() => setRoute('hub')} />
        </nav>

        {route === 'hub' ? (
          <Hub
            files={files}
            conflicts={conflicts}
            cloudEnabled={cloudEnabled}
            importing={importing}
            onOpen={openFile}
            onMindmap={() => setRoute('mindmap')}
            onChooseImport={chooseImport}
            onImportURL={importURL}
            onChooseConversation={chooseConversationImport}
            onDropConversation={files => planConversationImport(conversationSources(files))}
            onPasteConversation={pasteConversation}
            onOpenConflicts={() => setConflictManagerOpen(true)}
          />
        ) : route === 'mindmap' ? (
          <main className="main-content graph-route">
            <Suspense fallback={<RouteLoading />}>
              <MindmapStation graph={graph} onOpenNode={openFile} />
            </Suspense>
          </main>
        ) : (
          <>
            <aside className="sidebar">
              {sidebar === 'files' && (
                <FilesPanel
                  files={files}
                  selectedId={selectedId}
                  onOpen={openFile}
                  onCreate={createNote}
                  onImport={() => chooseImport('files')}
                />
              )}
              {sidebar === 'search' && (
                <SearchPanel
                  query={query}
                  hits={hits}
                  hasCurrentFile={Boolean(selectedId)}
                  canUndo={Boolean(replaceUndo)}
                  onQuery={setQuery}
                  onOpen={hit => openFile(hit.fileId)}
                  onPreview={previewReplace}
                  onUndo={() => void undoReplace()}
                />
              )}
              {sidebar === 'tags' && (
                <TagsPanel
                  files={files}
                  onManage={() => setTagManagerOpen(true)}
                  onAssignCategory={setCategory}
                  onFilter={value => {
                    setQuery(value);
                    setSidebar('search');
                  }}
                />
              )}
              {sidebar === 'preview' && selected && (
                <PreviewPanel content={selected.content} />
              )}
            </aside>
            <main className="editor-route">
              {selected ? (
                <>
                  <header className="document-header">
                    <div>
                      <strong>{selected.path.split('/').at(-1)}</strong>
                      <span>{selected.path}</span>
                    </div>
                    <TagEditor
                      file={selected}
                      onAdd={addTag}
                      onRemove={removeTag}
                      onCategory={category => setCategory(selected.id, category)}
                    />
                  </header>
                  <Suspense fallback={<RouteLoading />}>
                    <CoreEditor key={selected.id} value={selected.content} onChange={changeContent} />
                  </Suspense>
                </>
              ) : (
                <EmptyState onCreate={createNote} />
              )}
            </main>
          </>
        )}
      </div>
      {notice && (
        <div className="notice" role="alert">
          <span>{notice}</span>
          <button type="button" onClick={() => setNotice(undefined)}>×</button>
        </div>
      )}
      {taxonomyUndo && (
        <button className="undo-toast" type="button" onClick={undoTaxonomyAction}>
          {t('undo')} · {taxonomyUndo.length} {t('affectedFiles').toLocaleLowerCase()}
        </button>
      )}
      {conversationUndo && (
        <button className="undo-toast conversation-undo" type="button" onClick={() => void undoConversationImport()}>
          {t('undo')} · {t('conversationImport')}
        </button>
      )}
      {replaceUndo && (
        <button className="undo-toast replace-undo" type="button" onClick={() => void undoReplace()}>
          {t('undo')} · {t('replace')}
        </button>
      )}
      {tagManagerOpen && (
        <TagManagerDialog
          files={files}
          onClose={() => setTagManagerOpen(false)}
          onApply={applyTaxonomyAction}
        />
      )}
      {conflictManagerOpen && (
        <ConflictManagerDialog
          records={conflicts}
          onClose={() => setConflictManagerOpen(false)}
          onResolve={resolveConflict}
        />
      )}
      {conversationPlan && (
        <Suspense fallback={<RouteLoading />}>
          <ConversationImportDialog
            plan={conversationPlan}
            onClose={() => setConversationPlan(undefined)}
            onApply={applyConversationImport}
          />
        </Suspense>
      )}
      {replacePlan && (
        <ReplacePreviewDialog
          key={`${replacePlan.scope}-${replacePlan.occurrenceCount}-${replacePlan.options.replacement}`}
          plan={replacePlan}
          onClose={() => setReplacePlan(undefined)}
          onApply={selectedIds => void applyReplace(replacePlan, selectedIds)}
        />
      )}
      {recoverySetup && (
        <VaultRecoveryDialog
          workspaceId={storage.workspace().id}
          deviceToken={recoverySetup.deviceToken}
          recoveryPackage={recoverySetup.recoveryPackage}
          challenge={recoverySetup.challenge}
          onClose={() => setRecoverySetup(undefined)}
          onConfigured={() => {
            setRecoverySetup(undefined);
            void syncNow();
          }}
        />
      )}
      {devicesOpen && (
        <VaultDevicesDialog
          workspaceId={storage.workspace().id}
          onClose={() => setDevicesOpen(false)}
        />
      )}
      {backupOpen && (
        <BackupHistoryDialog
          workspaceId={storage.workspace().id}
          files={files}
          onClose={() => setBackupOpen(false)}
          onRestore={restoreBackupChoices}
        />
      )}
    </div>
  );
}

function historyCopyPath(path: string): string {
  const dot = path.lastIndexOf('.');
  const slash = path.lastIndexOf('/');
  const stem = dot > slash ? path.slice(0, dot) : path;
  const extension = dot > slash ? path.slice(dot) : '.md';
  const timestamp = new Date().toISOString().replaceAll(':', '-').replace('.000Z', 'Z');
  return `${stem} (historical ${timestamp})${extension}`;
}

function Welcome({
  notice,
  onContinue,
  onSignIn,
}: {
  notice?: string;
  onContinue: () => void;
  onSignIn: () => void;
}) {
  return (
    <main className="welcome">
      <section className="welcome-intro">
        <span className="welcome-mark" aria-hidden="true">K</span>
        <p className="eyebrow">Private Markdown workspace</p>
        <h1>Your notes remain yours.</h1>
        <p>Write, search and connect Markdown without creating an account. Encrypted sync is optional.</p>
        <div className="welcome-actions">
          <button className="primary-button" type="button" onClick={onContinue}>{t('continueOffline')}</button>
          <button className="secondary-button" type="button" onClick={onSignIn}>{t('signIn')}</button>
        </div>
        {notice && <p className="inline-notice" role="alert">{notice}</p>}
      </section>
      <section className="welcome-status" aria-label="Workspace status">
        <StatusRow label={t('recentWorkspace')} value="Personal Workspace" />
        <StatusRow label={t('recentDocuments')} value="—" />
        <StatusRow label={t('unsynced')} value="0" />
        <StatusRow label={t('backupHealth')} value={t('disabled')} />
      </section>
    </main>
  );
}

function Hub({
  files,
  conflicts,
  cloudEnabled,
  importing,
  onOpen,
  onMindmap,
  onChooseImport,
  onImportURL,
  onChooseConversation,
  onDropConversation,
  onPasteConversation,
  onOpenConflicts,
}: {
  files: NoteFile[];
  conflicts: ConflictRecord[];
  cloudEnabled: boolean;
  importing: boolean;
  onOpen: (id: string) => void;
  onMindmap: () => void;
  onChooseImport: (kind: 'files' | 'folder') => void;
  onImportURL: (url: string) => Promise<void>;
  onChooseConversation: (kind?: 'files' | 'folder') => void;
  onDropConversation: (files: File[]) => Promise<void>;
  onPasteConversation: (text?: string) => Promise<void>;
  onOpenConflicts: () => void;
}) {
  const tags = taxonomy(files);
  const categories = categoryCounts(files);
  const clipboardRecords = files
    .filter(isClipboardKnowledgeRecord)
    .sort((left, right) => right.modifiedAt - left.modifiedAt);
  return (
    <main className="main-content hub">
      <header className="hub-header">
        <div>
          <p className="eyebrow">Local-first workspace</p>
          <h1>{t('hub')}</h1>
          <p>{files.length} Markdown notes, encrypted on this device.</p>
        </div>
        <span className="account-state">{cloudEnabled ? t('accountOn') : t('accountOff')}</span>
      </header>
      <section className="hub-grid">
        <article className="hub-panel recent-panel">
          <div className="panel-heading">
            <h2>{t('recentDocuments')}</h2>
            <span>{files.length}</span>
          </div>
          <ul className="recent-list">
            {[...files].sort((a, b) => b.modifiedAt - a.modifiedAt).slice(0, 8).map(file => (
              <li key={file.id}>
                <button type="button" onClick={() => onOpen(file.id)}>
                  <strong>{file.path.split('/').at(-1)}</strong>
                  <span>{file.path}</span>
                </button>
              </li>
            ))}
          </ul>
        </article>
        <article className="hub-panel">
          <div className="panel-heading"><h2>{t('categories')}</h2><span>{categories.length}</span></div>
          <ul className="taxonomy-summary">
            {categories.slice(0, 8).map(item => <li key={item.name}><span>{item.name}</span><b>{item.count}</b></li>)}
          </ul>
        </article>
        <article className="hub-panel">
          <div className="panel-heading"><h2>{t('allTags')}</h2><span>{tags.length}</span></div>
          <div className="tag-cloud">
            {tags.slice(0, 18).map(item => <span key={item.identity}>{item.name}<b>{item.count}</b></span>)}
          </div>
        </article>
        <article className="hub-panel recent-panel clipboard-knowledge-panel">
          <div className="panel-heading">
            <div><p className="eyebrow">Clipboard</p><h2>{t('clipboardKnowledge')}</h2></div>
            <span>{clipboardRecords.length}</span>
          </div>
          {clipboardRecords.length ? (
            <ul className="recent-list">
              {clipboardRecords.map(file => (
                <li key={file.id}>
                  <button type="button" onClick={() => onOpen(file.id)}>
                    <strong>{clipboardKnowledgeTitle(file)}</strong>
                    <span>{isFavoriteClipboardRecord(file) ? '★ · ' : ''}{file.metadata.tags.join(' · ')}</span>
                  </button>
                </li>
              ))}
            </ul>
          ) : <p className="empty-copy">{t('clipboardKnowledgeEmpty')}</p>}
        </article>
        <Suspense fallback={<article className="hub-panel action-panel"><p>{t('deepSearch')}…</p></article>}>
          <DeepSearchPanel files={files} onOpen={onOpen} />
        </Suspense>
        <article className="hub-panel action-panel">
          <p className="eyebrow">Graph</p>
          <h2>Mindmap Station</h2>
          <p>Links, backlinks, tags and categories in one local graph.</p>
          <button type="button" onClick={onMindmap}>{t('open')}</button>
        </article>
        <ImportPanel
          importing={importing}
          onChoose={onChooseImport}
          onImportURL={onImportURL}
        />
        <ConversationInboxPanel
          importing={importing}
          onChoose={onChooseConversation}
          onDrop={onDropConversation}
          onPaste={onPasteConversation}
        />
        <article className="hub-panel action-panel conflict-summary">
          <p className="eyebrow">{t('versionHistory')}</p>
          <h2>{conflicts.filter(record => !record.resolution).length} {t('unresolvedConflicts')}</h2>
          <p>{conflicts.length} {t('preservedConflictSets')}</p>
          <button type="button" onClick={onOpenConflicts}>{t('compareVersions')}</button>
        </article>
      </section>
    </main>
  );
}

function ConversationInboxPanel({
  importing,
  onChoose,
  onDrop,
  onPaste,
}: {
  importing: boolean;
  onChoose: (kind?: 'files' | 'folder') => void;
  onDrop: (files: File[]) => Promise<void>;
  onPaste: (text?: string) => Promise<void>;
}) {
  const [draft, setDraft] = useState('');
  return (
    <article
      className="hub-panel conversation-inbox-panel"
      onDragOver={event => {
        if (event.dataTransfer.types.includes('Files')) event.preventDefault();
      }}
      onDrop={event => {
        if (!event.dataTransfer.files.length) return;
        event.preventDefault();
        void onDrop([...event.dataTransfer.files]);
      }}
    >
      <div className="panel-heading">
        <div>
          <p className="eyebrow">Claude · ChatGPT · Markdown</p>
          <h2>{t('conversationInbox')}</h2>
        </div>
      </div>
      <p>{t('conversationDescription')}</p>
      <textarea
        value={draft}
        rows={4}
        placeholder={t('conversationPastePlaceholder')}
        onChange={event => setDraft(event.target.value)}
        onPaste={event => {
          if (!draft && event.clipboardData.getData('text/plain')) {
            event.currentTarget.dataset.pasted = 'true';
          }
        }}
      />
      <div className="import-actions">
        <button type="button" disabled={importing} onClick={() => onChoose('files')}>{t('conversationImportExport')}</button>
        <button type="button" disabled={importing} onClick={() => onChoose('folder')}>{t('importFolder')}</button>
        <button type="button" disabled={importing} onClick={() => {
          void onPaste(draft || undefined).then(() => setDraft(''));
        }}>{draft ? t('conversationPreview') : t('conversationReadClipboard')}</button>
      </div>
    </article>
  );
}

function ImportPanel({
  importing,
  onChoose,
  onImportURL,
}: {
  importing: boolean;
  onChoose: (kind: 'files' | 'folder') => void;
  onImportURL: (url: string) => Promise<void>;
}) {
  const [url, setURL] = useState('');
  return (
    <article className="hub-panel import-panel">
      <div className="panel-heading"><h2>{t('importNotes')}</h2></div>
      <p>{t('importDescription')}</p>
      <div className="import-actions">
        <button type="button" disabled={importing} onClick={() => onChoose('files')}>{t('importFiles')}</button>
        <button type="button" disabled={importing} onClick={() => onChoose('folder')}>{t('importFolder')}</button>
      </div>
      <form onSubmit={event => {
        event.preventDefault();
        if (url.trim()) {
          void onImportURL(url.trim()).then(() => setURL(''));
        }
      }}>
        <label htmlFor="import-url">{t('importURL')}</label>
        <div>
          <input
            id="import-url"
            type="url"
            inputMode="url"
            placeholder="https://example.com/note.md"
            value={url}
            onChange={event => setURL(event.target.value)}
          />
          <button type="submit" disabled={importing || !url.trim()}>{importing ? '…' : t('import')}</button>
        </div>
      </form>
    </article>
  );
}

function ConflictManagerDialog({
  records,
  onClose,
  onResolve,
}: {
  records: ConflictRecord[];
  onClose: () => void;
  onResolve: (
    record: ConflictRecord,
    content: string,
    strategy: ConflictResolution['strategy'],
  ) => Promise<void>;
}) {
  const sorted = [...records].sort((left, right) => {
    if (Boolean(left.resolution) !== Boolean(right.resolution)) {
      return left.resolution ? 1 : -1;
    }
    return right.createdAt - left.createdAt;
  });
  const [selectedId, setSelectedId] = useState(sorted[0]?.id);
  const selected = sorted.find(record => record.id === selectedId) ?? sorted[0];
  return (
    <div className="dialog-backdrop conflict-backdrop" role="presentation">
      <section className="conflict-dialog" role="dialog" aria-modal="true" aria-labelledby="conflict-title">
        <header>
          <div>
            <p className="eyebrow">{t('versionHistory')}</p>
            <h2 id="conflict-title">{t('compareAndCombine')}</h2>
          </div>
          <button type="button" aria-label={t('cancel')} onClick={onClose}>×</button>
        </header>
        {sorted.length ? (
          <div className="conflict-layout">
            <nav aria-label={t('conflicts')}>
              {sorted.map(record => (
                <button
                  className={record.id === selected?.id ? 'selected' : ''}
                  type="button"
                  key={record.id}
                  onClick={() => setSelectedId(record.id)}
                >
                  <strong>{record.path}</strong>
                  <span>{record.resolution ? t('resolved') : t('needsReview')}</span>
                </button>
              ))}
            </nav>
            {selected && (
              <ConflictResolver
                key={`${selected.id}:${selected.resolution?.resolvedAt ?? 0}`}
                record={selected}
                onResolve={onResolve}
              />
            )}
          </div>
        ) : (
          <div className="conflict-empty"><p>{t('noConflicts')}</p></div>
        )}
      </section>
    </div>
  );
}

function ConflictResolver({
  record,
  onResolve,
}: {
  record: ConflictRecord;
  onResolve: (
    record: ConflictRecord,
    content: string,
    strategy: ConflictResolution['strategy'],
  ) => Promise<void>;
}) {
  const base = record.versions.find(version => version.source === 'base')?.content;
  const local = record.versions.find(version => version.source === 'local');
  const remote = record.versions.find(version => version.source === 'remote');
  const [draft, setDraft] = useState(suggestedConflictContent(record));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();

  async function save(content: string, strategy: ConflictResolution['strategy']) {
    setSaving(true);
    setError(undefined);
    try {
      await onResolve(record, content, strategy);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="conflict-resolver">
      <div className="conflict-meta">
        <div><strong>{record.path}</strong><span>{record.reason}</span></div>
        <time dateTime={new Date(record.createdAt).toISOString()}>{new Date(record.createdAt).toLocaleString()}</time>
      </div>
      <div className="version-compare">
        <VersionPane label={local?.label ?? t('deletedOnDevice')} content={local?.content} base={base} />
        <VersionPane label={remote?.label ?? t('deletedOnRemote')} content={remote?.content} base={base} />
      </div>
      {base !== undefined && (
        <details className="base-version">
          <summary>{t('commonAncestor')}</summary>
          <pre>{base}</pre>
        </details>
      )}
      <label className="merge-editor">
        <span>{t('combinedResult')}</span>
        <textarea value={draft} onChange={event => setDraft(event.target.value)} spellCheck={false} />
      </label>
      {record.resolution ? (
        <p className="resolution-status">{t('resolved')} · {record.resolution.strategy}</p>
      ) : (
        <div className="resolution-actions">
          <button type="button" disabled={saving || local?.content === undefined} onClick={() => {
            if (local?.content !== undefined) {
              setDraft(local.content);
              void save(local.content, 'local');
            }
          }}>{t('keepLocal')}</button>
          <button type="button" disabled={saving || remote?.content === undefined} onClick={() => {
            if (remote?.content !== undefined) {
              setDraft(remote.content);
              void save(remote.content, 'remote');
            }
          }}>{t('keepRemote')}</button>
          <button type="button" disabled={saving} onClick={() => setDraft(combineConflictContent(record))}>{t('combineBoth')}</button>
          <button className="primary-button" type="button" disabled={saving} onClick={() => void save(draft, 'manual')}>
            {saving ? '…' : t('saveCombined')}
          </button>
        </div>
      )}
      {error && <p className="dialog-error" role="alert">{error}</p>}
      <p className="preservation-note">{t('versionsPreserved')}</p>
    </div>
  );
}

function VersionPane({
  label,
  content,
  base,
}: {
  label: string;
  content?: string;
  base?: string;
}) {
  if (content === undefined) {
    return <section className="version-pane"><header>{label}</header><p>{t('versionDeleted')}</p></section>;
  }
  const changed = changedLineRange(base, content);
  const lines = content.split('\n');
  return (
    <section className="version-pane">
      <header>{label}</header>
      <pre>{lines.map((line, index) => (
        <span className={index >= changed.start && index < changed.end ? 'changed' : ''} key={`${index}-${line}`}>
          <i>{index + 1}</i>{line || ' '}{index < lines.length - 1 ? '\n' : ''}
        </span>
      ))}</pre>
    </section>
  );
}

function changedLineRange(base: string | undefined, value: string) {
  if (base === undefined) {
    return { start: 0, end: value.split('\n').length };
  }
  const baseLines = base.split('\n');
  const lines = value.split('\n');
  let start = 0;
  while (start < baseLines.length && start < lines.length && baseLines[start] === lines[start]) {
    start += 1;
  }
  let suffix = 0;
  while (
    suffix < baseLines.length - start
    && suffix < lines.length - start
    && baseLines[baseLines.length - suffix - 1] === lines[lines.length - suffix - 1]
  ) {
    suffix += 1;
  }
  return { start, end: lines.length - suffix };
}

function FilesPanel({
  files,
  selectedId,
  onOpen,
  onCreate,
  onImport,
}: {
  files: NoteFile[];
  selectedId?: string;
  onOpen: (id: string) => void;
  onCreate: () => void;
  onImport: () => void;
}) {
  return (
    <section className="sidebar-panel">
      <header className="sidebar-header">
        <h2>{t('files')}</h2>
        <div className="sidebar-actions">
          <button type="button" title={t('importFiles')} onClick={onImport}>⇧</button>
          <button type="button" title={t('newNote')} onClick={onCreate}>＋</button>
        </div>
      </header>
      <ul className="file-list">
        {files.map(file => (
          <li key={file.id}>
            <button
              className={file.id === selectedId ? 'selected' : ''}
              type="button"
              draggable
              onDragStart={event => event.dataTransfer.setData('application/x-ksamint-note', file.id)}
              onClick={() => onOpen(file.id)}
            >
              <span aria-hidden="true">▤</span>{file.path}
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function SearchPanel({
  query,
  hits,
  hasCurrentFile,
  canUndo,
  onQuery,
  onOpen,
  onPreview,
  onUndo,
}: {
  query: string;
  hits: SearchHit[];
  hasCurrentFile: boolean;
  canUndo: boolean;
  onQuery: (value: string) => void;
  onOpen: (hit: SearchHit) => void;
  onPreview: (options: ReplaceOptions, scope: ReplaceScope) => void;
  onUndo: () => void;
}) {
  const [replacement, setReplacement] = useState('');
  const [caseSensitive, setCaseSensitive] = useState(false);
  const [regularExpression, setRegularExpression] = useState(false);
  const options = { find: query, replacement, caseSensitive, regularExpression };
  return (
    <section className="sidebar-panel">
      <header className="sidebar-header"><h2>{t('search')}</h2><span>{hits.length}</span></header>
      <label className="search-box">
        <span className="sr-only">{t('searchWorkspace')}</span>
        <input autoFocus value={query} onChange={event => onQuery(event.target.value)} placeholder={t('searchWorkspace')} />
      </label>
      <section className="replace-controls" aria-label={t('replace')}>
        <input
          value={replacement}
          onChange={event => setReplacement(event.target.value)}
          placeholder={t('replaceWith')}
          aria-label={t('replaceWith')}
        />
        <div className="replace-options">
          <label><input type="checkbox" checked={caseSensitive} onChange={event => setCaseSensitive(event.target.checked)} />{t('matchCase')}</label>
          <label><input type="checkbox" checked={regularExpression} onChange={event => setRegularExpression(event.target.checked)} />{t('regularExpression')}</label>
        </div>
        <div className="replace-actions">
          <button type="button" disabled={!query || !hasCurrentFile} onClick={() => onPreview(options, 'current')}>{t('replaceCurrent')}</button>
          <button type="button" disabled={!query} onClick={() => onPreview(options, 'workspace')}>{t('replaceWorkspace')}</button>
        </div>
        {canUndo && <button className="replace-undo-inline" type="button" onClick={onUndo}>{t('undoReplace')}</button>}
      </section>
      {query && !hits.length ? <p className="empty-copy">{t('noResults')}</p> : (
        <ul className="search-list">
          {hits.map(hit => (
            <li key={`${hit.fileId}-${hit.line}`}>
              <button type="button" onClick={() => onOpen(hit)}>
                <strong>{hit.path}:{hit.line}</strong>
                <span>{hit.snippet || ' '}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function ReplacePreviewDialog({
  plan,
  onClose,
  onApply,
}: {
  plan: WorkspaceReplacePlan;
  onClose: () => void;
  onApply: (selectedFileIds: string[]) => void;
}) {
  const [selected, setSelected] = useState(() => new Set(plan.changes.map(change => change.fileId)));
  const selectedOccurrences = plan.changes.reduce((total, change) => (
    selected.has(change.fileId) ? total + change.occurrences : total
  ), 0);
  return (
    <div className="dialog-backdrop">
      <section className="taxonomy-dialog replace-dialog" role="dialog" aria-modal="true" aria-label={t('replacePreview')}>
        <header>
          <div><p className="eyebrow">{t('replace')}</p><h2>{t('replacePreview')}</h2></div>
          <button type="button" onClick={onClose}>×</button>
        </header>
        <div className="replace-summary">
          <strong>{selectedOccurrences}</strong>
          <span>{t('occurrences')} · {selected.size} {t('affectedFiles').toLocaleLowerCase()}</span>
          <code>{plan.options.find} → {plan.options.replacement || '∅'}</code>
          <div>
            <button type="button" onClick={() => setSelected(new Set(plan.changes.map(change => change.fileId)))}>{t('selectAll')}</button>
            <button type="button" onClick={() => setSelected(new Set())}>{t('clearAll')}</button>
          </div>
        </div>
        <ul className="replace-preview-list">
          {plan.changes.map(change => (
            <li key={change.fileId}>
              <label>
                <input
                  type="checkbox"
                  checked={selected.has(change.fileId)}
                  onChange={event => setSelected(current => {
                    const next = new Set(current);
                    if (event.target.checked) next.add(change.fileId);
                    else next.delete(change.fileId);
                    return next;
                  })}
                />
                <span><strong>{change.path}</strong><small>{change.occurrences} {t('occurrences')}</small></span>
              </label>
            </li>
          ))}
        </ul>
        <footer>
          <button type="button" onClick={onClose}>{t('cancel')}</button>
          <button className="primary-button" type="button" disabled={!selected.size} onClick={() => onApply([...selected])}>
            {t('replaceSelected')}
          </button>
        </footer>
      </section>
    </div>
  );
}

function TagsPanel({
  files,
  onFilter,
  onManage,
  onAssignCategory,
}: {
  files: NoteFile[];
  onFilter: (value: string) => void;
  onManage: () => void;
  onAssignCategory: (fileId: string, category?: string) => void;
}) {
  const tags = taxonomy(files);
  const categories = categoryCounts(files);
  return (
    <section className="sidebar-panel taxonomy-panel">
      <header className="sidebar-header">
        <h2>{t('tags')}</h2>
        <button type="button" onClick={onManage}>{t('manageTags')}</button>
      </header>
      <h3>{t('allTags')}</h3>
      <ul>
        {tags.map(item => (
          <li key={item.identity}>
            <button type="button" onClick={() => onFilter(`tag:"${item.name}"`)}>
              <span>{item.name}</span><b>{item.count}</b>
            </button>
          </li>
        ))}
      </ul>
      <h3>{t('categories')}</h3>
      <ul>
        {categories.map(item => (
          <li
            key={item.name}
            onDragOver={event => {
              if (event.dataTransfer.types.includes('application/x-ksamint-note')) {
                event.preventDefault();
              }
            }}
            onDrop={event => {
              event.preventDefault();
              const fileId = event.dataTransfer.getData('application/x-ksamint-note');
              if (fileId) {
                onAssignCategory(fileId, item.name);
              }
            }}
          >
            <button type="button" onClick={() => onFilter(`category:"${item.name}"`)}>
              <span>{item.name}</span><b>{item.count}</b>
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function PreviewPanel({ content }: { content: string }) {
  return (
    <section className="sidebar-panel preview-panel">
      <header className="sidebar-header"><h2>{t('preview')}</h2></header>
      <article className="markdown-preview" dangerouslySetInnerHTML={{ __html: renderMarkdown(content) }} />
    </section>
  );
}

function TagEditor({
  file,
  onAdd,
  onRemove,
  onCategory,
}: {
  file: NoteFile;
  onAdd: (tag: string) => void;
  onRemove: (tag: string) => void;
  onCategory: (category?: string) => void;
}) {
  const [value, setValue] = useState('');
  return (
    <div className="document-tags">
      {file.metadata.tags.slice(0, 4).map(tag => (
        <button
          className="tag-chip"
          key={canonicalTag(tag)}
          type="button"
          title={`${t('removeTag')}: ${tag}`}
          onClick={() => onRemove(tag)}
        >
          {tag}<span aria-hidden="true">×</span>
        </button>
      ))}
      <form onSubmit={event => {
        event.preventDefault();
        onAdd(value);
        setValue('');
      }}>
        <label className="sr-only" htmlFor="add-tag">{t('addTag')}</label>
        <input id="add-tag" value={value} onChange={event => setValue(event.target.value)} placeholder={`+ ${t('addTag')}`} />
      </form>
      <CategoryEditor
        key={`${file.id}:${file.metadata.category ?? ''}`}
        initialValue={file.metadata.category ?? ''}
        onCategory={onCategory}
      />
    </div>
  );
}

function CategoryEditor({
  initialValue,
  onCategory,
}: {
  initialValue: string;
  onCategory: (category?: string) => void;
}) {
  const [category, setCategory] = useState(initialValue);
  return (
    <form
      className="category-form"
      onSubmit={event => {
        event.preventDefault();
        onCategory(category);
      }}
    >
      <label className="sr-only" htmlFor="set-category">{t('setCategory')}</label>
      <input
        id="set-category"
        value={category}
        onChange={event => setCategory(event.target.value)}
        onBlur={() => onCategory(category)}
        placeholder={t('category')}
      />
    </form>
  );
}

function TagManagerDialog({
  files,
  onClose,
  onApply,
}: {
  files: NoteFile[];
  onClose: () => void;
  onApply: (
    kind: TaxonomyKind,
    action: TaxonomyAction,
    source: string,
    target: string,
    signal: AbortSignal,
    onProgress: (completed: number, total: number) => void,
  ) => Promise<void>;
}) {
  const [kind, setKind] = useState<TaxonomyKind>('tag');
  const [source, setSource] = useState('');
  const [target, setTarget] = useState('');
  const [action, setAction] = useState<TaxonomyAction>('rename');
  const [progress, setProgress] = useState<[number, number]>();
  const [error, setError] = useState<string>();
  const abort = useRef<AbortController | undefined>(undefined);
  const items = kind === 'tag'
    ? taxonomy(files).map(item => ({ name: item.name, count: item.count }))
    : categoryCounts(files);
  const selected = items.find(item => item.name === source);
  const needsTarget = action !== 'delete';

  async function apply() {
    if (!source || (needsTarget && !target.trim())) {
      return;
    }
    const controller = new AbortController();
    abort.current = controller;
    setProgress([0, selected?.count ?? 0]);
    setError(undefined);
    try {
      await onApply(kind, action, source, target, controller.signal, (completed, total) => {
        setProgress([completed, total]);
      });
      onClose();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
      setProgress(undefined);
    }
  }

  return (
    <div className="dialog-backdrop" role="presentation" onMouseDown={event => {
      if (event.target === event.currentTarget && !progress) {
        onClose();
      }
    }}>
      <section className="taxonomy-dialog" role="dialog" aria-modal="true" aria-labelledby="taxonomy-title">
        <header>
          <div>
            <p className="eyebrow">{t('workspace')}</p>
            <h2 id="taxonomy-title">{t('manageTags')}</h2>
          </div>
          <button type="button" aria-label={t('cancel')} onClick={onClose} disabled={Boolean(progress)}>×</button>
        </header>
        <div className="dialog-segments" role="tablist">
          <button className={kind === 'tag' ? 'active' : ''} type="button" onClick={() => {
            setKind('tag');
            setSource('');
          }}>{t('tags')}</button>
          <button className={kind === 'category' ? 'active' : ''} type="button" onClick={() => {
            setKind('category');
            setSource('');
          }}>{t('categories')}</button>
        </div>
        <div className="taxonomy-dialog-body">
          <ul className="taxonomy-manager-list">
            {items.map(item => (
              <li key={item.name}>
                <button className={source === item.name ? 'selected' : ''} type="button" onClick={() => {
                  setSource(item.name);
                  setTarget('');
                }}>
                  <span>{item.name}</span><b>{item.count}</b>
                </button>
              </li>
            ))}
          </ul>
          <div className="taxonomy-operation">
            <label>
              <span>{t('affectedFiles')}</span>
              <strong>{selected?.count ?? 0}</strong>
            </label>
            <div className="operation-buttons">
              {(['rename', 'merge', 'delete'] as const).map(value => (
                <button className={action === value ? 'active' : ''} type="button" key={value} onClick={() => setAction(value)}>
                  {t(value)}
                </button>
              ))}
            </div>
            {needsTarget && (
              <label>
                <span>{t('target')}</span>
                <input value={target} onChange={event => setTarget(event.target.value)} autoComplete="off" />
              </label>
            )}
            {progress && (
              <progress value={progress[0]} max={Math.max(progress[1], 1)}>
                {progress[0]} / {progress[1]}
              </progress>
            )}
            {error && <p className="dialog-error" role="alert">{error}</p>}
          </div>
        </div>
        <footer>
          <button type="button" onClick={() => progress ? abort.current?.abort() : onClose()}>
            {t('cancel')}
          </button>
          <button className="primary-button" type="button" disabled={!source || (needsTarget && !target.trim()) || Boolean(progress)} onClick={apply}>
            {t('apply')}
          </button>
        </footer>
      </section>
    </div>
  );
}

function EmptyState({ onCreate }: { onCreate: () => void }) {
  return (
    <div className="empty-editor">
      <p>No note selected</p>
      <button className="primary-button" type="button" onClick={onCreate}>{t('newNote')}</button>
    </div>
  );
}

function RouteLoading() {
  return <div className="route-loading" role="status">Loading…</div>;
}

function RailButton({
  label,
  symbol,
  active,
  onClick,
}: {
  label: string;
  symbol: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button className={active ? 'active' : ''} type="button" title={label} aria-label={label} onClick={onClick}>
      <span aria-hidden="true">{symbol}</span>
    </button>
  );
}

function StatusRow({ label, value }: { label: string; value: string }) {
  return <div className="status-row"><span>{label}</span><strong>{value}</strong></div>;
}

function taxonomy(files: NoteFile[]) {
  const values = new Map<string, { identity: string; name: string; count: number }>();
  for (const file of files) {
    for (const tag of file.metadata.tags) {
      const identity = canonicalTag(tag);
      const item = values.get(identity) ?? { identity, name: tag, count: 0 };
      item.count += 1;
      values.set(identity, item);
    }
  }
  return [...values.values()].sort((left, right) => left.name.localeCompare(right.name));
}

function categoryCounts(files: NoteFile[]) {
  const values = new Map<string, number>();
  for (const file of files) {
    if (file.metadata.category) {
      values.set(file.metadata.category, (values.get(file.metadata.category) ?? 0) + 1);
    }
  }
  return [...values].map(([name, count]) => ({ name, count })).sort((a, b) => a.name.localeCompare(b.name));
}

function parseMetadataLazy(content: string) {
  const frontMatter = content.match(/^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)/u)?.[1] ?? '';
  const category = frontMatter.match(/^category:\s*["']?([^"'\r\n#]+)["']?/mu)?.[1]?.trim();
  const rawTags = frontMatter.match(/^tags:\s*\[([^\]]*)\]/mu)?.[1] ?? '';
  const tags = rawTags.split(',').map(tag => tag.trim().replace(/^["']|["']$/gu, '')).filter(Boolean);
  return { category, tags };
}
