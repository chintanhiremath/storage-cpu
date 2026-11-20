import assert from 'node:assert/strict';

const pageSize = 4096;
const ssdCapacity = 1_000_000_000_000;
const cacheSize = 64_000_000_000;
const tileCount = 16;
const coresPerTile = 16;
const storageBase = 0x1_0000_0000;
const ramSize = 4096;
const ebreak = 0x0010_0073;

function signExtend(value, bits) {
  return value << (32 - bits) >> (32 - bits);
}

class FlashStorage {
  constructor(pages) {
    this.pages = pages;
    this.reads = 0;
  }

  readBlock(block) {
    const page = this.pages.get(block);
    if (!page) throw new Error(`No image page at storage block ${block}`);
    this.reads++;
    return Buffer.from(page);
  }
}

class HostLink {
  constructor(flash) {
    this.flash = flash;
    this.payloadBytes = 0;
  }

  readBlock(block) {
    const page = this.flash.readBlock(block);
    this.payloadBytes += page.length;
    return page;
  }

  readResult(deviceRam) {
    const result = Buffer.from(deviceRam.subarray(0, 8));
    this.payloadBytes += result.length;
    return result.readBigInt64LE();
  }
}

class PageCache {
  constructor(storage, capacityBytes) {
    this.storage = storage;
    this.capacity = Math.floor(capacityBytes / pageSize);
    this.pages = new Map();
    this.hits = 0;
  }

  read(address, width) {
    const offset = address - storageBase;
    if (address % width !== 0 || offset < 0 || offset + width > ssdCapacity) {
      throw new Error(`Invalid storage address ${address.toString(16)}`);
    }

    const block = Math.floor(offset / pageSize);
    let page = this.pages.get(block);
    if (page) {
      this.hits++;
      this.pages.delete(block);
    } else {
      page = this.storage.readBlock(block);
      if (this.pages.size === this.capacity) {
        this.pages.delete(this.pages.keys().next().value);
      }
    }
    this.pages.set(block, page);
    return width === 4 ? page.readUInt32LE(offset % pageSize)
      : page.readBigInt64LE(offset % pageSize);
  }
}

function* execute(cache, entry, coreId) {
  const registers = new BigInt64Array(32);
  registers[2] = BigInt(coreId); // Seed each demo task with its local core ID.
  const ram = Buffer.alloc(ramSize);
  let pc = entry;

  for (let fetches = 1; fetches <= 100; fetches++) {
    const instruction = cache.read(pc, 4);
    if (instruction === ebreak) return { registers, ram, fetches };

    const opcode = instruction & 0x7f;
    const rd = instruction >>> 7 & 31;
    const funct3 = instruction >>> 12 & 7;
    const rs1 = instruction >>> 15 & 31;
    const rs2 = instruction >>> 20 & 31;
    let next = pc + 4;

    if (opcode === 0x13 && funct3 === 0) { // ADDI
      if (rd !== 0) registers[rd] = registers[rs1] + BigInt(instruction >> 20);
    } else if (opcode === 0x17) { // AUIPC
      if (rd !== 0) registers[rd] = BigInt(pc) + BigInt(instruction & 0xffff_f000);
    } else if (opcode === 0x63 && funct3 === 1) { // BNE
      const displacement = (instruction >>> 31) << 12
        | (instruction >>> 7 & 1) << 11
        | (instruction >>> 25 & 63) << 5
        | (instruction >>> 8 & 15) << 1;
      if (registers[rs1] !== registers[rs2]) next = pc + signExtend(displacement, 13);
    } else if (funct3 === 3 && (opcode === 0x03 || opcode === 0x23)) { // LD / SD
      const immediate = opcode === 0x03 ? instruction >> 20
        : signExtend((instruction >>> 25) << 5 | (instruction >>> 7 & 31), 12);
      const address = BigInt.asUintN(64, registers[rs1] + BigInt(immediate));
      if (opcode === 0x03 && address >= BigInt(storageBase) && address < BigInt(storageBase + ssdCapacity)) {
        const value = cache.read(Number(address), 8);
        if (rd !== 0) registers[rd] = value;
      } else if (address % 8n !== 0n || address + 8n > BigInt(ram.length)) {
        throw new Error(`Invalid RAM address ${address.toString(16)}`);
      } else if (opcode === 0x23) {
        ram.writeBigInt64LE(registers[rs2], Number(address));
      } else {
        const value = ram.readBigInt64LE(Number(address));
        if (rd !== 0) registers[rd] = value;
      }
    } else {
      throw new Error(`Unsupported instruction 0x${instruction.toString(16)}`);
    }
    pc = next;
    yield;
  }
  throw new Error('Instruction limit exceeded');
}

function demoImage() {
  const firstBlock = Math.floor(ssdCapacity / pageSize) - 2;
  const firstPage = Buffer.alloc(pageSize);
  const secondPage = Buffer.alloc(pageSize);
  const start = pageSize - 16;

  firstPage.writeBigInt64LE(3n, start - 8);        // input stored on flash
  firstPage.writeUInt32LE(0x0000_0217, start);      // auipc x4, 0
  firstPage.writeUInt32LE(0xff82_3083, start + 4);  // ld x1, -8(x4)
  firstPage.writeUInt32LE(0x00e1_0113, start + 8);  // addi x2, x2, 14
  firstPage.writeUInt32LE(0xfff0_8093, start + 12); // addi x1, x1, -1
  secondPage.writeUInt32LE(0xfe00_9ce3, 0);       // bne x1, x0, -8
  secondPage.writeUInt32LE(0x0020_3023, 4);       // sd x2, 0(x0)
  secondPage.writeUInt32LE(0x0000_3183, 8);       // ld x3, 0(x0)
  secondPage.writeUInt32LE(ebreak, 12);

  return {
    storage: new Map([[firstBlock, firstPage], [firstBlock + 1, secondPage]]),
    entry: storageBase + firstBlock * pageSize + start,
  };
}

const { storage, entry } = demoImage();
console.log(`Simulated SSD: ${ssdCapacity.toLocaleString('en-US')} bytes`);
console.log(`Program starts at SSD byte ${(entry - storageBase).toLocaleString('en-US')}`);

function runCores(caches) {
  let active = caches.map((cache, id) => ({ id, instructions: execute(cache, entry, id) }));
  const results = new Array(caches.length);

  while (active.length > 0) {
    active = active.filter(({ id, instructions }) => {
      const step = instructions.next();
      if (!step.done) return true;

      const expected = 42n + BigInt(id);
      const { registers, ram, fetches } = step.value;
      assert.equal(registers[3], expected);
      assert.equal(ram.readBigInt64LE(0), expected);
      assert.equal(fetches, 14);
      results[id] = ram;
      return false;
    });
  }
  return results;
}

for (const [capacity, expectedReads] of [[8 * 1024, 2], [4 * 1024, 6]]) {
  const flash = new FlashStorage(storage);
  const link = new HostLink(flash);
  const cache = new PageCache(link, capacity);
  runCores([cache]);
  assert.equal(flash.reads, expectedReads);
  assert.equal(link.payloadBytes, expectedReads * pageSize);
  console.log(`Host CPU, ${capacity / 1024} KiB cache: ${flash.reads} SSD reads, `
    + `${link.payloadBytes} bytes crossed the host link`);
}

const flash = new FlashStorage(storage);
const link = new HostLink(flash);
const cache = new PageCache(flash, cacheSize);
assert.equal(cache.capacity, 15_625_000);
assert.equal(cache.pages.size, 0);
assert.equal(flash.reads, 0);
runCores([cache]);
assert.equal(flash.reads, 2);
assert.equal(cache.hits, 13);
assert.equal(link.payloadBytes, 0);
console.log('Drive-side CPU, 64 GB cache, cold start: 0 bytes preloaded, 0 host payload bytes');
console.log(`Local flash to cache: ${flash.reads * pageSize} bytes, ${cache.hits} cache hits`);

const readsBeforeWarmRun = flash.reads;
const [deviceRam] = runCores([cache]);
assert.equal(flash.reads, readsBeforeWarmRun);
assert.equal(cache.hits, 28);
assert.equal(link.payloadBytes, 0);
console.log('Warm run: 0 additional flash reads, 0 host payload bytes');

if (process.argv.includes('--read-result')) {
  const result = link.readResult(deviceRam);
  assert.equal(result, 42n);
  assert.equal(link.payloadBytes, 8);
  console.log(`Result returned to host: ${result}, ${link.payloadBytes} payload bytes`);
}

const tileFlash = new FlashStorage(storage);
const tileLink = new HostLink(tileFlash);
const totalPages = cacheSize / pageSize;
const pagesPerTile = Math.floor(totalPages / tileCount);
const extraPages = totalPages % tileCount;
const tiles = Array.from({ length: tileCount }, (_, id) => {
  const pages = pagesPerTile + Number(id < extraPages);
  return new PageCache(tileFlash, pages * pageSize);
});
const coreCaches = tiles.flatMap(tile => Array(coresPerTile).fill(tile));
assert.equal(coreCaches.length, 256);
assert.equal(tiles.reduce((pages, tile) => pages + tile.capacity, 0), totalPages);
assert.equal(tileFlash.reads, 0);

const coldResults = runCores(coreCaches);
assert.equal(coldResults.length, 256);
assert.equal(tileFlash.reads, tileCount * storage.size);
for (const tile of tiles) {
  assert.equal(tile.pages.size, storage.size);
  assert.equal(tile.hits, coresPerTile * 15 - storage.size);
}
assert.equal(tileLink.payloadBytes, 0);
console.log(`Drive-side CPU: ${coldResults.length} cores completed across ${tiles.length} tiles`);
console.log(`Cold run: ${tileFlash.reads} flash reads, ${tileFlash.reads * pageSize} local bytes transferred, ${tileLink.payloadBytes} host payload bytes`);

const coldReads = tileFlash.reads;
runCores(coreCaches);
assert.equal(tileFlash.reads, coldReads);
assert.equal(tileLink.payloadBytes, 0);
console.log(`Warm run across ${coreCaches.length} cores: 0 additional flash reads, ${tileLink.payloadBytes} host payload bytes`);
