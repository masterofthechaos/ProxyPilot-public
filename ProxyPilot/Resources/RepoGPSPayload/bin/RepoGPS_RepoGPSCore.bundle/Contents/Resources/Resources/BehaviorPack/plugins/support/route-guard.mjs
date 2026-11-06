import { execFileSync } from 'node:child_process'

export function routeIdentity(route) {
  return [route?.provider || route?.applied_provider,route?.applied_model || route?.model]
}
// Match OpenCodeConfigurator's effective limits and enum-valued modalities.
// Raw catalog maxima above the coding budget and unsupported enum additions do
// not require a restart when the engine's configuration would remain identical.
const positiveLimit=value=>Number.isSafeInteger(value) && value>0 ? value : null
function engineModalities(value) {
  const allowed=new Set(['text','audio','image','video','pdf'])
  const result=Array.isArray(value)?[...new Set(value.filter(item=>allowed.has(item)))].sort():[]
  return result.length?result:['text']
}
export function capabilityFingerprint(route) {
  const input=engineModalities(route?.modalities?.input)
  if(route?.modalities?.image_support==='supported' && !input.includes('image'))input.push('image')
  return JSON.stringify({context:positiveLimit(route?.limits?.context) ?? 200000,output_limit:Math.min(positiveLimit(route?.limits?.output) ?? 8000,8000),input:input.sort(),output:engineModalities(route?.modalities?.output),image_support:route?.modalities?.image_support || 'unknown'})
}
export function readRoute(executable) {
  const result=JSON.parse(execFileSync(executable,['route','status','--json'],{encoding:'utf8',timeout:10000,maxBuffer:256*1024,stdio:['ignore','pipe','pipe']}))
  if(result.ok===false)throw Error('Route metadata unavailable')
  return result.data || result
}
export function hasImages(messages) {
  return messages.some(message=>(message.parts || []).some(part=>(part.type==='file' && part.mime?.startsWith('image/')) || (part.state?.attachments || []).some(file=>file.mime?.startsWith('image/'))))
}
export function validateRoute({launch,current,messages,override}) {
  if(capabilityFingerprint(launch)!==capabilityFingerprint(current))return 'The route capabilities or context limits changed. Refresh the engine before continuing.'
  if(!hasImages(messages))return null
  const support=current?.metadata_stale ? 'unknown' : (current?.modalities?.image_support || 'unknown')
  if(support==='supported')return null
  if(support==='unsupported')return 'The selected model reports no image input support. Choose an image-capable route before resuming.'
  if(override && JSON.stringify(routeIdentity(current))===JSON.stringify(override))return null
  return 'Image input support is unknown. Refresh model metadata or explicitly retry with --allow-unknown-images for this route.'
}
