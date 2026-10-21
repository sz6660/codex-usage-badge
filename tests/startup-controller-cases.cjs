'use strict';
const assert=require('node:assert/strict');
module.exports=async function check(modulePath) {
  const {StartupController}=require(modulePath);
  const app=(key='new',overrides={})=>({key,pid:20,launchedAt:99500,finishedLaunching:true,argumentsKnown:true,plainLaunch:true,debugPort:null,inputStamp:'client:0',inputIdleMs:10000,...overrides});
  async function scenario(options={},verify) {
    let now=100000,apps=options.baseline||[],input='global:1',frontmost=options.foreground??20;
    const calls=[],records=[],shows=[];
    const adapter={
      snapshot:async()=>({apps,frontmostPid:frontmost,inputStamp:input,inputIdleMs:0,...options.snapshot}),
      portInUse:async()=>!!options.portInUse,
      record:async(event,details)=>{records.push({event,...details});if(event==='attempt'&&options.failReceipt)throw Error('disk full');},
      quit:async(a,stamp)=>{calls.push('quit');assert.equal(stamp,a.inputStamp);if(options.quit!==false&&options.exit!==false){apps=[];frontmost=30;}return {accepted:options.quit!==false};},
      launch:async()=>{calls.push('launch');apps=[app('replacement',{pid:21,debugPort:'39222'})];options.onLaunch?.({setInput:v=>input=v,setFront:v=>frontmost=v});return {launched:options.launch!==false,key:'replacement',pid:21};},
      show:async(a,stamp,foreground)=>{calls.push('show');shows.push({stamp,foreground});return {shown:options.shown!==false,activated:false};}
    };
    const control=new StartupController(adapter,{now:()=>now,sleep:async ms=>{now+=ms;options.onSleep?.({setApps:v=>apps=v,setInput:v=>input=v,stop:()=>control.stop()});},lastAttemptAt:options.lastAttemptAt||0});
    await control.tick();apps=options.fresh||[app()];await control.tick();
    await verify({calls,records,shows,control,setApps:v=>apps=v,setNow:v=>now=v,setInput:v=>input=v});
  }
  const success=({calls})=>assert.deepEqual(calls,['quit','launch','show']);
  await scenario({},success);
  await scenario({baseline:[app()]},({calls})=>assert.deepEqual(calls,[]));
  for(const overrides of [{launchedAt:1000},{launchedAt:101000},{argumentsKnown:false},{plainLaunch:false},{debugPort:'39222'},{debugPort:'9222'},{inputIdleMs:100}]){
    await scenario({fresh:[app('new',overrides)]},({calls})=>assert.deepEqual(calls,[]));
  }
  await scenario({foreground:30,fresh:[app('new',{inputIdleMs:100})]},({calls,records})=>{
    assert.deepEqual(calls,[]);assert.equal(records.at(-1).reason,'client-input','Prior Codex interaction stays protected after switching apps');
  });
  await scenario({foreground:30,snapshot:{inputIdleMs:0}},({calls,shows})=>{
    success({calls});assert.equal(shows[0].foreground,-1,'A background client must never request foreground activation');
  });
  await scenario({onSleep:({setInput})=>setInput('other-app:typing')},success);
  await scenario({onLaunch:({setInput,setFront})=>{setInput('other-app:click');setFront(99);}},success);
  for(const overrides of [{finishedLaunching:false},{inputStamp:'unknown',inputIdleMs:0}]){
    await scenario({fresh:[app('new',overrides)]},async({calls,control,setApps})=>{
      assert.deepEqual(calls,[]);assert.equal(control.pendingLaunch,true);
      setApps([app()]);await control.tick();success({calls});
    });
  }
  await scenario({fresh:[app(),app('second',{pid:99})]},({calls})=>assert.deepEqual(calls,[]));
  await scenario({lastAttemptAt:99000},success);
  await scenario({portInUse:true},({calls,records})=>{assert.deepEqual(calls,[]);assert.equal(records.at(-1).event,'port-in-use');});
  await scenario({failReceipt:true},({calls,records})=>{assert.deepEqual(calls,[]);assert.equal(records.at(-1).event,'error');});
  await scenario({quit:false},async({calls,control})=>{await control.tick();assert.deepEqual(calls,['quit']);});
  await scenario({exit:false},({calls,records})=>{assert.deepEqual(calls,['quit']);assert.equal(records.at(-1).event,'quit-timeout');});
  await scenario({onSleep:({setApps})=>setApps([app('manual-reopen')])},({calls})=>assert.deepEqual(calls,['quit']));
  await scenario({onSleep:({stop})=>stop()},({calls})=>assert.deepEqual(calls,['quit']));
  await scenario({launch:false},({calls})=>assert.deepEqual(calls,['quit','launch']));
  await scenario({shown:false},({records})=>assert.equal(records.at(-1).event,'reopened-window-pending'));
  await scenario({},async({calls,control,setApps})=>{
    setApps([app('replacement')]);await control.tick();success({calls});
    setApps([]);await control.tick();setApps([app('user-again')]);await control.tick();
    assert.deepEqual(calls,['quit','launch','show','quit','launch','show']);
  });
  console.log('PASS '+modulePath+': scoped client input, background load without activation, outside input during shutdown/reopen, protected client work, cold/unknown input, rapid relaunch, no loops, refusal and cancellation');
};
