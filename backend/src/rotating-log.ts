import { appendFileSync, existsSync, mkdirSync, renameSync, statSync } from 'node:fs';
import { join } from 'node:path';

/**
 * A log destination with a hard size cap. When the current file would pass
 * maxBytes it becomes scrolltax.log.1 (replacing the old one) and a fresh file
 * starts, so the total on disk never goes much past twice maxBytes.
 * Easy to copy off a VM: just grab scrolltax.log and scrolltax.log.1.
 */
export class RotatingLog {
  readonly path: string;
  private readonly maxBytes: number;
  private size: number;

  constructor(dir: string, maxBytes: number, name = 'scrolltax.log') {
    mkdirSync(dir, { recursive: true });
    this.path = join(dir, name);
    this.maxBytes = maxBytes;
    this.size = existsSync(this.path) ? statSync(this.path).size : 0;
  }

  write(chunk: string): void {
    const bytes = Buffer.byteLength(chunk);
    if (this.size > 0 && this.size + bytes > this.maxBytes) {
      renameSync(this.path, `${this.path}.1`);
      this.size = 0;
    }
    appendFileSync(this.path, chunk);
    this.size += bytes;
  }
}

/** Sends every log line to stdout (journald picks it up) and to the capped file. */
export function logStream(file: RotatingLog | null): { write(chunk: string): void } {
  return {
    write(chunk: string) {
      process.stdout.write(chunk);
      file?.write(chunk);
    },
  };
}
