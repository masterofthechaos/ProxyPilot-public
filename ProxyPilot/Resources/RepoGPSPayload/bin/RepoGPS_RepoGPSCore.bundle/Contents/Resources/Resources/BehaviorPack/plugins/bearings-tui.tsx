/** @jsxImportSource @opentui/solid */
import { createSignal } from 'solid-js'
import fs from 'node:fs'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { readJSON } from './support/continuity.mjs'

export default {id:'repogps.bearings.tui',tui:async(api)=>{
  if(!process.env.RGPS_CONTINUITY_DIR) return
  const file=path.join(process.env.RGPS_CONTINUITY_DIR,'state.json')
  const [state,setState]=createSignal(readJSON(file))
  const [route,setRoute]=createSignal(null)
  const [usage,setUsage]=createSignal(null)
  const [collapsed,setCollapsed]=createSignal(api.kv.get('repogps.bearings.collapsed',false))
  const [switching,setSwitching]=createSignal(false)
  const launchRoute=(()=>{try{return JSON.parse(process.env.RGPS_LAUNCH_ROUTE_JSON || 'null')}catch{return null}})()
  const run=(args)=>new Promise((resolve,reject)=>execFile(process.env.RGPS_PROXYPILOT_PATH,args,{timeout:15000,maxBuffer:1024*1024},(error,stdout)=>{
    if(error) return reject(Error('ProxyPilot operation failed; previous route retained unless status reports otherwise.'))
    try {const r=JSON.parse(stdout);if(r.ok===false)throw Error(r.error?.message || 'Operation failed');resolve(r.data ?? r)}catch(e){reject(e)}
  }))
  const refresh=async()=>{
    try {setRoute(await run(['route','status','--json']))}catch{}
    try {setUsage(await run(['telemetry','--client','repogps','--session-id',process.env.RGPS_SESSION_ID,'--json']))}catch{}
  }
  // Local reads and telemetry refreshes never invoke a model.
  const timer=setInterval(()=>setState(readJSON(file)),750)
  const metadataTimer=setInterval(refresh,10000)
  api.lifecycle.onDispose(()=>{clearInterval(timer);clearInterval(metadataTimer)})
  refresh()
  const observation=()=>state()?.evidence?.filter(x=>x.kind==='observation').at(-1)
  const note=()=>state()?.notes?.at(-1)
  const detail=(title,value)=>{
    const Alert=api.ui.DialogAlert
    api.ui.dialog.replace(()=><Alert title={title} message={typeof value==='string'?value:JSON.stringify(value,null,2)} />)
  }
  const details=()=>{
    const Select=api.ui.DialogSelect
    const s=state()
    api.ui.dialog.replace(()=><Select title="RepoGPS Bearings" options={[
      {title:'Current repository observations',value:observation()},
      {title:'Human intent and corrections',value:s?.intent},
      {title:'Navigator interpretations (advisory)',value:s?.notes},
      {title:'Raw evidence and tool outcomes',value:s?.evidence},
      {title:'Lead route and launch limits',value:{current:route(),launch:launchRoute || 'unavailable'}},
      {title:'Attributed usage',value:{lead:usage(),navigator:s?.usage?.navigator,notice:'Active-agent recordkeeping is included in lead usage. Unknown accounting is unavailable, never zero.'}},
    ]} onSelect={item=>detail(item.title,item.value ?? 'Unavailable')} />)
  }
  const routeChooser=async()=>{
    try {
      const providers=await run(['providers','--json'])
      const Select=api.ui.DialogSelect
      const list=Array.isArray(providers)?providers:providers.providers || []
      api.ui.dialog.replace(()=><Select title="Lead provider" options={list.map(p=>({title:p.name || p.id || p.provider,value:p.id || p.provider}))} onSelect={async item=>{
        try {
          const result=await run(['models','--provider',item.value,'--json'])
          const models=Array.isArray(result)?result:result.models || []
          api.ui.dialog.replace(()=><Select title="Lead model" options={models.map(m=>({title:m.name || m.id,value:m.id}))} onSelect={async model=>{
            if(switching()) return
            setSwitching(true)
            api.ui.dialog.clear()
            try {
              const result=await run(['route','set','--provider',item.value,'--model',model.value,'--json'])
              await refresh()
              detail('Lead route result',result)
            }catch(error){await refresh();detail('Switch failed',String(error))}
            finally{setSwitching(false)}
          }} />)
        }catch(error){detail('Model catalog unavailable',String(error))}
      }} />)
    }catch(error){detail('Provider catalog unavailable',String(error))}
  }
  const settings=()=>{
    const Prompt=api.ui.DialogPrompt
    api.ui.dialog.replace(()=><Prompt title="Navigator settings" description="active OR model <provider> <model> [output token ceiling]. Selecting Navigator never switches the lead." value={state()?.navigator?.mode || 'active'} onConfirm={async value=>{
      const parts=value.trim().split(/\s+/)
      const args=['config','navigator','--mode',parts[0]]
      if(parts[0]==='model')args.push('--provider',parts[1] || '', '--model',parts[2] || '')
      if(parts[3])args.push('--max-output-tokens',parts[3])
      const executable=process.env.RGPS_EXECUTABLE
      if(!executable)return detail('Settings unavailable','Use rgps config navigator in another terminal.')
      execFile(executable,args,{timeout:15000},(error,stdout,stderr)=>detail(error?'Navigator settings failed':'Navigator settings saved',error?stderr:stdout))
    }} />)
  }
  api.keymap.registerLayer({commands:[
    {name:'repogps.bearings',title:'Bearings',namespace:'palette',category:'RepoGPS',slashName:'bearings',run:details},
    {name:'repogps.navigator.settings',title:'Navigator settings',namespace:'palette',category:'RepoGPS',slashName:'settings',run:settings},
    {name:'repogps.route',title:'Switch lead route',namespace:'palette',category:'RepoGPS',slashName:'route-choose',run:routeChooser},
    {name:'repogps.bearings.collapse',title:'Collapse or expand Bearings',namespace:'palette',category:'RepoGPS',run:()=>{const next=!collapsed();setCollapsed(next);api.kv.set('repogps.bearings.collapsed',next)}},
  ]})
  const currentRoute=()=>route()?.applied?.model || route()?.model || route()?.selected?.model || 'unavailable'
  const launchModel=()=>launchRoute?.applied_model || launchRoute?.model
  const routeBudgetChanged=()=>{
    const current=route()
    return Boolean(launchRoute && current && (
      launchModel() !== currentRoute()
      || launchRoute?.limits?.context !== current?.limits?.context
      || launchRoute?.limits?.output !== current?.limits?.output
    ))
  }
  const roleTokens=(role)=>usage()?.role_breakdown?.[role]?.total_tokens
  const costText=()=>{
    const cost=usage()?.cost
    if(!cost)return 'unavailable'
    if(cost.provider_reported_usd != null)return `$${Number(cost.provider_reported_usd).toFixed(6)} provider reported`
    if(cost.estimated_usd != null)return `$${Number(cost.estimated_usd).toFixed(6)} estimated`
    return 'unavailable'
  }
  const Panel=()=> <box flexDirection="column" gap={1} onMouseUp={details}>
    <text fg={api.theme.current.primary}><b>RepoGPS Bearings</b></text>
    <text>{path.basename(state()?.repository || process.cwd())} · {observation()?.branch || 'no Git branch'}</text>
    {!collapsed() && <box flexDirection="column" gap={1}>
      <text>{note()?.understanding || 'Establishing current work from repository evidence.'}</text>
      <text>Constraints: {observation()?.sources?.filter(x=>x.path.endsWith('AGENTS.md')).map(x=>path.basename(path.dirname(x.path))).join(', ') || 'Discover local conventions; no setup required'}</text>
      <text>{note()?.next_action || 'Read applicable instructions; clarify the requested outcome.'}</text>
      <text>Verification: inspect tool evidence</text>
      <text>Lead: {currentRoute()}</text>
      {routeBudgetChanged() && <text fg={api.theme.current.warning}>Launch budget differs from the current route; review limits before continuing on a smaller-context model.</text>}
      <text>Navigator: {state()?.navigator?.mode || 'active'} · {state()?.navigator?.status || 'starting'}</text>
      <text>Usage: lead {roleTokens('lead') ?? 'unavailable'} · navigator {roleTokens('navigator') ?? (state()?.navigator?.mode==='active'?'included in lead':'unavailable')} · total {usage()?.total_tokens ?? 'unavailable'} tokens</text>
      <text>Cost: {costText()}</text>
      <text>Active recordkeeping included in lead usage</text>
      <text fg={api.theme.current.textMuted}>/bearings for details · /route-choose</text>
    </box>}
  </box>
  api.slots.register({order:50,slots:{sidebar_content:Panel,session_prompt_right:()=> <text>Bearings · {state()?.navigator?.status || 'starting'} · /bearings</text>,home_bottom:()=> <text>RepoGPS · local bearings ready when work begins</text>}})
}}
