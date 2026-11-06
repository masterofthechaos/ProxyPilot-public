import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const LIMIT=16000
const bounded=text=>String(text).length>LIMIT ? String(text).slice(0,LIMIT)+'\n[Output shortened; select a narrower path.]' : String(text)
function inside(root, relative) {
  const base=fs.realpathSync(root), target=fs.realpathSync(path.resolve(base,relative))
  if(target!==base && !target.startsWith(base+path.sep)) throw Error('Path must remain inside the selected directory')
  return target
}
export function skillLibrary(root) {
  if(!root || !fs.existsSync(root))return []
  return fs.readdirSync(root,{withFileTypes:true}).filter(item=>item.isDirectory() && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(item.name)).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(item=>{
    try {
      const file=inside(root,item.name+'/SKILL.md'), stat=fs.statSync(file)
      if(stat.size>1024*1024)return []
      const text=fs.readFileSync(file,'utf8'), front=text.match(/^---\r?\n([\s\S]*?)\r?\n---/)
      const description=(front?.[1].match(/^description:\s*(.*)$/m)?.[1] || '').replace(/^["']|["']$/g,'').slice(0,240)
      return [{name:item.name,description,directory:path.dirname(file)}]
    }catch{return []}
  })
}
export function searchSkills(root,query) {
  const terms=String(query).toLowerCase().split(/\s+/).filter(Boolean), all=skillLibrary(root)
  const matches=all.filter(item=>terms.every(term=>(item.name+' '+item.description).toLowerCase().includes(term)))
  return JSON.stringify({total:matches.length,returned:Math.min(matches.length,10),skills:matches.slice(0,10).map(({name,description})=>({name,description})),notice:'Load the named skill with skill_load. Narrow the search when more results remain.'})
}
export function loadSkill(root,name,resource='SKILL.md') {
  if(!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(name))throw Error('Use an exact skill name from skill_search')
  const skill=skillLibrary(root).find(item=>item.name===name)
  if(!skill)throw Error('Skill not found in the canonical RepoGPS library')
  const file=inside(skill.directory,resource || 'SKILL.md'),stat=fs.statSync(file)
  if(!stat.isFile() || stat.size>1024*1024)throw Error('Resource must be a text file below 1 MiB; inspect the named asset with an appropriate local tool')
  const text=fs.readFileSync(file,'utf8')
  if(text.includes('\u0000'))throw Error('Binary skill asset: inspect it with an appropriate local tool at '+file)
  return JSON.stringify({name,path:file,base_directory:skill.directory,content:text.slice(0,64000),truncated:text.length>64000,notice:'Resolve relative resources against base_directory. The canonical skill and all assets remain intact; skill_load accepts a relative resource path.'})
}
export function explicitSkills(root,text) {
  const names=new Set([...String(text).matchAll(/(?:^|\s)\$([a-z0-9]+(?:-[a-z0-9]+)*)(?=\b)/g)].map(m=>m[1]))
  return skillLibrary(root).filter(item=>names.has(item.name)).map(item=>loadSkill(root,item.name))
}
export function repositorySearch(repo,query,relative='.') {
  const target=inside(repo,relative || '.')
  try {
    return bounded(execFileSync('rg',['--line-number','--fixed-strings','--max-count','20','--max-columns','240','--',query,target],{encoding:'utf8',timeout:5000,maxBuffer:128*1024,stdio:['ignore','pipe','pipe']})) || 'No matches in the selected path.'
  }catch(error){
    if(error.status===1)return 'No matches in the selected path.'
    if(error.code!=='ENOENT')throw Error('Search unavailable or exceeded the bounded output. Select a narrower exact path.')
    // Stock machines need no ripgrep installation for the exact-path helper.
    const pending=[target], rows=[];let entries=0,bytes=0,truncated=false
    while(pending.length && entries<1000 && bytes<8*1024*1024 && rows.join('\n').length<LIMIT) {
      const file=pending.shift();entries++
      const stat=fs.lstatSync(file)
      if(stat.isSymbolicLink())continue
      if(stat.isDirectory()) {for(const item of fs.readdirSync(file).sort())if(!['.git','.build','node_modules'].includes(item))pending.push(path.join(file,item));continue}
      if(!stat.isFile() || stat.size>1024*1024)continue
      bytes+=stat.size
      const text=fs.readFileSync(file,'utf8');if(text.includes('\u0000'))continue
      let matches=0
      for(const [index,line] of text.split(/\r?\n/).entries())if(line.includes(query)) {rows.push(path.relative(repo,file)+':'+(index+1)+':'+line.slice(0,240));if(++matches>=20)break}
    }
    truncated=pending.length>0
    return bounded(rows.join('\n') || 'No matches in the scanned files.')+'\n[Portable search; '+entries+' entries examined.'+(truncated?' Limit reached; narrow the path.':'')+']'
  }
}
export function gitPreflight(repo) {
  const commands=[['status','--short','--branch'],['diff','--no-ext-diff','--no-textconv','--stat'],['diff','--no-ext-diff','--no-textconv','--cached','--stat'],['log','-1','--format=%h %s']]
  return commands.map(args=>{
    try{return '$ git '+args.join(' ')+'\n'+bounded(execFileSync('git',['--no-optional-locks','-c','core.fsmonitor=false','-C',repo,...args],{encoding:'utf8',timeout:5000,maxBuffer:128*1024,stdio:['ignore','pipe','pipe']}))}
    catch{return '$ git '+args.join(' ')+'\nUnavailable.'}
  }).join('\n')+'\nRead-only preflight. Preserve unrelated changes; this does not authorize checkout, reset, clean, commit, push, or merge.'
}
export function deterministicTitle(text) {
  return String(text).replace(/\s+/g,' ').trim().slice(0,80) || 'RepoGPS session'
}
