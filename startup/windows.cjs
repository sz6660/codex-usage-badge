'use strict';
const fs=require('node:fs');
const path=require('node:path');
const net=require('node:net');
const {spawn}=require('node:child_process');
const readline=require('node:readline');
const {StartupController}=require('./controller.cjs');

class NativeBridge {
  constructor(app,stopFile,{spawnProcess=spawn}={}) {
    this.nextId=0;this.pending=new Map();this.closed=false;
    const shell=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe');
    this.child=spawnProcess(shell,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'windows-bridge.ps1'),'-AppExe',app,'-StopFile',stopFile,'-ParentId',String(process.pid)],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    this.lines=readline.createInterface({input:this.child.stdout});
    this.lines.on('line',line=>{
      try {
        const reply=JSON.parse(line),entry=this.pending.get(reply.id);
        if(!entry)throw Error('Unexpected startup bridge response');
        this.pending.delete(reply.id);clearTimeout(entry.timer);
        if(reply.error)entry.reject(Error(reply.error));else entry.resolve(reply.result);
      } catch(error){this.fail(error);}
    });
    this.child.stderr.on('data',()=>{}); // Never print native command lines or personal paths.
    this.child.stdin.on('error',error=>this.fail(error));
    this.child.once('error',error=>this.fail(error));
    this.child.once('exit',()=>this.fail(Error('Native startup helper exited')));
  }
  fail(error) {
    this.closed=true;
    for(const entry of this.pending.values()){clearTimeout(entry.timer);entry.reject(error);}
    this.pending.clear();
  }
  call(action,fields={}) {
    if(this.closed)return Promise.reject(Error('Native startup helper unavailable'));
    const id=++this.nextId;
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.fail(Error('Native startup helper timeout'));this.child.stdin.end();},35000);
      this.pending.set(id,{resolve,reject,timer});
      this.child.stdin.write(JSON.stringify({id,action,...fields})+'\n');
    });
  }
  close() {this.fail(Error('Startup watcher stopped'));this.child.stdin.end();this.lines.close();}
}
function portInUse() {
  return new Promise(resolve=>{
    const socket=net.createConnection({host:'127.0.0.1',port:39222});
    const done=value=>{socket.destroy();resolve(value);};
    socket.once('connect',()=>done(true));socket.once('error',error=>done(error.code!=='ECONNREFUSED'));
    socket.setTimeout(350,()=>done(true));
  });
}
function readReceipt(file) {
  let state={};try{state=JSON.parse(fs.readFileSync(file,'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
  if(!Number.isFinite(state.lastAttemptAt??0)||(state.lastAttemptAt??0)<0)throw Error('Invalid startup receipt');
  return state;
}
function writeReceipt(file,state) {
  const temp=file+'.tmp';const fd=fs.openSync(temp,'w',0o600);
  try{fs.writeFileSync(fd,JSON.stringify(state,null,2)+'\n');fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
  fs.renameSync(temp,file);
}
async function main(){
  const root=path.dirname(__dirname);
  const stopFile=process.env.CODEX_BADGE_STOP_FILE||path.join(root,'stop.request');
  const receipt=path.join(__dirname,'state.json');
  const state={event:'watching',mode:'environment-connection-only',automaticRestart:false,pid:process.pid,updatedAt:Date.now()};
  fs.writeFileSync(receipt,JSON.stringify(state,null,2)+'\n');
  console.log(new Date().toISOString(),'environment-connection-only: no client quit/restart; recover lost original-entry activation only');
  let observer=null,recovery=null;
  const activationScript=path.join(__dirname,'activation-watch.ps1');
  if(process.env.CODEX_BADGE_APP&&fs.existsSync(activationScript)){
    const {LostLaunchRecovery}=require('./lost-launch.cjs');
    const shell=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe');
    const args=['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',activationScript,
      '-AppExe',process.env.CODEX_BADGE_APP,'-StopFile',stopFile,'-ParentId',String(process.pid)];
    const record=(event,details={})=>{
      writeReceipt(path.join(__dirname,'recovery.json'),{event,...details,updatedAt:Date.now(),automaticRestart:false});
      console.log(new Date().toISOString(),event);
    };
    recovery=new LostLaunchRecovery({record,launch:()=>new Promise(resolve=>{
      if(fs.existsSync(stopFile))return resolve({launched:false,reason:'watcher-stopped'});
      const child=spawn(shell,[...args,'-Recover'],{windowsHide:true,stdio:['ignore','pipe','ignore']});
      let output='',done=false;
      const timer=setTimeout(()=>{child.kill();finish({launched:false,reason:'activation-timeout'});},10000);
      const finish=result=>{if(done)return;done=true;clearTimeout(timer);resolve(result);};
      child.stdout.on('data',b=>{if(output.length<8192)output+=b;});
      child.once('error',()=>finish({launched:false,reason:'activation-helper-unavailable'}));
      child.once('exit',()=>{try{finish(JSON.parse(output));}catch{finish({launched:false,reason:'activation-helper-failed'});}});
    })});
    observer=spawn(shell,args,{windowsHide:true,stdio:['ignore','pipe','ignore']});
    const lines=readline.createInterface({input:observer.stdout});
    lines.on('line',line=>{
      try{
        const event=JSON.parse(line);
        if(event.kind==='snapshot')recovery.tick(event).catch(()=>record('recovery-observation-failed'));
        else if(event.kind==='unavailable')record('recovery-unavailable');
      }catch{record('recovery-observation-failed');}
    });
    observer.once('error',()=>record('recovery-unavailable'));
    observer.once('exit',()=>{lines.close();record('recovery-observer-stopped');});
  }
  const stop=()=>{recovery?.stop();observer?.kill();clearInterval(timer);process.exit(0);};
  const timer=setInterval(()=>{if(fs.existsSync(stopFile))stop();},200);
  process.once('SIGTERM',stop);process.once('SIGINT',stop);
}
module.exports={NativeBridge,portInUse,readReceipt,writeReceipt};
if(require.main===module)main().catch(error=>{console.error(error.message);process.exitCode=1;});
