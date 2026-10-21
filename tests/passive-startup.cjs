'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
(async()=>{
  for(const platform of ['windows','macos']){
    const temp=fs.mkdtempSync(path.join(os.tmpdir(),'badge-passive-'));
    const folder=path.join(temp,platform==='windows'?'startup':'startup-helper');fs.mkdirSync(folder);
    const source=platform==='windows'?'startup/windows.cjs':'macos/startup/watch.cjs';
    fs.copyFileSync(path.join(root,source),path.join(folder,'watch.cjs'));
    // If the old restart controller is constructed at all, fail immediately.
    fs.writeFileSync(path.join(folder,'controller.cjs'),"exports.StartupController=class{constructor(){throw Error('Restart controller must never be used')}};");
    fs.mkdirSync(path.join(temp,'macos'));
    fs.writeFileSync(path.join(temp,'macos/environment.cjs'),"exports.applySession=()=>{};");
    const stop=path.join(temp,'stop');
    const child=spawn(process.execPath,[path.join(folder,'watch.cjs')],{env:{...process.env,CODEX_BADGE_STOP_FILE:stop},stdio:['ignore','pipe','pipe'],windowsHide:true});
    let stderr='';child.stderr.on('data',b=>stderr+=b);child.stdout.resume();
    const done=new Promise(resolve=>child.once('exit',(code,signal)=>resolve({code,signal})));
    try{
      const receipt=path.join(folder,'state.json');
      for(let i=0;i<60&&!fs.existsSync(receipt)&&child.exitCode===null;i++)await sleep(50);
      assert.equal(fs.existsSync(receipt),true,stderr);
      const state=JSON.parse(fs.readFileSync(receipt,'utf8'));
      assert.equal(state.automaticRestart,false);assert.equal(state.mode,'environment-connection-only');
      await sleep(350);assert.equal(child.exitCode,null,stderr);
      fs.writeFileSync(stop,'stop');
      const exit=await Promise.race([done,sleep(3000).then(()=>{throw Error('Observer did not stop')})]);
      assert.equal(exit.code,0,stderr);
    }finally{if(child.exitCode===null){child.kill();await done;}fs.rmSync(temp,{recursive:true,force:true});}
  }
  console.log('PASS both packaged startup observers stay alive, acknowledge readiness and stop without constructing a restart controller');
})().catch(error=>{console.error(error);process.exitCode=1;});
