import assert from 'node:assert/strict';
import { closeSync, existsSync, fstatSync, mkdtempSync, openSync, readSync, rmdirSync, unlinkSync, writeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const recordBytes = 16;
const chunkBytes = 1024 * 1024;
const { values } = parseArgs({ options: {
  records: { type: 'string' },
  runs: { type: 'string', default: '3' },
  fixture: { type: 'string' },
  input: { type: 'string' },
} });

function positiveInteger(text, limit) {
  const value = Number(text);
  if (!Number.isSafeInteger(value) || value < 1 || value > limit) throw new Error(`Invalid count: ${text}`);
  return value;
}

function createFixture(path, records) {
  const handle = openSync(path, 'wx');
  const chunk = Buffer.allocUnsafe(chunkBytes);
  let matches = 0;
  let checksum = 0;
  try {
    for (let first = 0; first < records; first += chunk.length / recordBytes) {
      const count = Math.min(records - first, chunk.length / recordBytes);
      for (let index = 0; index < count; index++) {
        const id = first + index;
        const offset = index * recordBytes;
        const tokens = 8 + id % 256;
        const flags = (id >>> 3) & 1;
        chunk.writeUInt32LE(id, offset);
        chunk.writeUInt32LE(tokens, offset + 4);
        chunk.writeUInt32LE(flags, offset + 8);
        chunk.writeUInt32LE((id ^ 0x9e37_79b9) >>> 0, offset + 12);
        if (tokens >= 128 && flags) {
          matches++;
          checksum = (checksum + id) >>> 0;
        }
      }

      const length = count * recordBytes;
      for (let written = 0; written < length;) {
        const step = writeSync(handle, chunk, written, length - written);
        if (step === 0) throw new Error('Fixture write made no progress');
        written += step;
      }
    }
  } finally {
    closeSync(handle);
  }
  return { records, matches, checksum };
}

function scanFixture(path) {
  const handle = openSync(path, 'r');
  const chunk = Buffer.allocUnsafe(chunkBytes);
  let matches = 0;
  let checksum = 0;
  const start = performance.now();
  try {
    const file = fstatSync(handle);
    if (!file.isFile() || file.size % recordBytes !== 0) throw new Error('Expected an aligned record file');
    for (let remaining = file.size; remaining > 0;) {
      const length = Math.min(remaining, chunk.length);
      for (let received = 0; received < length;) {
        const step = readSync(handle, chunk, received, length - received);
        if (step === 0) throw new Error('Unexpected end of record file');
        received += step;
      }
      for (let offset = 0; offset < length; offset += recordBytes) {
        if (chunk.readUInt32LE(offset + 4) >= 128 && (chunk.readUInt32LE(offset + 8) & 1)) {
          matches++;
          checksum = (checksum + chunk.readUInt32LE(offset)) >>> 0;
        }
      }
      remaining -= length;
    }
    return { result: { records: file.size / recordBytes, matches, checksum }, ms: performance.now() - start };
  } finally {
    closeSync(handle);
  }
}

if (values.input !== undefined && (values.fixture !== undefined || values.records !== undefined)) {
  throw new Error('--input reads an existing fixture and cannot be combined with --fixture or --records');
}

const runs = positiveInteger(values.runs, 100);
const records = positiveInteger(values.records ?? '4194304', 2 ** 32);
const scratch = values.input === undefined && values.fixture === undefined
  ? mkdtempSync(join(tmpdir(), 'storage-cpu-bench-')) : undefined;
const file = scratch ? join(scratch, 'records.bin') : resolve(values.input ?? values.fixture);
try {
  let expected = values.input === undefined ? createFixture(file, records) : undefined;
  console.log('Host CPU baseline, single-threaded, buffered filesystem I/O');
  for (let run = 1; run <= runs; run++) {
    const { result, ms } = scanFixture(file);
    expected ??= result;
    assert.deepEqual(result, expected);
    const mib = result.records * recordBytes / 2 ** 20;
    console.log(`Run ${run}: ${mib.toFixed(2)} MiB, ${ms.toFixed(2)} ms, `
      + `${(mib * 1000 / ms).toFixed(1)} MiB/s, ${Math.round(result.records * 1000 / ms)} records/s`);
  }
  console.log(`Records ${expected.records}, matches ${expected.matches}, checksum ${expected.checksum}`);
} finally {
  if (scratch) {
    if (existsSync(file)) unlinkSync(file);
    rmdirSync(scratch);
  }
}
