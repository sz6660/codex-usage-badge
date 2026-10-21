'use strict';
const fs=require('node:fs');
const path=require('node:path');
const net=require('node:net');
const {spawn}=require('node:child_process');
const readline=require('node:readline');
const {StartupController}=require('./controller.cjs');

class NativeBridge {
  constructor(executable,app,{spawnProcess=spawn}={}) {
    this.app=app;this.nextId=0;this.pending=new Map();this.closed=false;
    this.child=spawnProcess(executable,['serve',app],{stdio:['pipe','pipe','pipe']});
    this.lines=readline.createInterface({input:this.child.stdout});
    this.lines.on('line',line=>{
      try {
        const reply=JSON.parse(line),entry=this.pending.get(reply.id);
        if(!entry)throw Error('Unexpected native startup response');
        this.pending.delete(reply.id);clearTimeout(entry.timer);
        if(reply.result?.error)entry.reject(Error(reply.result.error));else entry.resolve(reply.result);
      } catch(error){this.fail(error);}
    });
    this.child.stderr.on('data',()=>{});
    this.child.stdin.on('error',error=>this.fail(error));
    this.child.once('error',error=>this.fail(error));
    this.child.once('exit',()=>this.fail(Error('Native startup helper exited')));
  }
  fail(error) {
    this.closed=true;
    for(const entry of this.pending.values()){clearTimeout(entry.timer);entry.reject(error);}
    this.pending.clear();
  }
  call(action,...fields) {
    if(this.closed)return Promise.reject(Error('Native startup helper unavailable'));
    const id=++this.nextId;
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.fail(Error('Native startup helper timeout'));this.child.kill('SIGTERM');},35000);
      this.pending.set(id,{resolve,reject,timer});
      this.child.stdin.write(JSON.stringify({id,args:[action,this.app,...fields.map(String)]})+'\n');
    });
  }
  close(){this.fail(Error('Startup watcher stopped'));this.lines.close();this.child.stdin.end();this.child.kill('SIGTERM');}
}
async function main(){
  const envModule=path.join(path.dirname(__dirname),'macos/environment.cjs');
  require(fs.existsSync(envModule)?envModule:'../environment.cjs').applySession();
  const root=path.dirname(__dirname);
  const stopFile=process.env.CODEX_BADGE_STOP_FILE||path.join(root,'stop.request');
  const receipt=path.join(__dirname,'state.json');
  const state={event:'watching',mode:'environment-connection-only',automaticRestart:false,pid:process.pid,updatedAt:Date.now()};
  fs.writeFileSync(receipt,JSON.stringify(state,null,2)+'\n');
  console.log(new Date().toISOString(),'environment-connection-only: no client launch or restart');
  const timer=setInterval(()=>{if(fs.existsSync(stopFile)){clearInterval(timer);process.exit(0);}},200);
  const stop=()=>{clearInterval(timer);process.exit(0);};
  process.once('SIGTERM',stop);process.once('SIGINT',stop);
}
module.exports={NativeBridge};
if(require.main===module)main().catch(error=>{console.error(error.message);process.exitCode=1;});
