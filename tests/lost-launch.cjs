'use strict';
const assert=require('node:assert/strict');
const {LostLaunchRecovery}=require('../startup/lost-launch.cjs');
function fixture(){
  let now=0,launches=0;const records=[];
  const model=new LostLaunchRecovery({now:()=>now,record:(...args)=>records.push(args),launch:async()=>{launches++;return {launched:true};}});
  const tick=async(time,events=[],mainPids=[],portReady=false)=>{now=time;await model.tick({observedAt:time,events,mainPids,portReady});};
  return {model,tick,records,get launches(){return launches;}};
}
const event=(id,time,pid=0,extra={})=>({id,time,pid,container:'{container-a}',recordId:time,fresh:true,portWasUnavailable:true,...extra});
(async()=>{
  let f=fixture();
  await f.tick(0,[event(210,0),event(211,0,10)], [10],true);
  await f.tick(1000,[],[10]);
  await f.tick(2000,[event(211,2000,20)],[10]);
  await f.tick(3000,[event(217,3000)]);
  await f.tick(4999);assert.equal(f.launches,0,'wait for stable empty process set');
  await f.tick(5000);assert.equal(f.launches,1);await f.tick(9000);assert.equal(f.launches,1);
  assert.equal(f.records.at(-1)[0],'lost-activation-recovered');
  // Ordinary quit with no new original-entry activation never opens a window.
  f=fixture();await f.tick(0,[event(210,0),event(211,0,10)],[10],true);
  await f.tick(1000,[event(217,1000)]);await f.tick(10000);assert.equal(f.launches,0);
  // A second icon click delivered to a healthy running client must not be replayed.
  f=fixture();await f.tick(0,[event(210,0),event(211,0,10)],[10],true);
  await f.tick(1000,[event(211,1000,20)],[10],true);await f.tick(2000,[event(217,2000)]);await f.tick(9000);assert.equal(f.launches,0);
  // A click during this poll's port transition is ambiguous, so fail closed.
  f=fixture();await f.tick(0,[event(210,0),event(211,0,10)],[10],true);
  await f.tick(1000,[event(211,1000,20,{portWasUnavailable:false})],[10]);await f.tick(2000,[event(217,2000)]);await f.tick(9000);assert.equal(f.launches,0);
  // Historical or delayed events must never resurrect an old request.
  for(const extra of [{fresh:false},{time:-10000}]){
    f=fixture();await f.tick(0,[event(210,0),event(211,0,10)],[10],true);
    await f.tick(1000,[event(211,1000,20,extra)],[10]);await f.tick(2000,[event(217,2000)]);await f.tick(9000);assert.equal(f.launches,0);
  }
  // A successful manual retry cancels recovery. Old container destruction alone is insufficient.
  f=fixture();await f.tick(0,[event(210,0),event(211,0,10)],[10],true);
  await f.tick(1000,[event(211,1000,20)],[10]);await f.tick(2000,[event(217,2000)]);
  await f.tick(3000,[],[30],true);await f.tick(9000);assert.equal(f.launches,0);
  // Retained main process, missing destruction, expiry, stop, and repeated native failures.
  for(const mode of ['main-retained','no-destruction','expired','stopped']){
    f=fixture();await f.tick(0,[event(210,0),event(211,0,10)],[10],true);
    await f.tick(1000,[event(211,1000,20)],[10]);
    await f.tick(2000,mode==='no-destruction'?[]:[event(217,2000)],mode==='main-retained'?[10]:[]);
    if(mode==='stopped')f.model.stop();
    await f.tick(mode==='expired'?17000:5000,[],mode==='main-retained'?[10]:[]);assert.equal(f.launches,0,mode);
  }
  // An initial cold launch which never reached a ready port is not sufficient evidence.
  f=fixture();await f.tick(0,[event(210,0),event(211,0,10)],[10],false);
  await f.tick(1000,[event(211,1000,20)],[10]);await f.tick(2000,[event(217,2000)]);await f.tick(5000);assert.equal(f.launches,0);
  console.log('PASS lost Windows activation recovery: container evidence, unavailable port, stable exit, exactly once, normal quit, healthy second click, manual retry, stale events, expiry and stop');
})().catch(error=>{console.error(error);process.exitCode=1;});
