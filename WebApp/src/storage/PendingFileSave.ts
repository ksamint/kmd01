export type PendingFileEdit = {
  fileId: string;
  content: string;
};

export class PendingFileSave<T> {
  private pending?: PendingFileEdit;
  private timer?: ReturnType<typeof setTimeout>;
  private writeChain: Promise<void> = Promise.resolve();
  private activeWrites = 0;

  constructor(
    private readonly write: (fileId: string, content: string) => Promise<T>,
    private readonly onSaved: (saved: T, edit: PendingFileEdit) => void,
    private readonly onSavingChange: (saving: boolean) => void,
    private readonly onBackgroundError: (error: unknown) => void,
    private readonly delay = 450,
  ) {}

  queue(fileId: string, content: string) {
    if (this.pending && this.pending.fileId !== fileId) {
      // Replacing the pending edit would silently discard the other file's text.
      void this.flush().catch(this.onBackgroundError);
    }
    this.pending = { fileId, content };
    this.onSavingChange(true);
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      void this.flush().catch(this.onBackgroundError);
    }, this.delay);
  }

  async flush(): Promise<T | undefined> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    const edit = this.pending;
    if (!edit) {
      await this.writeChain;
      this.updateSavingState();
      return undefined;
    }
    this.pending = undefined;
    this.activeWrites += 1;
    this.updateSavingState();
    let saved: T | undefined;
    const task = this.writeChain
      .catch(() => undefined)
      .then(async () => {
        saved = await this.write(edit.fileId, edit.content);
      });
    this.writeChain = task;
    try {
      await task;
      if (saved !== undefined && !this.hasPendingEditFor(edit.fileId)) {
        this.onSaved(saved, edit);
      }
      return saved;
    } catch (error) {
      if (!this.pending) this.pending = edit;
      throw error;
    } finally {
      this.activeWrites -= 1;
      this.updateSavingState();
    }
  }

  private hasPendingEditFor(fileId: string) {
    return this.pending?.fileId === fileId;
  }

  private updateSavingState() {
    this.onSavingChange(Boolean(this.pending) || this.activeWrites > 0);
  }
}
