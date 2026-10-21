'use strict';
// Only the user's launchd environment is changed. App bundles, shell profiles,
// account files and launchers are never edited, launched or stopped here.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {execFileSync}=require('node:child_process');
const keys=['BUILD_FLAVOR','CODEX_ELECTRON_CHROMIUM_SWITCHES','CODEX_ELECTRON_USER_DATA_PATH'];
const owner='local.codexusagebadge.environment-v1';
function createEnvironment({home=os.homedir(),command=(bin,args)=>execFileSync(bin,args,{encoding:'utf8',timeout:10000})}={}){
  const root=path.join(home,'Library/Application Support/CodexUsageBadge-Environment');
  const backup=path.join(root,'environment-backup.json');
  function get(key){try{return command('/bin/launchctl',['getenv',key]).replace(/\r?\n$/,'')||null;}catch(error){if(error.status===1)return null;throw error;}}
  function set(key,value){command('/bin/launchctl',value==null?['unsetenv',key]:['setenv',key,value]);}
  function read(){
    if(fs.existsSync(root)&&(!fs.lstatSync(root).isDirectory()||fs.lstatSync(root).isSymbolicLink()))throw Error('Environment backup directory is not a regular directory');
    if(!fs.existsSync(backup))return null;
    if(fs.lstatSync(backup).isSymbolicLink())throw Error('Environment backup must not be a symbolic link');
    const state=JSON.parse(fs.readFileSync(backup,'utf8'));
    if(state.owner!==owner||![state.original,state.applied].every(o=>o&&Object.keys(o).length===3&&keys.every(k=>Object.hasOwn(o,k)&&(o[k]===null||typeof o[k]==='string'))))throw Error('Invalid environment backup');
    return state;
  }
  function assertValues(state){
    const current=snapshot();
    // launchd session values disappear on logout, including pre-existing values.
    if(keys.every(key=>current[key]===null))return;
    for(const key of keys)if(current[key]!==state.applied[key]&&current[key]!==state.original[key])throw Error('Environment changed after installation; refusing to overwrite: '+key);
  }
  function snapshot(){return Object.fromEntries(keys.map(key=>[key,get(key)]));}
  function change(values){
    const before=snapshot();
    try{for(const key of keys)set(key,values[key]);}
    catch(error){for(const key of keys){try{set(key,before[key]);}catch(rollback){error.rollbackFailed=true;error.message+='; environment rollback failed: '+rollback.message;}}throw error;}
    return ()=>change(before);
  }
  function applySession(){const state=read();if(!state)throw Error('Environment backup is missing; run installation again');assertValues(state);change(state.applied);}
  function prepare(){
    const existing=read();
    if(existing){assertValues(existing);const undo=change(existing.applied);return {created:false,rollback:undo};}
    const profile=get('CODEX_ELECTRON_USER_DATA_PATH')||path.join(home,'Library/Application Support/Codex');
    if(!fs.existsSync(profile)||!fs.statSync(profile).isDirectory())throw Error('Existing Codex profile not found; open Codex once before installing');
    const state={owner,createdAt:new Date().toISOString(),original:snapshot(),applied:{BUILD_FLAVOR:'dev',CODEX_ELECTRON_CHROMIUM_SWITCHES:JSON.stringify({'remote-debugging-address':'127.0.0.1','remote-debugging-port':'39222'}),CODEX_ELECTRON_USER_DATA_PATH:profile}};
    fs.mkdirSync(root,{recursive:true,mode:0o700});
    fs.writeFileSync(backup,JSON.stringify(state,null,2)+'\n',{mode:0o600,flag:'wx'});
    try{change(state.applied);}catch(error){if(!error.rollbackFailed)fs.unlinkSync(backup);throw error;}
    return {created:true,rollback(){change(state.original);fs.unlinkSync(backup);}};
  }
  function checkRestore(){const state=read();if(state)assertValues(state);return state;}
  function restore(){
    const state=checkRestore();if(!state)return;
    const undo=change(state.original);
    try{fs.renameSync(backup,path.join(root,`environment-restored-${Date.now()}.json`));}catch(error){undo();throw error;}
  }
  function status(){const state=read();return {installed:!!state,mode:'environment-connection-only',automaticRestart:false,variablesMatch:!!state&&keys.every(key=>get(key)===state.applied[key]),profilePath:state?.applied.CODEX_ELECTRON_USER_DATA_PATH??null};}
  return {prepare,applySession,checkRestore,restore,status};
}
module.exports={createEnvironment,applySession:()=>createEnvironment().applySession()};
