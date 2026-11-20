import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  synth: { type: 'boolean' },
  'full-scan': { type: 'boolean' },
  'emit-boot-image': { type: 'string' },
} });

const commit = 'ef203c2b0a3fb793280f5114941416c425c5b461';
const expectedHash = '0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622';
const rtl = fileURLToPath(new URL('./storage_tile.sv', import.meta.url));
const axiRtl = fileURLToPath(new URL('./storage_tile_axi.sv', import.meta.url));
const testbench = fileURLToPath(new URL('./storage_tile_tb.sv', import.meta.url));
const axiTestbench = fileURLToPath(new URL('./storage_tile_axi_tb.sv', import.meta.url));
const filterRtl = fileURLToPath(new URL('./dataset_filter.sv', import.meta.url));
const filterTestbench = fileURLToPath(new URL('./dataset_filter_tb.sv', import.meta.url));
const scanRtl = fileURLToPath(new URL('./dataset_scan.sv', import.meta.url));
const scanTestbench = fileURLToPath(new URL('./dataset_scan_tb.sv', import.meta.url));
const benchmark = fileURLToPath(new URL('../benchmark.mjs', import.meta.url));

function run(program, args, cwd, timeout = 120_000) {
  const result = spawnSync(program, args, { cwd, stdio: 'inherit', timeout });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${program} exited with ${result.status ?? result.signal}`);
}

async function readCore() {
  if (process.env.PICORV32_RTL) return readFileSync(process.env.PICORV32_RTL);
  const url = `https://raw.githubusercontent.com/YosysHQ/picorv32/${commit}/picorv32.v`;
  const response = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`PicoRV32 download failed with HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

const coreSource = await readCore();
if (createHash('sha256').update(coreSource).digest('hex') !== expectedHash) {
  throw new Error('PicoRV32 source does not match the pinned revision');
}

const build = mkdtempSync(join(tmpdir(), 'storage-tile-'));
const core = join(build, 'picorv32.v');
const binary = join(build, 'tile.vvp');
const bootImage = join(build, 'boot-pages.bin');
const records = join(build, 'records.bin');
const synthesisSource = join(build, 'storage_tile.sv');
const synthesisAxi = join(build, 'storage_tile_axi.sv');
const synthesisFilter = join(build, 'dataset_filter.sv');
const synthesisScan = join(build, 'dataset_scan.sv');
try {
  writeFileSync(core, coreSource);
  run('iverilog', ['-g2012', '-s', 'storage_tile_tb', '-o', binary, core, rtl, testbench], build);
  run('vvp', [binary], build);

  const bootPages = Buffer.alloc(8192);
  const program = [0x2000_02b7, 0x0002_a303, 0x02a3_0313, 0x0062_a223, 0x0010_0073];
  program.forEach((word, index) => bootPages.writeUInt32LE(word, 4088 + index * 4));
  writeFileSync(bootImage, bootPages);
  run('iverilog', ['-g2012', '-s', 'storage_tile_axi_tb', '-o', binary, core, rtl, axiRtl, axiTestbench], build);
  run('vvp', [binary], build);
  run('iverilog', ['-g2012', '-s', 'dataset_filter_tb', '-o', binary, filterRtl, filterTestbench], build);
  run('vvp', [binary], build);

  const fixture = values['full-scan'] ? { records: 4194304, matches: 1179648, checksum: 70189056 }
    : { records: 1025, matches: 288, checksum: 164592 };
  run(process.execPath, [benchmark, '--fixture', records, '--records', String(fixture.records), '--runs', '1'], build);
  run('iverilog', ['-g2012', '-s', 'dataset_scan_tb', '-o', binary, filterRtl, scanRtl, scanTestbench], build);
  run('vvp', [binary, ...Object.entries(fixture).map(([name, value]) => `+${name}=${value}`)], build,
    values['full-scan'] ? 360_000 : 120_000);

  if (values.synth) {
    copyFileSync(rtl, synthesisSource);
    copyFileSync(axiRtl, synthesisAxi);
    copyFileSync(filterRtl, synthesisFilter);
    copyFileSync(scanRtl, synthesisScan);
    const yosys = process.env.YOSYS ?? 'yosys';
    run(yosys, ['-Q', '-p', 'read_verilog -sv picorv32.v storage_tile.sv storage_tile_axi.sv; hierarchy -check -top storage_tile_axi; proc; opt; memory -nomap; check -assert; stat'], build);
    run(yosys, ['-Q', '-p', 'read_verilog -sv dataset_filter.sv dataset_scan.sv; synth -top dataset_scan; check -assert; stat'], build);
  }
  if (values['emit-boot-image'] !== undefined) {
    writeFileSync(values['emit-boot-image'], bootPages, { flag: 'wx' });
  }
} finally {
  for (const path of [core, binary, bootImage, records, synthesisSource, synthesisAxi, synthesisFilter, synthesisScan]) {
    if (existsSync(path)) unlinkSync(path);
  }
  rmdirSync(build);
}
