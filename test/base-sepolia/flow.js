// The Base Sepolia test, step by step. Used by index.html (your wallet signs) and by the local dry run.
// Each step reads/writes `st` (saved addresses and the proposal), so the page can resume after a reload.
export const TEST = { wrapAmount: '100000', trade: [1000, 1000, 1000, 1000, 1000] }; // 5 virtues x 10.00 = 5000 points

const PROPOSER = '0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1'; // keccak256("PROPOSER_ROLE")
const CANCELLER = '0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783'; // keccak256("CANCELLER_ROLE")
export const STATES = ['Pending', 'Active', 'Canceled', 'Defeated', 'Succeeded', 'Queued', 'Expired', 'Executed'];

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
    const f = new ethers.ContractFactory(C[name].abi, C[name].bytecode, signer);
    const c = await f.deploy(...args);
    await c.waitForDeployment();
    st[key] = await c.getAddress();
    log(`${name}: ${st[key]}`);
  };
  await deploy('MockRunes', [], 'runes');
  await deploy('WrappedRunesVotesTest', [st.runes], 'wrap');
  await deploy('VirtueAuditRegistry', [me], 'registry');
  // 60 s timelock delay; no proposers yet; anyone may execute; the deployer is admin (test only).
  await deploy('TimelockController', [60, [], [ethers.ZeroAddress], me], 'timelock');
  await deploy('MyGovernanceTest', [st.wrap, st.timelock, st.registry], 'gov');
  const { timelock } = attach(ethers, C, st, signer);
  for (const [role, label] of [[PROPOSER, 'proposer'], [CANCELLER, 'canceller']]) {
    if (await timelock.hasRole(role, st.gov)) continue;
    log(`Giving the governor the timelock ${label} role…`);
    await (await timelock.grantRole(role, st.gov)).wait();
  }
  st.deployed = true;
}

/** Step 2: wrap test Runes, delegate to self, record one scored trade. Then report token votes vs governance votes. */
export async function wrapDelegateScore(ethers, C, signer, st, log) {
  const me = await signer.getAddress();
  const { runes, wrap, registry } = attach(ethers, C, st, signer);
  const amt = ethers.parseUnits(TEST.wrapAmount, 18);
  if ((await wrap.balanceOf(me)) < amt) {
    log(`Approving ${TEST.wrapAmount} tRUNES…`);
    await (await runes.approve(st.wrap, amt)).wait();
    log('Wrapping into wtRUNES…');
    await (await wrap.depositFor(me, amt)).wait();
  }
  if ((await wrap.delegates(me)) !== me) {
    log('Delegating votes to yourself…');
    await (await wrap.delegate(me)).wait();
  }
  if ((await registry.getTradeCount(me)) === 0n) {
    log('Recording one scored trade (5 virtues x 10.00 = 5000 points, +0.5% vote bonus)…');
    const [gi, yu, jin, rei, makoto] = TEST.trade;
    await (await registry.recordTrade(me, st.runes, st.wrap, amt, amt, gi, yu, jin, rei, makoto, ethers.id('test-trade'))).wait();
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
  const { gov } = attach(ethers, C, st, signer);
  st.proposalNonce ||= String(Date.now());
  const p = proposal(ethers, C, st);
  st.proposalId = (await gov.hashProposal(p.targets, p.values, p.calldatas, p.descHash)).toString();
  log('Submitting the test proposal…');
  await (await gov.propose(p.targets, p.values, p.calldatas, p.description)).wait();
  log(`Proposal ${st.proposalId.slice(0, 12)}… submitted. Voting opens in about 60 s.`);
}

export async function stateOf(ethers, C, runner, st) {
  const { gov } = attach(ethers, C, st, runner);
  return STATES[Number(await gov.state(st.proposalId))];
}

export async function voteFor(ethers, C, signer, st, log) {
  const { gov } = attach(ethers, C, st, signer);
  log('Voting For…');
  await (await gov.castVote(st.proposalId, 1)).wait();
  const v = await gov.proposalVotes(st.proposalId);
  log(`Votes For ${ethers.formatUnits(v[1], 18)} · quorum needed ${ethers.formatUnits(await gov.quorum(await gov.proposalSnapshot(st.proposalId)), 18)}. Voting ends in about 5 min.`);
}

export async function queue(ethers, C, signer, st, log) {
  const { gov } = attach(ethers, C, st, signer);
  const p = proposal(ethers, C, st);
  log('Queueing in the timelock…');
  await (await gov.queue(p.targets, p.values, p.calldatas, p.descHash)).wait();
  log('Queued. It can be executed after the 60 s timelock delay.');
}

export async function execute(ethers, C, signer, st, log) {
  const { gov, runes } = attach(ethers, C, st, signer);
  const p = proposal(ethers, C, st);
  const before = await runes.balanceOf(st.timelock);
  log('Executing…');
  await (await gov.execute(p.targets, p.values, p.calldatas, p.descHash)).wait();
  const after = await runes.balanceOf(st.timelock);
  log(`Executed. Timelock tRUNES ${ethers.formatUnits(before, 18)} → ${ethers.formatUnits(after, 18)}.`);
  if (after - before !== ethers.parseUnits('1', 18)) throw new Error('The proposal ran but the mint did not land.');
  st.executed = true;
}
