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
async function main() {
  const root=__dirname,config=JSON.parse(fs.readFileSync(path.join(root,'settings.json'),'utf8'));
  const receipt=path.join(root,'state.json');
  let state={};try{state=JSON.parse(fs.readFileSync(receipt,'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
  if(!Number.isFinite(state.lastAttemptAt??0))throw Error('Invalid startup receipt');
  const bridge=new NativeBridge(path.join(root,'bridge'),config.app);
  let stopped=false,timer;
  const adapter={
    snapshot:()=>bridge.call('snapshot'),
    quit:(app,stamp)=>bridge.call('quit',app.pid,app.key,stamp),
    launch:(stamp,frontmost)=>bridge.call('launch',stamp,frontmost,'restore'),
    show:(app,stamp,frontmost)=>bridge.call('show',app.pid,app.key,stamp,frontmost),
    portInUse:()=>new Promise(resolve=>{
      const socket=net.createConnection({host:'127.0.0.1',port:39222});
      const done=value=>{socket.destroy();resolve(value);};
      socket.once('connect',()=>done(true));socket.once('error',error=>done(error.code!=='ECONNREFUSED'));
      socket.setTimeout(350,()=>done(true));
    }),
    async record(event,details={}) {
      const {message,reason,shown,activated,ageMs,clientInputIdleMs,frontmostPid,...previous}=state;
      state={...previous,...details,event,updatedAt:Date.now()};
      const temp=receipt+'.tmp';fs.writeFileSync(temp,JSON.stringify(state,null,2)+'\n',{mode:0o600});fs.renameSync(temp,receipt);
      console.log(new Date().toISOString(),event);
    }
  };
  const controller=new StartupController(adapter,{lastAttemptAt:state.lastAttemptAt||0});
  function shutdown(code=0){if(stopped)return;stopped=true;controller.stop();clearTimeout(timer);bridge.close();process.exitCode=code;}
  async function tick(){
    if(stopped)return;
    if(!fs.existsSync(path.join(root,'../agent.cjs')))return shutdown();
    await controller.tick();
    if(bridge.closed)return shutdown(1);
    if(!stopped)timer=setTimeout(tick,controller.pendingLaunch?200:1000);
  }
  process.once('SIGTERM',()=>shutdown());process.once('SIGINT',()=>shutdown());
  await tick();
}
module.exports={NativeBridge};
if(require.main===module)main().catch(error=>{console.error(error.message);process.exitCode=1;});
