// The testnet governance test (Monad testnet or Base Sepolia), step by step. Used by index.html (your wallet signs) and by the local dry run.
// Each step reads/writes `st` (saved addresses and the proposal), so the page can resume after a reload.
export const TEST = { wrapAmount: '100000', trade: [1000, 1000, 1000, 1000, 1000] }; // 5 virtues x 10.00 = 5000 points

const PROPOSER = '0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1'; // keccak256("PROPOSER_ROLE")
const CANCELLER = '0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783'; // keccak256("CANCELLER_ROLE")
export const STATES = ['Pending', 'Active', 'Canceled', 'Defeated', 'Succeeded', 'Queued', 'Expired', 'Executed'];

// Reads, gas estimates and confirmations go through a public RPC (setRead); the wallet is only asked to sign and
// send. Some wallet in-app browsers refuse eth_estimateGas / eth_call / receipt lookups, which left the deploy stuck.
let READ = null;
export function setRead(provider) { READ = provider; }
const reader = (signer) => READ || signer.provider;

/** Estimate on the public RPC, have the wallet sign + send (eth_sendTransaction only), wait on the public RPC. */
async function send(ethers, signer, req, log) {
  const rp = reader(signer);
  const from = await signer.getAddress();
  const gas = await rp.estimateGas({ ...req, from });
  const fee = await rp.getFeeData();
  const tx = { ...req, from, gasLimit: (gas * 12n) / 10n + 20000n };
  if (fee.maxFeePerGas) Object.assign(tx, { maxFeePerGas: fee.maxFeePerGas * 2n, maxPriorityFeePerGas: fee.maxPriorityFeePerGas ?? 1n });
  log?.('  confirm it in your wallet…');
  const hash = await signer.sendUncheckedTransaction(tx);
  log?.(`  sent ${hash.slice(0, 14)}…, waiting for the chain`);
  let rc = null;
  for (let i = 0; i < 90 && !rc; i++) { // check the receipt every 2 s for up to 3 minutes
    rc = await rp.getTransactionReceipt(hash).catch(() => null);
    if (!rc) await new Promise((r) => setTimeout(r, 2000));
  }
  if (!rc) throw new Error(`not confirmed after 3 minutes (tx ${hash}); check your wallet's activity`);
  if (rc.status !== 1) throw new Error(`reverted on-chain (tx ${hash})`);
  return rc;
}
const callTx = (ethers, C, name, to, fn, args) => ({ to, data: new ethers.Interface(C[name].abi).encodeFunctionData(fn, args) });

export function attach(ethers, C, st, runner) {
  const at = (name, key) => (st[key] ? new ethers.Contract(st[key], C[name].abi, runner) : null);
  return {
    runes: at('MockRunes', 'runes'), wrap: at('WrappedRunesVotesTest', 'wrap'), registry: at('VirtueAuditRegistry', 'registry'),
    timelock: at('TimelockController', 'timelock'), gov: at('MyGovernanceTest', 'gov'),
  };
}

/** Step 1: deploy the five contracts and give the governor the timelock's proposer + canceller roles. */
export async function deployAll(ethers, C, signer, st, log) {
  const me = await signer.getAddress();
  const deploy = async (name, args, key) => {
    if (st[key]) return log(`${name} already at ${st[key]}`);
    log(`Deploying ${name}…`);
    const req = await new ethers.ContractFactory(C[name].abi, C[name].bytecode).getDeployTransaction(...args);
    const rc = await send(ethers, signer, { data: req.data }, log);
    st[key] = rc.contractAddress;
    log(`${name}: ${st[key]}`);
  };
  await deploy('MockRunes', [], 'runes');
  await deploy('WrappedRunesVotesTest', [st.runes], 'wrap');
  await deploy('VirtueAuditRegistry', [me], 'registry');
  // 60 s timelock delay; no proposers yet; anyone may execute; the deployer is admin (test only).
  await deploy('TimelockController', [60, [], [ethers.ZeroAddress], me], 'timelock');
  await deploy('MyGovernanceTest', [st.wrap, st.timelock, st.registry], 'gov');
  const { timelock } = attach(ethers, C, st, reader(signer));
  for (const [role, label] of [[PROPOSER, 'proposer'], [CANCELLER, 'canceller']]) {
    if (await timelock.hasRole(role, st.gov)) continue;
    log(`Giving the governor the timelock ${label} role…`);
    await send(ethers, signer, callTx(ethers, C, 'TimelockController', st.timelock, 'grantRole', [role, st.gov]), log);
  }
  st.deployed = true;
}

/** Step 2: wrap test Runes, delegate to self, record one scored trade. Then report token votes vs governance votes. */
export async function wrapDelegateScore(ethers, C, signer, st, log) {
  const me = await signer.getAddress();
  const { wrap, registry } = attach(ethers, C, st, reader(signer));
  const amt = ethers.parseUnits(TEST.wrapAmount, 18);
  if ((await wrap.balanceOf(me)) < amt) {
    log(`Approving ${TEST.wrapAmount} tRUNES…`);
    await send(ethers, signer, callTx(ethers, C, 'MockRunes', st.runes, 'approve', [st.wrap, amt]), log);
    log('Wrapping into TWRunes…');
    await send(ethers, signer, callTx(ethers, C, 'WrappedRunesVotesTest', st.wrap, 'depositFor', [me, amt]), log);
  }
  if ((await wrap.delegates(me)) !== me) {
    log('Delegating votes to yourself…');
    await send(ethers, signer, callTx(ethers, C, 'WrappedRunesVotesTest', st.wrap, 'delegate', [me]), log);
  }
  if ((await registry.getTradeCount(me)) === 0n) {
    log('Recording one scored trade (5 virtues x 10.00 = 5000 points, +0.5% vote bonus)…');
    const [gi, yu, jin, rei, makoto] = TEST.trade;
    const args = [me, st.runes, st.wrap, amt, amt, gi, yu, jin, rei, makoto, ethers.id('test-trade')];
    await send(ethers, signer, callTx(ethers, C, 'VirtueAuditRegistry', st.registry, 'recordTrade', args), log);
  }
  st.scored = true;
}

/** Votes check: governance votes must equal token votes x (1 + bonus). Needs a moment after step 2 (past timepoint). */
export async function checkVotes(ethers, C, runner, st, me, log) {
  const { wrap, gov, registry } = attach(ethers, C, st, runner);
  const t = (await wrap.clock()) - 1n;
  const base = await wrap.getPastVotes(me, t);
  const withBonus = await gov.getVotes(me, t);
  const s = await registry.getBushidoVirtueScore(me);
  const total = s.reduce((a, b) => a + b, 0n);
  let bp = total / 100n; if (bp > 10000n) bp = 10000n;
  const expected = base + (base * bp) / 10000n;
  const f = (x) => ethers.formatUnits(x, 18);
  log(`Token votes ${f(base)} · virtue points ${total} (+${Number(bp) / 100}%) · governance votes ${f(withBonus)} (expected ${f(expected)})`);
  if (base === 0n) throw new Error('No token votes yet: wait a few seconds after delegating, then check again.');
  if (withBonus !== expected) throw new Error('Governance votes do not match token votes plus the virtue bonus.');
  return { base, withBonus };
}

/** The test proposal: the timelock asks MockRunes to mint 1 tRUNES to the timelock itself (harmless, easy to check). */
export function proposal(ethers, C, st) {
  const iface = new ethers.Interface(C.MockRunes.abi);
  const description = `BTG test proposal ${st.proposalNonce}`;
  return { targets: [st.runes], values: [0n], calldatas: [iface.encodeFunctionData('mint', [st.timelock, ethers.parseUnits('1', 18)])], description, descHash: ethers.id(description) };
}

export async function propose(ethers, C, signer, st, log) {
  const { gov } = attach(ethers, C, st, reader(signer));
  st.proposalNonce ||= String(Date.now());
  const p = proposal(ethers, C, st);
  const id = (await gov.hashProposal(p.targets, p.values, p.calldatas, p.descHash)).toString();
  log('Submitting the test proposal…');
  await send(ethers, signer, callTx(ethers, C, 'MyGovernanceTest', st.gov, 'propose', [p.targets, p.values, p.calldatas, p.description]), log);
  st.proposalId = id;
  log(`Proposal ${st.proposalId.slice(0, 12)}… submitted. Voting opens in about 60 s.`);
}

export async function stateOf(ethers, C, runner, st) {
  const { gov } = attach(ethers, C, st, runner);
  return STATES[Number(await gov.state(st.proposalId))];
}

export async function voteFor(ethers, C, signer, st, log) {
  const { gov } = attach(ethers, C, st, reader(signer));
  log('Voting For…');
  await send(ethers, signer, callTx(ethers, C, 'MyGovernanceTest', st.gov, 'castVote', [st.proposalId, 1]), log);
  const v = await gov.proposalVotes(st.proposalId);
  log(`Votes For ${ethers.formatUnits(v[1], 18)} · quorum needed ${ethers.formatUnits(await gov.quorum(await gov.proposalSnapshot(st.proposalId)), 18)}. Voting ends in about 5 min.`);
}

export async function queue(ethers, C, signer, st, log) {
  const p = proposal(ethers, C, st);
  log('Queueing in the timelock…');
  await send(ethers, signer, callTx(ethers, C, 'MyGovernanceTest', st.gov, 'queue', [p.targets, p.values, p.calldatas, p.descHash]), log);
  log('Queued. It can be executed after the 60 s timelock delay.');
}

export async function execute(ethers, C, signer, st, log) {
  const { runes } = attach(ethers, C, st, reader(signer));
  const p = proposal(ethers, C, st);
  const before = await runes.balanceOf(st.timelock);
  log('Executing…');
  await send(ethers, signer, callTx(ethers, C, 'MyGovernanceTest', st.gov, 'execute', [p.targets, p.values, p.calldatas, p.descHash]), log);
  const after = await runes.balanceOf(st.timelock);
  log(`Executed. Timelock tRUNES ${ethers.formatUnits(before, 18)} → ${ethers.formatUnits(after, 18)}.`);
  if (after - before !== ethers.parseUnits('1', 18)) throw new Error('The proposal ran but the mint did not land.');
  st.executed = true;
}
