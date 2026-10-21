'use strict';
const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {PassThrough}=require('node:stream');
const {NativeBridge}=require('../macos/startup/watch.cjs');
(async()=>{
  let child,args;
  const bridge=new NativeBridge('/fixture/bridge','/fixture/Client.app',{spawnProcess:(exe,a)=>{
    args=a;child=new EventEmitter();child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();child.kill=()=>{};return child;
  }});
  assert.deepEqual(args,['serve','/fixture/Client.app']);
  const pending=bridge.call('snapshot'),request=JSON.parse(child.stdin.read().toString());
  child.stdout.write(JSON.stringify({id:request.id,result:{apps:[{inputStamp:'0',inputIdleMs:1e15}]}})+'\n');
  assert.equal((await pending).apps[0].inputStamp,'0');
  const restore=bridge.call('launch','global:changed',-1,'restore'),launch=JSON.parse(child.stdin.read().toString());
  assert.deepEqual(launch.args,['launch','/fixture/Client.app','global:changed','-1','restore']);
  child.stdout.write(JSON.stringify({id:launch.id,result:{launched:true}})+'\n');await restore;
  const failed=bridge.call('quit',10,'key','client:0'),quit=JSON.parse(child.stdin.read().toString());
  child.stdout.write(JSON.stringify({id:quit.id,result:{error:'refused'}})+'\n');await assert.rejects(failed,/refused/);
  const lost=bridge.call('snapshot');child.emit('exit');await assert.rejects(lost,/exited/);bridge.close();
  console.log('PASS macOS persistent native RPC, scoped activity, background restore, native errors and helper exit');
})().catch(error=>{console.error(error);process.exitCode=1;});
