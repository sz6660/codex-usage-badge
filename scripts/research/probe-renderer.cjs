'use strict';
// CI only: connect to the empty-account application's renderer, without launching it.
if(process.env.GITHUB_ACTIONS!=='true')throw Error('GitHub-hosted research only');
const fs=require('node:fs'),path=require('node:path');
const {buildBootstrapScript,isMainWindow}=require('../../agent.cjs');
const port=Number(process.argv[2]),file=process.argv[3];
const report={connected:false,mainPageFound:false,bootstrapEvaluated:false,accountLoggedIn:false,quotaSource:'none (CI does not sign in)',errors:[]};
let socket;
async function main(){
  const response=await fetch(`http://127.0.0.1:${port}/json/list`,{signal:AbortSignal.timeout(2000)});
  const targets=await response.json();report.connected=true;
  report.targets=targets.map(t=>({type:t.type,url:t.url}));
  const target=targets.find(isMainWindow);
  if(!target)return;
  report.mainPageFound=true;
  socket=new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});setTimeout(()=>reject(Error('WebSocket open timeout')),5000).unref();});
  let id=0;const pending=new Map();
  socket.addEventListener('message',event=>{const data=JSON.parse(event.data);if(pending.has(data.id)){const p=pending.get(data.id);pending.delete(data.id);data.error?p.reject(Error(data.error.message)):p.resolve(data.result);}});
  function send(method,params={}){return new Promise((resolve,reject)=>{const seq=++id;pending.set(seq,{resolve,reject});socket.send(JSON.stringify({id:seq,method,params}));setTimeout(()=>{if(pending.delete(seq))reject(Error(method+' timed out'));},8000).unref();});}
  await send('Runtime.enable');
  const value=await send('Runtime.evaluate',{expression:buildBootstrapScript(),returnByValue:true});
  if(value.exceptionDetails)throw Error(value.exceptionDetails.text);
  report.bootstrapEvaluated=true;
  await new Promise(resolve=>setTimeout(resolve,5000));
  const status=await send('Runtime.evaluate',{expression:'JSON.stringify({usage:window.__codexUsageBadge?.status()??null,colors:window.__codexProjectColors?.status()??null,tokens:window.__codexThreadTokens?.status()??null,sizes:window.__codexProjectSizes?.status()??null,readyState:document.readyState,navCount:document.querySelectorAll("nav").length})',returnByValue:true});
  report.rendererStatus=JSON.parse(status.result.value);
  try{const screenshot=await send('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(path.dirname(file),path.basename(file,'.json')+'.png'),Buffer.from(screenshot.data,'base64'));}catch(error){report.errors.push('Screenshot: '+error.message);}
}
main().catch(error=>report.errors.push(error.message)).finally(()=>{socket?.close();fs.writeFileSync(file,JSON.stringify(report,null,2));console.log(JSON.stringify(report));});
