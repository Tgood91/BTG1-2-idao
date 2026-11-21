// Base mainnet deploy of BushidoGovernanceV1_1 and the BushidoRoomsGauge it owns (build/*.json), mirroring
// script/DeployGovernanceV1_1.s.sol and script/DeployRoomsGauge.s.sol.
// Used by index.html; the wallet only signs and sends, while gas, reads and confirmations go through Base's public RPC.
//
// The WRunes address is required (as in the Foundry script): a freshly deployed WRunes has no supply, so its 4%
// quorum would be 0 and the first wrapper could pass anything.
// New-timelock path (no timelock address entered): TimelockController (2 days, anyone
// executes, this wallet temporary admin) -> BushidoGovernanceV1_1 -> BushidoRoomsGauge (owner: timelock)
// -> PROPOSER to the governor -> CANCELLER to the security multisig -> this wallet renounces timelock admin.
// Existing-timelock path: deploys only the governor and the gauge, and shows the grantRole / revokeRole calls the V1 governance
// must pass (target = the timelock); this wallet cannot change that timelock's roles.
export const RUNES = '0x68E63f682AB383A9132317349125fF7618C96e01';
export const FAUCET_WALLET = '0x4342bBb4FA142f2D5E7Fd02e7cFAc9FaF19B9BdE'; // holds a server key: must never own contracts
export const NAMES = ['WrappedRunesVotes', 'TimelockController', 'BushidoGovernanceV1_1', 'BushidoRoomsGauge'];
export const NEW_TIMELOCK_DELAY = 2n * 24n * 3600n; // 2 days, as in the Foundry script
const ADMIN = '0x0000000000000000000000000000000000000000000000000000000000000000'; // DEFAULT_ADMIN_ROLE
const WRUNES_ABI = ['function name() view returns (string)', 'function symbol() view returns (string)', 'function underlying() view returns (address)', 'function CLOCK_MODE() view returns (string)', 'function decimals() view returns (uint8)'];
const TL_ABI = ['function getMinDelay() view returns (uint256)', 'function hasRole(bytes32,address) view returns (bool)', 'function grantRole(bytes32,address)', 'function revokeRole(bytes32,address)', 'function renounceRole(bytes32,address)'];

let READ = null;
export function setRead(p) { READ = p; }

async function send(ethers, signer, req, log) {
  const from = await signer.getAddress();
  const gas = await READ.estimateGas({ ...req, from }); // a revert stops here, before anything is signed
  const fee = await READ.getFeeData();
  const tx = { ...req, from, gasLimit: (gas * 12n) / 10n + 20000n };
  if (fee.maxFeePerGas) Object.assign(tx, { maxFeePerGas: fee.maxFeePerGas * 2n, maxPriorityFeePerGas: fee.maxPriorityFeePerGas ?? 1n });
  log('  confirm it in your wallet…');
  const hash = await signer.sendUncheckedTransaction(tx);
  log(`  sent ${hash}`);
  let rc = null;
  for (let i = 0; i < 90 && !rc; i++) {
    rc = await READ.getTransactionReceipt(hash).catch(() => null);
    if (!rc) await new Promise((r) => setTimeout(r, 2000));
  }
  if (!rc) throw new Error(`not confirmed after 3 minutes (tx ${hash}); check your wallet's activity`);
  if (rc.status !== 1) throw new Error(`reverted on-chain (tx ${hash})`);
  return rc;
}
const roles = (ethers) => ({ PROPOSER: ethers.id('PROPOSER_ROLE'), CANCELLER: ethers.id('CANCELLER_ROLE'), EXECUTOR: ethers.id('EXECUTOR_ROLE') });
const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const opt = (ethers, v, label) => {
  if (!v) return;
  if (!ethers.isAddress(v) || v === ethers.ZeroAddress) throw new Error(`${label} is not a valid address`);
};

/** Throws with a plain reason if the address is not the real WRunes wrapper of Runes. */
async function checkWRunes(ethers, addr) {
  if ((await READ.getCode(addr)) === '0x') throw new Error('the WRunes address has no contract code on Base');
  const W = new ethers.Contract(addr, WRUNES_ABI, READ);
  const [n, s, u, c, d] = await Promise.all([W.name(), W.symbol(), W.underlying(), W.CLOCK_MODE(), W.decimals()]).catch(() => { throw new Error('the WRunes address is not a WrappedRunesVotes contract'); });
  if (n !== 'Wrapped Runes' || s !== 'WRunes' || !eq(u, RUNES) || c !== 'mode=timestamp') throw new Error(`that token is ${n} / ${s} wrapping ${u} (${c}), not WRunes`);
  if (d !== 18n) throw new Error(`WRunes reports ${d} decimals, expected 18`); // the threshold below is scaled by 18
  return Number(d);
}

/** Checks before anything is signed. Returns the parsed config. Throws with a plain reason. */
export async function preflight(ethers, me, raw) {
  const net = await READ.getNetwork();
  if (net.chainId !== 8453n) throw new Error('the read RPC is not Base mainnet');
  if (eq(me, FAUCET_WALLET)) throw new Error('this is the faucet wallet: its key is on the server, so it must not own governance contracts. Connect another wallet.');
  if ((await READ.getCode(RUNES)) === '0x') throw new Error('Runes has no code on Base: wrong network?');
  const cfg = { wrunes: raw.wrunes, timelock: raw.timelock, multisig: raw.multisig, v1Governor: raw.v1Governor, threshold: raw.threshold || '0' };
  if (!cfg.wrunes) throw new Error('enter the WRunes address (the existing WrappedRunesVotes on Base)');
  opt(ethers, cfg.wrunes, 'the WRunes address');
  opt(ethers, cfg.timelock, 'the timelock address');
  opt(ethers, cfg.multisig, 'the security multisig');
  opt(ethers, cfg.v1Governor, 'the V1 governor address');
  await checkWRunes(ethers, cfg.wrunes);
  if (!/^\d+(\.\d{1,18})?$/.test(cfg.threshold)) throw new Error('the proposal threshold must be a WRunes amount such as 0 or 1000');
  cfg.thresholdWei = ethers.parseUnits(cfg.threshold, 18).toString(); // checkWRunes confirmed 18 decimals
  if (cfg.timelock) {
    if ((await READ.getCode(cfg.timelock)) === '0x') throw new Error('the timelock address has no contract code on Base');
    await new ethers.Contract(cfg.timelock, TL_ABI, READ).getMinDelay().catch(() => { throw new Error('the timelock address is not a TimelockController'); });
    if (cfg.multisig) throw new Error('the security multisig is only used with a new timelock: leave it empty, or clear the timelock address');
  } else {
    if (cfg.v1Governor) throw new Error('the V1 governor is only used with an existing timelock: leave it empty, or enter the timelock address');
    if (cfg.multisig && eq(cfg.multisig, me)) throw new Error('the security multisig must be a different address from this deploying wallet (ideally a Safe)');
  }
  return cfg;
}

/** Step 1: deploy what is needed (each contract skipped if already deployed in this session). */
export async function deploy(ethers, B, signer, st, cfg, log) {
  const me = await signer.getAddress();
  st.WrappedRunesVotes = cfg.wrunes; // never deployed here: see the note at the top
  if (cfg.timelock) st.TimelockController = cfg.timelock;
  const args = {
    TimelockController: () => [NEW_TIMELOCK_DELAY, [], [ethers.ZeroAddress], me], // anyone executes; deployer admin until step 2
    BushidoGovernanceV1_1: () => [st.WrappedRunesVotes, st.TimelockController, BigInt(cfg.thresholdWei)],
    BushidoRoomsGauge: () => [st.WrappedRunesVotes, RUNES, st.TimelockController], // rooms are added by governance
  };
  for (const name of NAMES) {
    if (st[name]) { log(`${name} at ${st[name]}`); continue; }
    log(`Deploying ${name}…`);
    const req = await new ethers.ContractFactory(B[name].abi, B[name].bytecode).getDeployTransaction(...args[name]());
    st[name] = (await send(ethers, signer, { data: req.data }, log)).contractAddress;
    log(`${name}: ${st[name]}`);
  }
}

/** Step 2 (new timelock only): governor proposes, multisig cancels, then this wallet gives up timelock admin. */
export async function wireTimelock(ethers, signer, st, cfg, log) {
  const me = await signer.getAddress(), R = roles(ethers);
  const T = new ethers.Contract(st.TimelockController, TL_ABI, READ);
  const grant = async (role, who, label) => {
    if (await T.hasRole(role, who)) return;
    log(`Granting the timelock ${label} role to ${who}…`);
    await send(ethers, signer, { to: st.TimelockController, data: T.interface.encodeFunctionData('grantRole', [role, who]) }, log);
  };
  await grant(R.PROPOSER, st.BushidoGovernanceV1_1, 'proposer');
  if (cfg.multisig) await grant(R.CANCELLER, cfg.multisig, 'canceller');
  if (!(await T.hasRole(R.PROPOSER, st.BushidoGovernanceV1_1))) throw new Error('the governor does not hold the proposer role: stopping before this wallet gives up admin');
  if (await T.hasRole(ADMIN, me)) {
    log('Giving up this wallet’s timelock admin role (only governance can change the timelock after this)…');
    await send(ethers, signer, { to: st.TimelockController, data: T.interface.encodeFunctionData('renounceRole', [ADMIN, me]) }, log);
  }
}

/** Existing timelock only: the calls the V1 governance must pass (target = timelock, value 0). */
export function migrationCalls(ethers, st, cfg) {
  const R = roles(ethers), I = new ethers.Interface(TL_ABI), g = st.BushidoGovernanceV1_1;
  const rows = [
    ['grantRole(PROPOSER_ROLE, V1.1)', I.encodeFunctionData('grantRole', [R.PROPOSER, g])],
    ['grantRole(CANCELLER_ROLE, V1.1)', I.encodeFunctionData('grantRole', [R.CANCELLER, g])],
  ];
  if (cfg.v1Governor) {
    rows.push(['revokeRole(PROPOSER_ROLE, V1)', I.encodeFunctionData('revokeRole', [R.PROPOSER, cfg.v1Governor])]);
    rows.push(['revokeRole(CANCELLER_ROLE, V1)', I.encodeFunctionData('revokeRole', [R.CANCELLER, cfg.v1Governor])]);
  }
  return rows;
}

/** Read everything back. Returns [label, ok, detail] rows. */
export async function verify(ethers, B, st, cfg, me) {
  const R = roles(ethers);
  const G = new ethers.Contract(st.BushidoGovernanceV1_1, B.BushidoGovernanceV1_1.abi, READ);
  const T = new ethers.Contract(st.TimelockController, TL_ABI, READ);
  const rows = [];
  const add = (label, ok, detail) => rows.push([label, !!ok, detail]);
  await checkWRunes(ethers, st.WrappedRunesVotes).then(() => add('Token', true, `WRunes at ${st.WrappedRunesVotes}, wraps Runes, timestamp clock`), (e) => add('Token', false, e.message));
  const [name, tok, tl] = await Promise.all([G.name(), G.token(), G.timelock()]);
  add('Governor', name === 'BushidoGovernance V1.1' && eq(tok, st.WrappedRunesVotes) && eq(tl, st.TimelockController), `"${name}", token and timelock match`);
  const [d, p, q, th] = await Promise.all([G.votingDelay(), G.votingPeriod(), G.quorumNumerator(), G.proposalThreshold()]);
  add('Settings', d === 86400n && p === 604800n && q === 4n && th === BigInt(cfg.thresholdWei), `delay ${d} s, voting ${p} s, quorum ${q}%, threshold ${ethers.formatUnits(th, 18)} WRunes`);
  const Gg = new ethers.Contract(st.BushidoRoomsGauge, B.BushidoRoomsGauge.abi, READ);
  const [gv, gr, go, ge] = await Promise.all([Gg.votesToken(), Gg.rewardToken(), Gg.owner(), Gg.EPOCH_LENGTH()]);
  add('Rooms gauge', eq(gv, st.WrappedRunesVotes) && eq(gr, RUNES) && eq(go, st.TimelockController) && ge === 604800n, `votes with WRunes, pays Runes, owned by the timelock, ${ge} s epochs`);
  const delay = await T.getMinDelay();
  if (cfg.timelock) {
    const isProposer = await T.hasRole(R.PROPOSER, st.BushidoGovernanceV1_1);
    add('Timelock roles', isProposer, isProposer ? 'V1.1 is a proposer on the existing timelock' : 'not yet: V1 governance must pass the migration calls below');
  } else {
    add('Timelock delay', delay === NEW_TIMELOCK_DELAY, `${delay} s`);
    add('Timelock roles', (await T.hasRole(R.PROPOSER, st.BushidoGovernanceV1_1)) && (await T.hasRole(R.EXECUTOR, ethers.ZeroAddress)), 'governor proposes, anyone executes');
    if (cfg.multisig) add('Canceller', await T.hasRole(R.CANCELLER, cfg.multisig), `security multisig ${cfg.multisig}`);
    add('Timelock admin', !(await T.hasRole(ADMIN, me)) && (await T.hasRole(ADMIN, st.TimelockController)), 'deploying wallet holds no admin role; only the timelock administers itself');
  }
  return rows;
}
