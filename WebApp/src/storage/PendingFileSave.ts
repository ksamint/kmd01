export type PendingFileEdit = {
  fileId: string;
  content: string;
};

export class PendingFileSave<T> {
  private pending = new Map<string, PendingFileEdit>();
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
    this.pending.set(fileId, { fileId, content });
    this.onSavingChange(true);
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      void this.flush().catch(this.onBackgroundError);
    }, this.delay);
  }

  async flush(): Promise<T | undefined> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    const edits = [...this.pending.values()];
    this.activeWrites += 1;
    this.updateSavingState();
    let saved: T | undefined;
    const task = this.writeChain.catch(() => undefined).then(async () => {
      for (const edit of edits) {
        if (this.pending.get(edit.fileId) !== edit) continue;
        // Keep each file's text queued until its own write succeeds.
        saved = await this.write(edit.fileId, edit.content);
        if (this.pending.get(edit.fileId) === edit) {
          this.pending.delete(edit.fileId);
          this.onSaved(saved, edit);
        }
      }
    });
    this.writeChain = task;
    try {
      await task;
      return saved;
    } finally {
      this.activeWrites -= 1;
      this.updateSavingState();
    }
  }

  private updateSavingState() {
    this.onSavingChange(this.pending.size > 0 || this.activeWrites > 0);
  }
}
