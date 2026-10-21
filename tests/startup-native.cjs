'use strict';
// Uses a temporary windowless test app. Never quits or activates the real Codex client.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const assert=require('node:assert/strict');
const {execFile,spawn}=require('node:child_process');
const {promisify}=require('node:util');
const readline=require('node:readline');
const {NativeBridge}=require('../macos/startup/watch.cjs');
const run=promisify(execFile);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const bridge=process.argv[2];
if(process.platform!=='darwin'||!bridge)throw Error('Use on macOS: node tests/startup-native.cjs /path/to/compiled/bridge');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'codex-startup-native-test-'));
const app=path.join(root,'Startup Test.app'),macos=path.join(app,'Contents/MacOS');
const events=[];
let childPid,observer,server;
async function call(action,...args){return JSON.parse((await run(bridge,[action,app,...args.map(String)],{timeout:35000})).stdout);}
async function waitUntil(test){for(let i=0;i<50;i++){if(test())return;await sleep(100);}throw Error('Native observer missed a process transition');}
(async()=>{
  fs.mkdirSync(macos,{recursive:true});
  const activityTest=path.join(root,'activity-test.m');
  fs.writeFileSync(activityTest,`#define main badgeStartupMain
#include ${JSON.stringify(path.resolve(__dirname,'../macos/startup/bridge.m'))}
#undef main
#include <assert.h>
int main(void){@autoreleasepool{
  clientInputs=[NSMutableDictionary dictionary];
  assert(keyForEvent(kCGEventKeyDown,nil,nil,nil)==nil);
  assert(keyForEvent(kCGEventKeyDown,@"codex",nil,nil)==nil);
  assert([keyForEvent(kCGEventKeyDown,@"codex",@"codex",nil) isEqual:@"codex"]);
  assert(keyForEvent(kCGEventLeftMouseDown,@"codex",@"codex",nil)==nil);
  assert([keyForEvent(kCGEventScrollWheel,nil,nil,@"codex") isEqual:@"codex"]);
  recordClientInput(nil,1000,999);assert(clientInputs.count==0);
  recordClientInput(@"codex",1100,1099);
  recordClientInput(nil,1200,1199);
  assert([clientInputs[@"codex"][@"sequence"] intValue]==1);
  assert([clientInputs[@"codex"][@"lastInput"] doubleValue]==1099);
}return 0;}
`);
  await run('/usr/bin/xcrun',['clang','-fobjc-arc','-framework','AppKit','-framework','ApplicationServices',activityTest,'-o',path.join(root,'activity-test')]);
  await run(path.join(root,'activity-test'));
  fs.writeFileSync(path.join(root,'fixture.m'),'#import <AppKit/AppKit.h>\nint main(void){@autoreleasepool{NSApplication *a=NSApplication.sharedApplication;[a setActivationPolicy:NSApplicationActivationPolicyProhibited];[a run];}return 0;}\n');
  fs.writeFileSync(path.join(app,'Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>fixture</string><key>CFBundleIdentifier</key><string>local.codexusagebadge.startup-test-${process.pid}</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
  await run('/usr/bin/xcrun',['clang','-fobjc-arc','-framework','AppKit',path.join(root,'fixture.m'),'-o',path.join(macos,'fixture')]);
  observer=spawn(bridge,['watch',app],{stdio:['ignore','pipe','pipe']});
  readline.createInterface({input:observer.stdout}).on('line',line=>events.push(JSON.parse(line)));
  await waitUntil(()=>events.length>0);
  const initial=await call('snapshot');assert.equal(initial.apps.length,0);
  const opened=await call('launch',initial.inputStamp,initial.frontmostPid);
  assert.equal(opened.launched,true,'Input changed during test or native launch failed');childPid=opened.pid;
  await waitUntil(()=>events.some(e=>e.apps.some(a=>a.pid===childPid)));
  const current=await call('snapshot');assert.equal(current.apps.length,1);
  server=new NativeBridge(path.resolve(bridge),app);
  await server.call('snapshot');await sleep(350);
  const scoped=await server.call('snapshot');
  assert.notEqual(scoped.apps[0].inputStamp,'unknown','Persistent helper must retain client activity between requests');
  assert.equal(current.apps[0].debugPort,'39222');assert.equal(current.apps[0].key,opened.key);
  assert.equal(current.frontmostPid,initial.frontmostPid,'Hidden launch must not steal focus');
  const revealed=await call('show',childPid,opened.key,'invalid-input-stamp',initial.frontmostPid);
  assert.equal(revealed.activated,false,'Changed input must still prevent foreground activation');
  assert.equal((await call('snapshot')).frontmostPid,initial.frontmostPid,'Recovery must preserve another app foreground');
  assert.equal((await call('show',childPid,'wrong-identity',initial.inputStamp,initial.frontmostPid)).shown,false);
  assert.equal((await call('quit',childPid,opened.key,current.inputStamp)).accepted,false,'Background debugging fixture must not be restarted');
  const beforeExit=events.length;
  process.kill(childPid,'SIGTERM');childPid=null;
  await waitUntil(()=>events.slice(beforeExit).some(e=>e.apps.length===0));
  assert.equal((await call('snapshot')).apps.length,0);
  const restored=await server.call('launch','outside-app-input-changed',-1,'restore');
  assert.equal(restored.launched,true,'Other-app input must not cancel restoring an already closed client');childPid=restored.pid;
  assert.equal((await call('snapshot')).frontmostPid,initial.frontmostPid,'Background restore must preserve another app foreground');
  console.log('PASS native activity attribution, focus transitions, inactive scrolling, persistent RPC history, outside input during restore, identity and no foreground theft');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{
  if(childPid)try{process.kill(childPid,'SIGTERM');}catch{}
  server?.close();
  observer?.kill('SIGTERM');await sleep(200);fs.rmSync(root,{recursive:true,force:true});
});
