import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  'model-b': { type: 'string' },
  gpus: { type: 'string', default: '1' },
  'hbm-gb': { type: 'string', default: '288' },
  'storage-tb': { type: 'string', default: '1' },
  'dataset-gb': { type: 'string', default: '0' },
  'checkpoint-copies': { type: 'string', default: '1' },
  'reserve-percent': { type: 'string', default: '20' },
} });

function numberOption(name, valid) {
  const value = Number(values[name]);
  if (!values[name]?.trim() || !Number.isFinite(value) || !valid(value)) {
    throw new Error(`Invalid --${name}: ${values[name]}`);
  }
  return value;
}

const positive = value => value > 0;
const modelSizes = values['model-b'] === undefined ? [7, 70, 405] : [numberOption('model-b', positive)];
const gpus = numberOption('gpus', value => Number.isSafeInteger(value) && value > 0);
const hbm = numberOption('hbm-gb', positive);
const storage = numberOption('storage-tb', positive) * 1000;
const dataset = numberOption('dataset-gb', value => value >= 0);
const copies = numberOption('checkpoint-copies', value => Number.isSafeInteger(value) && value > 0);
const reserve = numberOption('reserve-percent', value => value >= 0 && value < 100);

// BF16 weights and gradients, plus FP32 master weights and two Adam moments.
const bytesPerParam = { weights: 2, gradients: 2, master: 4, moments: 8 };
const checkpointBytesPerParam = bytesPerParam.weights + bytesPerParam.master + bytesPerParam.moments;
const stateBytesPerParam = checkpointBytesPerParam + bytesPerParam.gradients;
const budgetPerGpu = hbm * (100 - reserve) / 100;
const format = value => value.toLocaleString('en-US', { maximumFractionDigits: 2 });

console.log(`Training plan: ${gpus} GPU(s), ${format(hbm)} GB HBM each, ${reserve}% reserved`);
console.log(`Storage: ${format(storage)} GB, ${format(dataset)} GB dataset, ${copies} checkpoint(s)`);
console.log('All capacities use decimal units. GPU minimums assume evenly sharded model state.');
for (const model of modelSizes) {
  const states = model * stateBytesPerParam;
  const checkpoint = model * checkpointBytesPerParam;
  const minimumGpus = Math.ceil(states / budgetPerGpu);
  const storageNeeded = dataset + copies * checkpoint;

  console.log(`\n${format(model)}B parameters`);
  console.log(`  Training state: ${format(states)} GB HBM; budgeted minimum ${format(minimumGpus)} GPU(s)`);
  console.log(`  HBM budget: ${gpus >= minimumGpus ? 'fits' : 'too small'}`);
  console.log(`  One resumable checkpoint: ${format(checkpoint)} GB`);
  console.log(`  Storage requirement: ${format(storageNeeded)} GB; ${storageNeeded <= storage ? 'fits modeled payload' : 'too small'}`);
}
