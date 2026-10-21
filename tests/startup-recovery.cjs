'use strict';
const assert=require('node:assert/strict');

async function check(modulePath) {
  const {StartupController}=require(modulePath);
  let now=100000,apps=[],stamp='1',front=20,shows=0,quits=0,launches=0;
  const records=[];
  const app=(key,pid,port=null)=>({key,pid,launchedAt:now-100,finishedLaunching:true,argumentsKnown:true,plainLaunch:true,debugPort:port});
  let shown=true;
  const adapter={
    snapshot:async()=>({apps,frontmostPid:front,inputStamp:stamp,inputIdleMs:10000}),
    portInUse:async()=>false,
    record:async(event,details)=>records.push({event,...details}),
    quit:async()=>{quits++;apps=[];front=30;return {accepted:true};},
    launch:async()=>{launches++;apps=[app('replacement-'+launches,20+launches,'39222')];stamp=String(Number(stamp)+1);return {launched:true,...apps[0]};},
    show:async()=>{shows++;return {shown,activated:false,reason:shown?'visible-without-focus':'window-timeout'};}
  };
  const control=new StartupController(adapter,{now:()=>now,sleep:async ms=>{now+=ms;},lastAttemptAt:now-1000});
  await control.tick();apps=[app('user-1',20)];await control.tick();
  assert.equal(quits,1,'A recent previous attempt must not block a different user process');
  assert.equal(shows,1,'Input during startup must still reach visibility recovery');
  assert.equal(records.at(-1).event,'reopened');
  assert.equal(records.at(-1).activated,false,'Visibility and focus are distinct outcomes');
  // Electron may strip flags; the replacement identity must still prevent a loop.
  apps[0].debugPort=null;await control.tick();assert.equal(quits,1);
  // An explicit user close/open seconds later must be handled immediately.
  apps=[];await control.tick();front=20;apps=[app('user-2',20)];
  shown=false;await control.tick();assert.equal(quits,2);
  assert.equal(records.at(-1).event,'reopened-window-pending','Do not report success without a visible window');
  await control.tick();assert.equal(quits,2,'A pending window must not trigger a restart loop');
  // Restarting the watcher must baseline an existing window rather than restart it.
  const restarted=new StartupController(adapter,{now:()=>now,lastAttemptAt:now});
  await restarted.tick();await restarted.tick();assert.equal(quits,2);
}
(async()=>{
  await check('../startup/controller.cjs');
  await check('../macos/startup/controller.cjs');
  console.log('PASS both platforms: rapid user relaunch, replacement loop prevention, input/focus changes, truthful visibility diagnostics and watcher restart');
})().catch(error=>{console.error(error);process.exitCode=1;});
