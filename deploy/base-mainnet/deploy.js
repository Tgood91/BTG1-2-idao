// Base mainnet deploy of the real BTG governance contracts (build/*.json). Used by index.html; the wallet only
// signs and sends, while gas, reads and confirmations go through Base's public RPC.
export const RUNES = '0x68E63f682AB383A9132317349125fF7618C96e01';
export const FAUCET_WALLET = '0x4342bBb4FA142f2D5E7Fd02e7cFAc9FaF19B9BdE'; // holds a server key: must never own contracts
export const NAMES = ['WrappedRunesVotes', 'VirtueAuditRegistry', 'TimelockController', 'MyGovernance'];
const ADMIN = '0x0000000000000000000000000000000000000000000000000000000000000000'; // DEFAULT_ADMIN_ROLE

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
const call = (ethers, B, name, to, fn, args) => ({ to, data: new ethers.Interface(B[name].abi).encodeFunctionData(fn, args) });
const roles = (ethers) => ({ PROPOSER: ethers.id('PROPOSER_ROLE'), CANCELLER: ethers.id('CANCELLER_ROLE'), EXECUTOR: ethers.id('EXECUTOR_ROLE'), RECORDER: ethers.id('RECORDER_ROLE') });

/** Checks before anything is signed. Throws with a plain reason. */
export async function preflight(ethers, me, cfg) {
  const net = await READ.getNetwork();
  if (net.chainId !== 8453n) throw new Error('the read RPC is not Base mainnet');
  if (me.toLowerCase() === FAUCET_WALLET.toLowerCase()) throw new Error('this is the faucet wallet: its key is on the server, so it must not own governance contracts. Connect another wallet.');
  if ((await READ.getCode(RUNES)) === '0x') throw new Error('Runes has no code on Base: wrong network?');
  if (!ethers.isAddress(cfg.admin) || cfg.admin === ethers.ZeroAddress) throw new Error('enter the address that will own the virtue registry (your Safe)');
  if (cfg.admin.toLowerCase() === me.toLowerCase()) throw new Error('the registry owner must be a different address from this deploying wallet (ideally a Safe)');
  if (cfg.recorder && !ethers.isAddress(cfg.recorder)) throw new Error('the recorder address is not valid');
  if (!(cfg.delayHours >= 1 && cfg.delayHours <= 24 * 30)) throw new Error('the timelock delay must be between 1 hour and 30 days');
}

/** Step 1: deploy the four contracts (each one skipped if already deployed in this session). */
export async function deploy(ethers, B, signer, st, cfg, log) {
  const me = await signer.getAddress();
  const args = {
    WrappedRunesVotes: () => [],
    VirtueAuditRegistry: () => [me], // handed to cfg.admin in step 3
    TimelockController: () => [BigInt(Math.round(cfg.delayHours * 3600)), [], [ethers.ZeroAddress], me], // deployer admin until step 2
    MyGovernance: () => [st.WrappedRunesVotes, st.TimelockController, st.VirtueAuditRegistry],
  };
  for (const name of NAMES) {
    if (st[name]) { log(`${name} already at ${st[name]}`); continue; }
    log(`Deploying ${name}…`);
    const req = await new ethers.ContractFactory(B[name].abi, B[name].bytecode).getDeployTransaction(...args[name]());
    st[name] = (await send(ethers, signer, { data: req.data }, log)).contractAddress;
    log(`${name}: ${st[name]}`);
  }
}

/** Step 2: the governor proposes and cancels through the timelock; then the deployer gives up timelock admin. */
export async function wireTimelock(ethers, B, signer, st, log) {
  const me = await signer.getAddress(), R = roles(ethers);
  const T = new ethers.Contract(st.TimelockController, B.TimelockController.abi, READ);
  for (const [role, label] of [[R.PROPOSER, 'proposer'], [R.CANCELLER, 'canceller']]) {
    if (await T.hasRole(role, st.MyGovernance)) continue;
    log(`Giving MyGovernance the timelock ${label} role…`);
    await send(ethers, signer, call(ethers, B, 'TimelockController', st.TimelockController, 'grantRole', [role, st.MyGovernance]), log);
  }
  if (await T.hasRole(ADMIN, me)) {
    log('Giving up the deploying wallet’s timelock admin role (only governance can change the timelock after this)…');
    await send(ethers, signer, call(ethers, B, 'TimelockController', st.TimelockController, 'renounceRole', [ADMIN, me]), log);
  }
}

/** Step 3: the registry goes to its owner (Safe) and recorder; the deployer keeps nothing. */
export async function handOffRegistry(ethers, B, signer, st, cfg, log) {
  const me = await signer.getAddress(), R = roles(ethers);
  const V = new ethers.Contract(st.VirtueAuditRegistry, B.VirtueAuditRegistry.abi, READ);
  const grant = async (role, who, label) => {
    if (await V.hasRole(role, who)) return;
    log(`Granting ${label} to ${who}…`);
    await send(ethers, signer, call(ethers, B, 'VirtueAuditRegistry', st.VirtueAuditRegistry, 'grantRole', [role, who]), log);
  };
  await grant(ADMIN, cfg.admin, 'registry admin');
  if (cfg.recorder) await grant(R.RECORDER, cfg.recorder, 'recorder');
  if (!(await V.hasRole(ADMIN, cfg.admin))) throw new Error('the new registry admin does not hold the role: stopping before the deploying wallet gives anything up');
  for (const [role, label] of [[R.RECORDER, 'recorder'], [ADMIN, 'admin']]) {
    if (!(await V.hasRole(role, me))) continue;
    log(`Giving up the deploying wallet’s registry ${label} role…`);
    await send(ethers, signer, call(ethers, B, 'VirtueAuditRegistry', st.VirtueAuditRegistry, 'renounceRole', [role, me]), log);
  }
}

/** Read everything back. Returns [label, ok, detail] rows. */
export async function verify(ethers, B, st, cfg, me) {
  const R = roles(ethers);
  const c = (n) => new ethers.Contract(st[n], B[n].abi, READ);
  const W = c('WrappedRunesVotes'), V = c('VirtueAuditRegistry'), T = c('TimelockController'), G = c('MyGovernance');
  const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
  const rows = [];
  const add = (label, ok, detail) => rows.push([label, !!ok, detail]);
  const [wn, ws, wu, wc] = await Promise.all([W.name(), W.symbol(), W.underlying(), W.CLOCK_MODE()]);
  add('Wrapper', wn === 'Wrapped Runes' && ws === 'WRunes' && eq(wu, RUNES) && wc === 'mode=timestamp', `${wn} / ${ws}, wraps ${wu}, ${wc}`);
  add('Governance links', eq(await G.token(), st.WrappedRunesVotes) && eq(await G.timelock(), st.TimelockController) && eq(await G.virtueRegistry(), st.VirtueAuditRegistry), 'token, timelock and registry match');
  const [d, p, q, th] = await Promise.all([G.votingDelay(), G.votingPeriod(), G.quorumNumerator(), G.proposalThreshold()]);
  add('Governance settings', d === 3600n && p === 604800n && q === 4n && th === 0n, `delay ${d} s, voting ${p} s, quorum ${q}%, threshold ${th}`);
  add('Timelock', (await T.hasRole(R.PROPOSER, st.MyGovernance)) && (await T.hasRole(R.CANCELLER, st.MyGovernance)) && (await T.hasRole(R.EXECUTOR, ethers.ZeroAddress)), `governor proposes and cancels, anyone executes, delay ${await T.getMinDelay()} s`);
  add('Timelock admin', !(await T.hasRole(ADMIN, me)), 'deploying wallet holds no timelock admin role');
  add('Registry owner', await V.hasRole(ADMIN, cfg.admin), `admin: ${cfg.admin}`);
  if (cfg.recorder) add('Registry recorder', await V.hasRole(R.RECORDER, cfg.recorder), `recorder: ${cfg.recorder}`);
  add('Deploying wallet', !(await V.hasRole(ADMIN, me)) && !(await V.hasRole(R.RECORDER, me)), 'holds no registry role');
  return rows;
}
