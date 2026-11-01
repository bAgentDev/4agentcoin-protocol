import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeAbiParameters, encodeEventTopics, createPublicClient, custom } from 'viem';
import {
  POOL_ABI, validateAnswer, assertFresh, checkAuthorization, checkConfig,
  askModel, executeApproved, confirmedReward, mineOne, parseCodexOutput, runProcess, readTask, authorizationSession, hasDeveloperMode, readStatus,
} from '../scripts/agent-miner.mjs';

const address = n => `0x${String(n).repeat(40)}`;
const hash = n => `0x${String(n).repeat(64)}`;
const colors = Array.from({ length: 16 }, (_, i) => i % 4);
const task = { seed: hash(1), nonce: 7n, power: 150000000n, edges: [1, 258], gross: 2100000000000000000n };
const now = 1900000000000;
const config = () => ({
  environment: 'local', chainId: 31337, rpcUrl: 'http://127.0.0.1:8545', walletAddress: address(1), poolAddress: address(2), genesisAddress: address(3), tokenAddress: address(4), tokenId: '0',
  deployment: { verified: true, localMocks: true, identityVerifier: address(5), codeHashes: { pool: hash(1), genesis: hash(1), token: hash(1), identityVerifier: hash(1) } },
  model: { provider: 'codex', automationAuthorized: true, timeoutMs: 1000, maxAttempts: 1 },
  authorization: { consentId: 'ba687e2d-dc62-45e7-ab65-ed41c502e233', confirmedByUser: true, mode: 'single', skipRepeatedConfirmations: false, chainId: 31337, poolAddress: address(2), walletAddress: address(1), tokenId: '0', maxTasks: 1, maxDurationSeconds: 600, maxGasWei: '10000000', maxGasPerTaskWei: '10000000', minGrossWei: '100', expiresAt: new Date(now + 600000).toISOString() },
});
const preview = () => ({ requestId: 'request-7', parsedTx: { contractAddress: address(2) }, simulationResult: { simulationCode: '000000000', simulationErrorDetail: null, allowanceChanges: [], authorityChanges: [] }, risks: {}, expiresAt: now + 10000, requireConfirmation: false });
const receipt = () => ({ status: 'success', gasUsed: 100n, effectiveGasPrice: 2n, logs: [{
  address: address(2),
  topics: encodeEventTopics({ abi: POOL_ABI, eventName: 'TaskSolved', args: { tokenId: 0n, staker: address(1) } }),
  data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }], [7n, task.gross, task.gross * 3n / 100n, task.gross * 97n / 100n]),
}] });
function fixture({ stale = false, previewData = preview(), approved = true, receiptData = receipt(), model } = {}) {
  let taskReads = 0;
  const calls = [];
  const client = {
    getBlockNumber: async () => 10n,
    readContract: async ({ functionName }) => {
      if (functionName === 'getTask') { taskReads++; return [task.seed, stale && taskReads > 1 ? 8n : task.nonce, task.power, task.edges]; }
      return { previewReward: [task.gross, task.gross * 3n / 100n, task.gross * 97n / 100n, 0n], miningOpen: true, stakedBy: address(1), isEligible: true, agentIdOf: hash(2), stakeAgentId: hash(2), identityVerifier: address(5) }[functionName];
    },
    estimateGas: async () => 100n, getGasPrice: async () => 2n,
    waitForTransactionReceipt: async () => receiptData,
  };
  const wallet = async (args) => {
    calls.push(args);
    if (args[1] === 'settings') return { devMode: { enabled: true, expiresAt: Math.floor(now / 1000) + 600 } };
    if (args[1] === 'preview') return previewData;
    if (args[1] === 'execute') return { status: 'BROADCASTED', txHash: hash(8) };
    throw new Error('Unexpected wallet operation');
  };
  return { calls, deps: { client, wallet, model: model ?? (async () => validateAnswer(colors, task.edges)), confirm: async () => approved, notify: () => {}, now: () => now, remainingGas: () => 10000000n } };
}

test('checks and encodes only the model-supplied 16-slot assignment', () => {
  assert.equal(validateAnswer(JSON.stringify(colors), task.edges), 0xe4e4e4e4n);
  assert.throws(() => validateAnswer(Array(16).fill(0), task.edges), /violates edge/);
  for (const malformed of ['```json\n[0]\n```', '{}', '[0]', '[1.5]', JSON.stringify(Array(16).fill(4))]) assert.throws(() => validateAnswer(malformed, task.edges));
});

test('task remains valid without a block deadline but nonce, seed and power changes stop it', () => {
  assert.doesNotThrow(() => assertFresh(task, { ...task, blockNumber: 99999999n }, 1n));
  for (const change of [{ nonce: 8n }, { seed: hash(2) }, { power: 151000000n }, { gross: 1n }]) assert.throws(() => assertFresh(task, { ...task, ...change }, 2n));
});

test('production and unverified deployments fail closed', () => {
  assert.doesNotThrow(() => checkConfig(config()));
  for (const change of [{ chainId: 56, environment: 'production' }, { deployment: { ...config().deployment, verified: false } }, { poolAddress: null }]) assert.throws(() => checkConfig({ ...config(), ...change }));
});

test('task/time/gas/reward and pool-scoped authorization are mandatory', () => {
  const c = config();
  assert.doesNotThrow(() => checkAuthorization(c, now));
  for (const change of [{ confirmedByUser: false }, { maxTasks: 0 }, { maxTasks: 2 }, { maxDurationSeconds: 0 }, { maxGasWei: '0' }, { minGrossWei: '0' }, { poolAddress: address(9) }, { tokenId: '1' }, { expiresAt: '2000-01-01' }]) assert.throws(() => checkAuthorization({ ...c, authorization: { ...c.authorization, ...change } }, now));
});

test('reordered or annotated authorization preserves spending; changed scope needs new consent', () => {
  const c = config();
  const saved = { ...authorizationSession(c, null, now), completed: 1, spent: '250', startedAt: now - 10000 };
  const reordered = { ...c, authorization: { note: 'annotation', ...Object.fromEntries(Object.entries(c.authorization).reverse()) } };
  const resumed = authorizationSession(reordered, saved, now);
  assert.equal(resumed.completed, 1); assert.equal(resumed.spent, 250n); assert.equal(resumed.startedAt, now - 10000);
  assert.throws(() => authorizationSession({ ...c, authorization: { ...c.authorization, maxGasWei: '20000000' } }, saved, now), /scope changed/);
  const newConsent = authorizationSession({ ...c, authorization: { ...c.authorization, consentId: 'dd687e2d-dc62-45e7-ab65-ed41c502e233' } }, saved, now);
  assert.equal(newConsent.completed, 0); assert.equal(newConsent.spent, 0n); assert.equal(newConsent.startedAt, now);
});

test('post-receipt task reads bypass viem cached heads on consecutive rounds', async () => {
  let head = 16n;
  const real = createPublicClient({ transport: custom({ request: async ({ method }) => {
    assert.equal(method, 'eth_blockNumber'); return `0x${head.toString(16)}`;
  } }) });
  assert.equal(await real.getBlockNumber(), 16n);
  const f = fixture();
  const client = { ...f.deps.client, getBlockNumber: real.getBlockNumber };
  head = 17n;
  assert.equal((await readTask(client, config())).blockNumber, 17n);
  head = 18n;
  assert.equal((await readTask(client, config())).blockNumber, 18n);
});

test('model is called via stdin, without shell; a failed model never falls back to a solver', async () => {
  let calls = 0;
  const fakeHost = async (binary, args, options) => {
    calls++;
    assert.equal(binary, 'codex');
    assert.ok(args.includes('read-only'));
    assert.ok(args.includes('shell_tool'));
    assert.match(options.input, /conflict pair/);
    return JSON.stringify({ type: 'item.completed', item: { type: 'agent_message', text: JSON.stringify(Array(16).fill(0)) } });
  };
  await assert.rejects(askModel(task, config().model, fakeHost), /violates edge/);
  assert.equal(calls, 1);
  await assert.rejects(askModel(task, config().model, async () => { throw new Error('quota exceeded'); }), /quota exceeded/);
  assert.throws(() => parseCodexOutput(JSON.stringify({ type: 'item.completed', item: { type: 'command_execution', command: 'solver' } })), /tool use/);
  await assert.rejects(askModel(task, { ...config().model, provider: 'other' }, fakeHost), /no solver fallback/);
});

test('subprocess treats prompt metacharacters as inert stdin', async () => {
  const input = '$(echo injected); `echo injected`\n"data"';
  const output = await runProcess(process.execPath, ['-e', 'process.stdin.pipe(process.stdout)'], { input, timeoutMs: 1000 });
  assert.equal(output, input);
});

test('model time budget stops before another host invocation', async () => {
  let calls = 0;
  await assert.rejects(askModel(task, { ...config().model, deadlineAt: Date.now() - 1 }, async () => { calls++; }), /time budget exhausted/);
  assert.equal(calls, 0);
});

test('expired or unapproved preview never executes', async () => {
  let executions = 0;
  const execute = async () => { executions++; };
  await assert.rejects(executeApproved({ preview: preview(), approved: false, execute, now }), /not approved/);
  await assert.rejects(executeApproved({ preview: { ...preview(), expiresAt: now }, approved: true, execute, now }), /expired/);
  assert.equal(executions, 0);
});

test('Developer Mode uses Unix seconds; preview expiry remains milliseconds', () => {
  assert.equal(hasDeveloperMode({ devMode: { enabled: true, expiresAt: Math.floor(now / 1000) + 600 } }, now), true);
  assert.equal(hasDeveloperMode({ devMode: { enabled: true, expiresAt: Math.floor(now / 1000) } }, now), false);
  assert.equal(hasDeveloperMode({ devMode: { enabled: false, expiresAt: Math.floor(now / 1000) + 600 } }, now), false);
});

test('stale task, malformed model and exhausted gas never reach wallet preview', async () => {
  for (const settings of [{ stale: true }, { model: async () => -1n }]) {
    const f = fixture(settings);
    await assert.rejects(mineOne(config(), f.deps));
    assert.equal(f.calls.some(x => x[1] === 'preview'), false);
  }
  const f = fixture(); f.deps.remainingGas = () => 1n;
  await assert.rejects(mineOne(config(), f.deps), /Gas budget/);
  assert.equal(f.calls.some(x => x[1] === 'preview'), false);
});

test('App confirmation, missing approval and expired preview do not execute', async () => {
  for (const settings of [{ approved: false }, { previewData: { ...preview(), expiresAt: now } }, { previewData: { ...preview(), requireConfirmation: true } }, { previewData: { ...preview(), parsedTx: { contractAddress: address(9) } } }, { previewData: { ...preview(), simulationResult: { simulationCode: 'FAILED' } } }, { previewData: { ...preview(), authorityChanges: [{ spender: address(9) }] } }]) {
    const f = fixture(settings);
    await assert.rejects(mineOne(config(), f.deps));
    assert.equal(f.calls.some(x => x[1] === 'execute'), false);
  }
});

test('paused mining or revoked identity cannot hide original pending transaction history', async () => {
  for (const permission of ['miningOpen', 'isEligible']) {
    const f = fixture();
    const priorRead = f.deps.client.readContract;
    f.deps.client.readContract = async args => args.functionName === permission ? false : priorRead(args);
    f.deps.client.getTransactionReceipt = async ({ hash: tx }) => { assert.equal(tx, hash(8)); return receipt(); };
    const saved = { inFlight: { hash: hash(8), requestId: 'request-7' }, completed: 0 };
    const result = await readStatus(f.deps.client, config(), saved);
    assert.equal(result.previousSession, saved);
    assert.equal(result.originalReceipt.status, 'success');
    assert.equal(result.task, null);
    assert.match(result.taskError, /permission changed/);
    assert.equal(f.calls.length, 0);
  }
});

test('changed identity and higher gas after confirmation stop before execute', async () => {
  for (const changed of ['identity', 'gas']) {
    const f = fixture();
    f.deps.confirm = async () => {
      if (changed === 'gas') f.deps.client.getGasPrice = async () => 999999999n;
      else {
        const previousRead = f.deps.client.readContract;
        f.deps.client.readContract = async args => args.functionName === 'identityVerifier' ? address(9) : previousRead(args);
      }
      return true;
    };
    await assert.rejects(mineOne(config(), f.deps));
    assert.equal(f.calls.some(x => x[1] === 'execute'), false);
  }
});

test('success requires successful receipt and matching on-chain reward event', async () => {
  for (const invalid of [{ status: 'reverted', logs: receipt().logs }, { status: 'success', logs: [] }, { status: 'success', logs: [{ ...receipt().logs[0], address: address(9) }] }]) assert.throws(() => confirmedReward(invalid, config(), 7n));
  const f = fixture();
  const result = await mineOne(config(), f.deps);
  assert.equal(result.state, 'success');
  assert.equal(result.reward.net, task.gross * 97n / 100n);
  assert.equal(result.gasWei, 200n);
  assert.equal(f.calls.filter(x => x[1] === 'execute').length, 1);
});

test('broadcast timeout remains pending and never repeats execute', async () => {
  const f = fixture();
  f.deps.client.waitForTransactionReceipt = async () => { throw new Error('timeout'); };
  const result = await mineOne(config(), f.deps);
  assert.equal(result.state, 'pending');
  assert.equal(result.hash, hash(8));
  assert.equal(f.calls.filter(x => x[1] === 'execute').length, 1);
});
