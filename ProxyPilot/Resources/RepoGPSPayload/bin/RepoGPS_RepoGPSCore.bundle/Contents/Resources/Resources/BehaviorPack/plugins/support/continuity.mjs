import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { compactContext } from './prompt-context.mjs'

export const bounded = value => String(value ?? '').slice(0, 6000)
export const readJSON = file => { try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return null } }
export function atomicJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value) + '\n', { mode: 0o600 })
  fs.renameSync(tmp, file)
}
function git(repo, args) {
  try { return execFileSync('git', ['-C', repo, ...args], {encoding:'utf8', timeout:3000, maxBuffer:64000, stdio:['ignore','pipe','ignore']}).trim() }
  catch { return null }
}
export function observe(repo) {
  const instructions = []
  let dir = repo
  for (let depth = 0; depth < 20; depth++) {
    const file = path.join(dir, 'AGENTS.md')
    if (fs.existsSync(file)) instructions.unshift(file)
    const parent = path.dirname(dir); if (parent === dir) break; dir = parent
  }
  const docs = ['CLAUDE.md','README.md','docs/DEVLOG-EXPRESS.md','docs/STATE.md','docs/COURSE.md']
    .map(x => path.join(repo,x)).filter(x => fs.existsSync(x))
  for (const relative of ['docs/waypoints','docs/session-punch-cards/punch-outs','docs/Roadmaps/active']) {
    const directory=path.join(repo,relative)
    try {
      const recent=fs.readdirSync(directory).filter(name=>name.endsWith('.md') && name!=='README.md').sort().slice(-3)
      docs.push(...recent.map(name=>path.join(directory,name)))
    } catch {}
  }
  const sources = [...instructions, ...docs].map(file => {
    try {
      const stat = fs.statSync(file)
      if (!stat.isFile() || stat.size > 1048576) return {path:file, unavailable:'not a bounded text file'}
      const text = fs.readFileSync(file,'utf8')
      return {path:file, sha256:crypto.createHash('sha256').update(text).digest('hex'), excerpt:bounded(text)}
    } catch { return {path:file, unavailable:'unreadable'} }
  })
  return {kind:'observation', observed_at:new Date().toISOString(), repository:repo,
    git_root:git(repo,['rev-parse','--path-format=absolute','--git-common-dir']), worktree:git(repo,['rev-parse','--show-toplevel']),
    branch:git(repo,['branch','--show-current']), head:git(repo,['rev-parse','HEAD']),
    status:git(repo,['status','--short']), diff:git(repo,['diff','--stat']), sources}
}
export function validateNote(value, evidence) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('Expected a structured Navigator note')
  const allowed = new Set(['understanding','rationale','questions','next_action','references'])
  if (Object.keys(value).some(k => !allowed.has(k))) throw Error('Navigator cannot declare facts, verification, or completion')
  for (const key of ['understanding','rationale','next_action']) {
    if (typeof value[key] !== 'string' || value[key].length > 4000) throw Error(`Invalid ${key}`)
  }
  if (!Array.isArray(value.questions) || value.questions.length > 10 || value.questions.some(x => typeof x !== 'string' || x.length > 1000)) throw Error('Invalid questions')
  const ids = new Set(evidence.map(x => x.id))
  if (!Array.isArray(value.references) || value.references.length > 32 || value.references.some(x => typeof x !== 'string' || !ids.has(x))) throw Error('Unknown evidence reference')
  return {...value, kind:'interpretation', attributed_to:'navigator', validated_references:true}
}
export class Continuity {
  constructor(root, repo, logicalID, harness='opencode') {
    this.root = path.resolve(root)
    this.file = path.join(this.root,'state.json')
    this.repository = fs.realpathSync(repo)
    this.logicalID = String(logicalID).toLowerCase()
    this.executable = process.env.RGPS_EXECUTABLE
    if (!this.executable) throw Error('RepoGPS continuity requires RGPS_EXECUTABLE for shared locked mutations')
    const repogpsRoot=path.dirname(path.dirname(this.root))
    if (path.basename(this.root)!==this.logicalID || path.basename(path.dirname(this.root))!=='continuity' || path.basename(repogpsRoot)!=='.repogps') {
      throw Error('Continuity directory must belong to the RepoGPS logical session')
    }
    this.home=path.dirname(repogpsRoot)
    this.mutate('enter',{harness,session_id:process.env.RGPS_HARNESS_SESSION_ID || null,
      known_new:process.env.RGPS_THREAD_NEW==='1',observation:observe(this.repository)})
  }
  mutate(operation, payload={}) {
    fs.mkdirSync(this.root,{recursive:true,mode:0o700})
    // Snapshots include full local evidence. Send stdout to a private file instead
    // of imposing a child-process buffer cap on this existing durable data.
    const output=path.join(this.root,`.mutation-${process.pid}-${crypto.randomUUID()}.json`)
    const fd=fs.openSync(output,'wx',0o600)
    try {
      execFileSync(this.executable,['continuity','mutate','--session-id',this.logicalID,'--json'],{
        input:JSON.stringify({operation,repository:this.repository,...payload}),
        env:{...process.env,RGPS_HOME:this.home},stdio:['pipe',fd,'pipe']
      })
      const result=JSON.parse(fs.readFileSync(output,'utf8'))
      this.state=result.state
      return result.record
    } finally {fs.closeSync(fd);fs.rmSync(output,{force:true})}
  }
  bind(harness,sessionID) { this.mutate('bind',{harness,session_id:sessionID || null}) }
  record(collection, payload) { return this.mutate('record',{collection,payload}) }
  setNavigator(patch,replace=false) { this.mutate('navigator',{patch,replace}) }
  recordUsage(receipt) { this.mutate('usage',{receipt}) }
  refresh(reason) { return this.record('evidence',{...observe(this.repository),reason}) }
  briefing() { return JSON.stringify(compactContext(this.state)) }
}

// One inference at a time; pending changes coalesce. Superseded receipts are kept.
export class NavigatorQueue {
  constructor(call, accept, receipt, unavailable) { Object.assign(this,{call,accept,receipt,unavailable}); this.pending=null; this.inflight=false; this.generation=0 }
  update(input) {
    this.pending = {input, generation:++this.generation}
    if (!this.inflight) this.drain()
  }
  async drain() {
    if (!this.pending) return
    const job=this.pending; this.pending=null; this.inflight=true
    try {
      const response = await this.call(job.input)
      this.receipt(response, job.generation !== this.generation)
      if (job.generation === this.generation) this.accept(response, job.input)
    } catch(error) { if (job.generation === this.generation) this.unavailable(String(error)) }
    finally { this.inflight=false; if(this.pending) this.drain() }
  }
}

export const harnessName = value => ({opencode:'OpenCode','claude-code':'Claude Code',ori:'Ori'}[value] || 'Unknown harness')
export function provenanceBadge(state) {
  const origin=state?.thread_provenance?.origin
  if(!origin?.harness) {
    const current=state?.thread_provenance?.current?.harness
    return current ? `${harnessName(current)} · origin unknown` : 'Origin unknown'
  }
  const name=harnessName(origin.harness)
  return origin.via_repogps===true ? `RepoGPS · ${name}` : origin.via_repogps===false ? name : `${name} · origin unknown`
}
