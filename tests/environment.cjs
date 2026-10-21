'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {createEnvironment}=require('../macos/environment.cjs');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'badge-environment-'));
const profile=path.join(temp,'Library/Application Support/Codex');
fs.mkdirSync(profile,{recursive:true});
const values=new Map();let fail='';
const command=(bin,args)=>{
  assert.equal(bin,'/bin/launchctl');
  const [action,key,value]=args;
  if(action==='getenv')return values.get(key)||'';
  if(fail===key){fail='';throw Error('injected environment write failure');}
  if(action==='setenv'){values.set(key,value);return '';}
  if(action==='unsetenv'){values.delete(key);return '';}
  throw Error('Unexpected operation '+action);
};
try{
  const env=createEnvironment({home:temp,command});
  const backup=path.join(temp,'Library/Application Support/CodexUsageBadge-Environment/environment-backup.json');
  assert.equal(env.status().installed,false);
  fail='CODEX_ELECTRON_CHROMIUM_SWITCHES';assert.throws(()=>env.prepare(),/injected/);
  assert.equal(values.size,0);assert.equal(fs.existsSync(backup),false);
  const first=env.prepare();assert.equal(first.created,true);assert.equal(env.status().variablesMatch,true);
  const original=fs.readFileSync(backup,'utf8');assert.equal(env.prepare().created,false);
  assert.equal(fs.readFileSync(backup,'utf8'),original,'repeat install retains original backup');
  values.clear();assert.equal(env.status().variablesMatch,false);env.applySession();assert.equal(env.status().variablesMatch,true);
  values.set('BUILD_FLAVOR','external');assert.throws(()=>env.checkRestore(),/refusing/);assert.throws(()=>env.prepare(),/refusing/);
  assert.equal(values.get('BUILD_FLAVOR'),'external');values.set('BUILD_FLAVOR','dev');
  fail='CODEX_ELECTRON_CHROMIUM_SWITCHES';assert.throws(()=>env.restore(),/injected/);
  assert.equal(env.status().variablesMatch,true);assert.equal(fs.existsSync(backup),true);
  env.restore();assert.equal(values.size,0);assert.equal(env.status().installed,false);env.restore();
  values.set('BUILD_FLAVOR','prod');values.set('CODEX_ELECTRON_CHROMIUM_SWITCHES','previous-switches');
  const custom=path.join(temp,'custom-profile');fs.mkdirSync(custom);values.set('CODEX_ELECTRON_USER_DATA_PATH',custom);
  const transaction=env.prepare();assert.equal(env.status().profilePath,custom);transaction.rollback();
  assert.equal(values.get('BUILD_FLAVOR'),'prod');assert.equal(values.get('CODEX_ELECTRON_CHROMIUM_SWITCHES'),'previous-switches');
  assert.equal(values.get('CODEX_ELECTRON_USER_DATA_PATH'),custom);assert.equal(env.status().installed,false);
  console.log('PASS macOS environment install, idempotence, login reapply, conflict refusal, partial-failure rollback, exact restore and custom profile (launchctl mocked)');
}finally{fs.rmSync(temp,{recursive:true,force:true});}
