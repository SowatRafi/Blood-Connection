// A view owns its temporary image URLs; leaving it invalidates even requests that ignore abort.
export class PrivateEvidence {
  constructor(urls = URL) {
    this.urls = urls;
    this.version = 0;
    this.active = new Set();
    this.pending = new Set();
  }

  // Abort reduces wasted work; the version check is the authority against late responses.
  clear() {
    this.version += 1;
    for (const controller of this.pending) controller.abort();
    this.pending.clear();
    for (const url of this.active) this.urls.revokeObjectURL(url);
    this.active.clear();
  }

  // fetchImage receives a cancellation signal and returns a Blob. A superseded load
  // returns null; a current failure throws so the active report can show a retry message.
  async load(fetchImage) {
    const version = this.version;
    const controller = new AbortController();
    this.pending.add(controller);
    try {
      const blob = await fetchImage(controller.signal);
      if (version !== this.version) return null;
      // Restrict previews to sanitized bounded raster images, never HTML/SVG returned by an error page.
      if (blob.type !== 'image/jpeg' || !blob.size || blob.size > 5 * 1024 * 1024) {
        throw new Error('This image could not be displayed safely. Refresh the report or try again.');
      }
      const url = this.urls.createObjectURL(blob);
      this.active.add(url);
      return url;
    } catch (error) {
      if (version !== this.version) return null;
      throw error;
    } finally {
      this.pending.delete(controller);
    }
  }
}
