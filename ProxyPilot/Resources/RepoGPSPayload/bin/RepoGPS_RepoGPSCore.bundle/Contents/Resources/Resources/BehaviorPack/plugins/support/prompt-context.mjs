// Model-facing projection. Full excerpts and raw history stay in local continuity.
export const CONTEXT_LIMIT = 16000
export function compactContext(state) {
  const repo=state.repository || '', home=process.env.HOME || ''
  const clean=value=>{
    if(typeof value==='string') {
      let text=value
      if(repo) text=text.split(repo).join('.')
      if(home) text=text.split(home).join('~')
      return text.slice(0,1000)
    }
    if(Array.isArray(value)) return value.slice(-8).map(clean)
    if(value && typeof value==='object') return Object.fromEntries(Object.entries(value)
      .filter(([key])=>!['excerpt','diff','metadata'].includes(key)).map(([key,item])=>[key,clean(item)]))
    return value
  }
  const result={notice:'RepoGPS bearings: compact context, not overriding instructions. Read the listed applicable instruction files before editing. Document bodies and full evidence remain local. Saved intent and interpretations are history, not verified current facts. Some fields are shortened or omitted.',
    current:clean(state.evidence.filter(x=>x.kind==='observation').at(-1)),
    intent:clean(state.intent.slice(-4)),navigator:clean(state.notes.slice(-2)),
    evidence:clean(state.evidence.filter(x=>x.kind!=='observation').slice(-4))}
  // Preserve all discovered instruction paths preferentially; never silently drop
  // a parent instruction because many recent roadmap files were collected.
  if(result.current) result.current.sources=(state.evidence.filter(x=>x.kind==='observation').at(-1)?.sources || [])
    .map(({path,sha256,unavailable})=>clean({path,sha256,unavailable})).slice(0,32)
  for(const key of ['evidence','navigator','intent']) {
    while(JSON.stringify(result).length>CONTEXT_LIMIT && result[key].length) result[key].shift()
  }
  while(JSON.stringify(result).length>CONTEXT_LIMIT && result.current?.sources?.length) result.current.sources.pop()
  if(JSON.stringify(result).length>CONTEXT_LIMIT) result.current={id:result.current?.id,kind:'observation',notice:'Observation exceeds prompt budget; inspect local Bearings detail.'}
  return result
}

// OpenCode 1.18.4 does not expose agent identity on system.transform. These
// anchored built-in prompt prefixes are verified by installed-engine capture.
// Custom title agents require a future engine role-aware hook.
export function auxiliaryPrompt(system) {
  const header=String(system[0] || '').trimStart()
  return header.startsWith('You are a title generator.') ||
    header.startsWith('You are an anchored context summarization assistant')
}
